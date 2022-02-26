const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const Index = Node.Index;

pub fn parse(a: Allocator, source: []const u8) Allocator.Error!ParseResult {
    var parser = Parser{
        .a = a,
        .source = source,
        .offset = 0,
        .nodes = .{},
        .tmp_nodes = .{},
    };
    defer parser.nodes.deinit(a);
    defer parser.tmp_nodes.deinit(a);

    parser.parse() catch |err| {
        const tag: Error.Tag = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnbalancedOpenParen => .unbalanced_open_paren,
            error.UnbalancedClosingParen => .unbalanced_closing_paren,
            error.InvalidAtom => .expected_atom,
            error.StrayRepeat => .stray_repeat,
        };
        return ParseResult{.err = .{
            .offset = parser.offset,
            .tag = tag,
        }};
    };

    std.debug.assert(parser.offset == source.len);
    return ParseResult{.ast = .{
        .nodes = parser.nodes.toOwnedSlice(a),
    }};
}

pub const ParseResult = union(enum) {
    ast: Ast,
    err: Error,
};

pub const Error = struct {
    offset: usize,
    tag: Tag,

    pub const Tag = enum {
        unbalanced_open_paren,
        unbalanced_closing_paren,
        expected_atom,
        stray_repeat,
    };
};

const Parser = struct {
    const ParseError = error {
        OutOfMemory,
        /// Encountered an open paren with no corresponding open paren.
        UnbalancedOpenParen,
        UnbalancedClosingParen,
        /// Expected an atom character (literal, ., (, [) but found something else.
        InvalidAtom,
        StrayRepeat,
    };

    a: Allocator,
    source: []const u8,
    offset: usize,
    nodes: std.ArrayListUnmanaged(Node),
    tmp_nodes: std.ArrayListUnmanaged(Node),

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

    fn parse(self: *Parser) ParseError!void {
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

    fn alternation(self: *Parser) ParseError!Node {
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
            '\\' => unreachable, // TODO: Escape.
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
};

test "parser: basic" {
    const result = try parse(std.testing.allocator, "ab*|(d?e)+");
    var ast = result.ast;
    defer ast.deinit(std.testing.allocator);

    const root = ast.nodes[Ast.Root];
    try testing.expect(root == .alternation);
    try testing.expect(root.alternation.num_children == 2);

    const @"ab*" = ast.nodes[root.alternation.first_child];
    try testing.expect(@"ab*" == .sequence);
    try testing.expect(@"ab*".sequence.num_children == 2);

    const @"a" = ast.nodes[@"ab*".sequence.first_child];
    try testing.expect(@"a".char == 'a');

    const @"b*" = ast.nodes[@"ab*".sequence.first_child + 1];
    try testing.expect(@"b*" == .repeat);
    try testing.expect(@"b*".repeat.min == 0);
    try testing.expect(@"b*".repeat.max == 0);

    const @"b" = ast.nodes[@"b*".repeat.child];
    try testing.expect(@"b".char == 'b');

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
    try testing.expect(result.err.tag == .stray_repeat);
    try testing.expect(result.err.offset == 3);
}

test "parser: unbalanced open paren" {
    const result = try parse(std.testing.allocator, "py()(()th()n");
    try testing.expect(result.err.tag == .unbalanced_open_paren);
    try testing.expect(result.err.offset == 4);
}

test "parser: unbalanced closing paren" {
    const result = try parse(std.testing.allocator, "py(())()th)n");
    try testing.expect(result.err.tag == .unbalanced_closing_paren);
    try testing.expect(result.err.offset == 10);
}

test "parser: empty edge cases" {
    var result = try parse(std.testing.allocator, "|(||)*|");
    defer result.ast.deinit(std.testing.allocator);
}
