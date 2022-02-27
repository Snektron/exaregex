const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const Index = Node.Index;
const CharSet = @import("CharSet.zig");
const CharRange = CharSet.Range;

pub fn parse(a: Allocator, source: []const u8) Allocator.Error!ParseResult {
    var parser = Parser{
        .a = a,
        .source = source,
        .extra_data_arena = ArenaAllocator.init(a),
    };
    defer parser.nodes.deinit(a);
    defer parser.tmp_nodes.deinit(a);
    defer parser.current_char_range.deinit(a);
    var deinit_arena = true;
    defer if (deinit_arena) parser.extra_data_arena.deinit();

    parser.parse() catch |err| {
        const parse_err = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |parse_err| parse_err,
        };
        return ParseResult{.err = .{
            .offset = parser.offset,
            .err = parse_err,
        }};
    };

    deinit_arena = false;

    std.debug.assert(parser.offset == source.len);
    return ParseResult{.ast = .{
        .nodes = parser.nodes.toOwnedSlice(a),
        .extra_data_arena = parser.extra_data_arena.state,
    }};
}

pub const ParseError = error {
    UnbalancedOpenParen,
    UnbalancedClosingParen,
    InvalidAtom,
    StrayRepeat,
    InvalidEscape,
    InvalidEscapeUnexpectedEnd,
    InvalidEscapeHexDigit,
};

pub const ParseResult = union(enum) {
    ast: Ast,
    err: Error,
};

pub const Error = struct {
    offset: usize,
    err: ParseError,
};

const Parser = struct {
    const Error = ParseError || Allocator.Error;

    a: Allocator,
    source: []const u8,
    offset: usize = 0,
    nodes: std.ArrayListUnmanaged(Node) = .{},
    tmp_nodes: std.ArrayListUnmanaged(Node) = .{},
    current_char_range: CharSet.Mutable = .{.invert = false},
    extra_data_arena: ArenaAllocator,

    fn addNode(self: *Parser, node: Node) !Index {
        const index = @intCast(Index, self.nodes.items.len);
        try self.nodes.append(self.a, node);
        return index;
    }

    fn atEnd(self: Parser) bool {
        return self.offset >= self.source.len;
    }

    fn peek(self: Parser) ?u8 {
        if (self.atEnd())
            return null;
        return self.source[self.offset];
    }

    fn consume(self: *Parser) void {
        self.offset += 1;
    }

    fn check(self: Parser, expected: u8) bool {
        return (self.peek() orelse return false) == expected;
    }

    fn eat(self: *Parser, expected: u8) bool {
        if (self.check(expected)) {
            self.consume();
            return true;
        }
        return false;
    }

    fn parse(self: *Parser) Parser.Error!void {
        // Reserve some space for the root - its always present (provided no error happens)
        // and we always want to have it at index 0.
        try self.nodes.append(self.a, undefined);
        const root = try self.alternation();
        if (self.peek()) |c| {
            // Alternation loop only breaks on )
            std.debug.assert(c == ')');
            return error.UnbalancedClosingParen;
        }
        self.nodes.items[0] = root;
    }

    fn alternation(self: *Parser) Parser.Error!Node {
        const tmp_offset = self.tmp_nodes.items.len;
        defer self.tmp_nodes.items.len = tmp_offset;

        while (true) {
            const child = try self.sequence();
            try self.tmp_nodes.append(self.a, child);
            const c = self.peek() orelse break;
            switch (c) {
                ')' => break,
                '|' => self.consume(),
                else => unreachable,
            }
        }

        const num_children = self.tmp_nodes.items.len - tmp_offset;
        if (num_children == 1) {
            // Just return the node directly instead of constructing an alternation node.
            return self.tmp_nodes.items[tmp_offset];
        }

        const first_child = @intCast(Index, self.nodes.items.len);
        try self.nodes.appendSlice(self.a, self.tmp_nodes.items[tmp_offset..]);
        return Node{.alternation = .{
            .first_child = first_child,
            .num_children = @intCast(u32, num_children),
        }};
    }

    fn sequence(self: *Parser) !Node {
        const tmp_offset = self.tmp_nodes.items.len;
        defer self.tmp_nodes.items.len = tmp_offset;

        while (true) {
            const c = self.peek() orelse break;
            const node = switch (c) {
                ')', '|' => break,
                else => try self.repeat(),
            };
            // Just omit empty nodes...
            if (node != .empty) {
                try self.tmp_nodes.append(self.a, node);
            }
        }

        const num_children = self.tmp_nodes.items.len - tmp_offset;
        if (num_children == 0) {
            return Node.empty;
        } else if (num_children == 1) {
            // Just return the node directly instead of constructing a sequence node.
            return self.tmp_nodes.items[tmp_offset];
        }

        const first_child = @intCast(Index, self.nodes.items.len);
        try self.nodes.appendSlice(self.a, self.tmp_nodes.items[tmp_offset..]);
        return Node{.sequence = .{
            .first_child = first_child,
            .num_children = @intCast(u32, num_children),
        }};
    }

    fn repeat(self: *Parser) !Node {
        // TODO: Also parse things like {}. For now, just do *, + and ?.
        const child = try self.atom();
        const c = self.peek() orelse return child;
        const rep: Node.Repeat = switch (c) {
            '*' => .{
                .child = try self.addNode(child),
                .min = 0,
                .max = 0,
            },
            '+' => .{
                .child = try self.addNode(child),
                .min = 1,
                .max = 0,
            },
            '?' => .{
                .child = try self.addNode(child),
                .min = 0,
                .max = 1,
            },
            else => return child,
        };
        self.consume();
        return Node{.repeat = rep};
    }

    fn atom(self: *Parser) !Node {
        const c = self.peek().?;
        switch (c) {
            '.' => {
                self.consume();
                return Node.any_not_nl;
            },
            '[' => unreachable, // TODO: Character set.
            '\\' => return Node{.char = try self.escape()},
            '(' => {
                const open_offset = self.offset;
                self.consume();
                const child = try self.alternation();
                if (!self.eat(')')) {
                    // Rewind parser to get better error reporting.
                    self.offset = open_offset;
                    return error.UnbalancedOpenParen;
                }
                return child;
            },
            ')', '|' => unreachable, // Handled elsewhere
            '*', '+', '?' => return error.StrayRepeat,
            else => if (std.ascii.isPrint(c)) {
                self.consume();
                return Node{.char = c};
            } else {
                return error.InvalidAtom;
            }
        }
    }

    fn escape(self: *Parser) !u8 {
        std.debug.assert(self.peek().? == '\\');
        self.consume();
        const c = self.peek() orelse return error.InvalidEscapeUnexpectedEnd;
        const escaped: u8 = switch (c) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\', '\'', '"', '-', '^', '$', '(', ')', '[', ']' => c,
            'x' => {
                self.consume();
                const hi = try self.hex();
                const lo = try self.hex();
                return hi * 16 + lo;
            },
            else => return error.InvalidEscape,
        };
        self.consume();
        return escaped;
    }

    fn hex(self: *Parser) !u8 {
        const c = self.peek() orelse return error.InvalidEscape;
        const digit = switch (c) {
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            '0'...'9' => c - '0',
            else => return error.InvalidEscapeHexDigit,
        };
        self.consume();
        return digit;
    }
};

test "parser: basic" {
    const result = try parse(std.testing.allocator, "a.*|(d?e)+");
    var ast = result.ast;
    defer ast.deinit(std.testing.allocator);

    const root = ast.nodes[Ast.Root];
    try testing.expect(root == .alternation);
    try testing.expect(root.alternation.num_children == 2);

    const @"a.*" = ast.nodes[root.alternation.first_child];
    try testing.expect(@"a.*" == .sequence);
    try testing.expect(@"a.*".sequence.num_children == 2);

    const @"a" = ast.nodes[@"a.*".sequence.first_child];
    try testing.expect(@"a".char == 'a');

    const @".*" = ast.nodes[@"a.*".sequence.first_child + 1];
    try testing.expect(@".*" == .repeat);
    try testing.expect(@".*".repeat.min == 0);
    try testing.expect(@".*".repeat.max == 0);

    const @"." = ast.nodes[@".*".repeat.child];
    try testing.expect(@"." == .any_not_nl);

    const @"(d?e)+" = ast.nodes[root.alternation.first_child + 1];
    try testing.expect(@"(d?e)+" == .repeat);
    try testing.expect(@"(d?e)+".repeat.min == 1);
    try testing.expect(@"(d?e)+".repeat.max == 0);

    const @"d?e" = ast.nodes[@"(d?e)+".repeat.child];
    try testing.expect(@"d?e" == .sequence);
    try testing.expect(@"d?e".sequence.num_children == 2);

    const @"d?" = ast.nodes[@"d?e".sequence.first_child];
    try testing.expect(@"d?" == .repeat);
    try testing.expect(@"d?".repeat.min == 0);
    try testing.expect(@"d?".repeat.max == 1);

    const @"e" = ast.nodes[@"d?e".sequence.first_child + 1];
    try testing.expect(@"e".char == 'e');
}

test "parser: stray repeat" {
    const result = try parse(std.testing.allocator, "aa**bb");
    try testing.expect(result.err.err == error.StrayRepeat);
    try testing.expect(result.err.offset == 3);
}

test "parser: unbalanced open paren" {
    const result = try parse(std.testing.allocator, "py()(()th()n");
    try testing.expect(result.err.err == error.UnbalancedOpenParen);
    try testing.expect(result.err.offset == 4);
}

test "parser: unbalanced closing paren" {
    const result = try parse(std.testing.allocator, "py(())()th)n");
    try testing.expect(result.err.err == error.UnbalancedClosingParen);
    try testing.expect(result.err.offset == 10);
}

test "parser: empty edge cases" {
    var result = try parse(std.testing.allocator, "|(||)*|");
    defer result.ast.deinit(std.testing.allocator);
}

test "parser: escape sequences" {
    const result = try parse(std.testing.allocator, "\\n\\\"\\'\\-\\x123");
    var ast = result.ast;
    defer ast.deinit(std.testing.allocator);

    const root = ast.nodes[Ast.Root].sequence;
    const nodes = ast.nodes[root.first_child .. root.first_child + root.num_children];
    try testing.expect(nodes.len == 6);
    try testing.expect(nodes[0].char == '\n');
    try testing.expect(nodes[1].char == '"');
    try testing.expect(nodes[2].char == '\'');
    try testing.expect(nodes[3].char == '-');
    try testing.expect(nodes[4].char == '\x12');
    try testing.expect(nodes[5].char == '3');
}
