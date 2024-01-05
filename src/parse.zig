const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;

const Pattern = @import("Pattern.zig");
const Node = Pattern.Node;
const Index = Node.Index;
const CharSet = @import("CharSet.zig");
const CharRange = CharSet.Range;

pub fn parse(a: Allocator, source: []const u8) Allocator.Error!ParseResult {
    var extra_data_arena = ArenaAllocator.init(a);
    var deinit_arena = true;
    defer if (deinit_arena) extra_data_arena.deinit();

    var parser = Parser{
        .a = a,
        .source = source,
        .extra_data_arena = extra_data_arena.allocator(),
    };
    defer parser.nodes.deinit(a);
    defer parser.tmp_nodes.deinit(a);
    defer parser.current_char_range.deinit(a);

    parser.parse() catch |err| {
        const parse_err = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |parse_err| parse_err,
        };
        return ParseResult{ .err = .{
            .offset = parser.offset,
            .err = parse_err,
        } };
    };

    deinit_arena = false;

    std.debug.assert(parser.offset == source.len);
    return ParseResult{ .pattern = .{
        .nodes = try parser.nodes.toOwnedSlice(a),
        .extra_data_arena = extra_data_arena.state,
    } };
}

pub const ParseError = error{
    UnbalancedOpenParen,
    UnbalancedClosingParen,
    UnbalancedClosingBracket,
    InvalidChar,
    StrayRepeat,
    InvalidEscape,
    InvalidEscapeUnexpectedEnd,
    InvalidEscapeHexDigit,
    UnterminatedCharSet,
    InvalidCharSetChar,
    InvalidCharSetRange,
    AnchorsNotSupported,
};

pub const ParseResult = union(enum) {
    pattern: Pattern,
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
    current_char_range: std.ArrayListUnmanaged(CharRange) = .{},
    extra_data_arena: Allocator,

    fn addNode(self: *Parser, node: Node) !Index {
        const index = @as(Index, @intCast(self.nodes.items.len));
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

        const first_child = @as(Index, @intCast(self.nodes.items.len));
        try self.nodes.appendSlice(self.a, self.tmp_nodes.items[tmp_offset..]);
        return Node{ .alternation = .{
            .first_child = first_child,
            .num_children = @as(u32, @intCast(num_children)),
        } };
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

        const first_child = @as(Index, @intCast(self.nodes.items.len));
        try self.nodes.appendSlice(self.a, self.tmp_nodes.items[tmp_offset..]);
        return Node{ .sequence = .{
            .first_child = first_child,
            .num_children = @as(u32, @intCast(num_children)),
        } };
    }

    fn repeat(self: *Parser) !Node {
        // TODO: Also parse things like {}. For now, just do *, + and ?.
        const child = try self.atom();
        const c = self.peek() orelse return child;
        const kind: Node.Repeat.Kind = switch (c) {
            '*' => .zero_or_more,
            '?' => .zero_or_once,
            '+' => .once_or_more,
            else => return child,
        };
        self.consume();
        return Node{ .repeat = .{ .child = try self.addNode(child), .kind = kind } };
    }

    fn atom(self: *Parser) !Node {
        const c = self.peek().?;
        switch (c) {
            '.' => {
                self.consume();
                return Node.any_not_nl;
            },
            '[' => return try self.charSet(),
            ']' => return error.UnbalancedClosingBracket,
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
            '^', '$' => return error.AnchorsNotSupported,
            else => return Node{ .char = try self.maybeEscapedChar() },
        }
    }

    fn charSet(self: *Parser) !Node {
        std.debug.assert(self.peek().? == '[');
        self.consume();
        const invert = self.eat('^');

        self.current_char_range.items.len = 0;
        while (!self.eat(']')) {
            const min = try self.charSetChar();
            if (self.eat('-')) {
                const max_offset = self.offset;
                const max = try self.charSetChar();
                if (max < min) {
                    self.offset = max_offset; // So that the parser points to the max char.
                    return error.InvalidCharSetRange;
                }
                try self.current_char_range.append(self.a, CharSet.range(min, max));
            } else {
                try self.current_char_range.append(self.a, CharSet.singleton(min));
            }
        }

        const Cmp = struct {
            fn cmp(_: void, a: CharRange, b: CharRange) bool {
                return CharRange.cmp(a, b) == .lt;
            }
        };
        std.sort.block(CharRange, self.current_char_range.items, {}, Cmp.cmp);

        const ranges = self.current_char_range.items;
        var i: usize = 0;
        for (ranges, 0..) |r, j| {
            if (j == 0) {
                continue;
            }

            if (ranges[i].merge(r)) |merged| {
                ranges[i] = merged;
            } else {
                i += 1;
                ranges[i] = r;
            }
        }

        const char_set = try self.extra_data_arena.create(CharSet);
        char_set.* = .{
            .invert = invert,
            .ranges = try self.extra_data_arena.dupe(CharRange, ranges[0 .. i + 1]),
        };

        return Node{ .char_set = char_set };
    }

    fn charSetChar(self: *Parser) !u8 {
        const c = self.peek() orelse return error.UnterminatedCharSet;
        return switch (c) {
            '[', ']', '-' => error.InvalidCharSetChar,
            else => return try self.maybeEscapedChar(),
        };
    }

    fn maybeEscapedChar(self: *Parser) !u8 {
        const c = self.peek().?;
        if (c == '\\') {
            return try self.escape();
        } else if (std.ascii.isPrint(c)) {
            self.consume();
            return c;
        }
        return error.InvalidChar;
    }

    fn escape(self: *Parser) !u8 {
        std.debug.assert(self.peek().? == '\\');
        self.consume();
        const c = self.peek() orelse return error.InvalidEscapeUnexpectedEnd;
        const escaped: u8 = switch (c) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\', '\'', '"', '-', '^', '$', '(', ')', '[', ']', '.' => c,
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
    var pattern = result.pattern;
    defer pattern.deinit(std.testing.allocator);

    const root = pattern.nodes[Pattern.Root];
    try testing.expect(root == .alternation);
    try testing.expect(root.alternation.num_children == 2);

    const @"a.*" = pattern.nodes[root.alternation.first_child];
    try testing.expect(@"a.*" == .sequence);
    try testing.expect(@"a.*".sequence.num_children == 2);

    const a = pattern.nodes[@"a.*".sequence.first_child];
    try testing.expect(a.char == 'a');

    const @".*" = pattern.nodes[@"a.*".sequence.first_child + 1];
    try testing.expect(@".*" == .repeat);
    try testing.expect(@".*".repeat.kind == .zero_or_more);

    const @"." = pattern.nodes[@".*".repeat.child];
    try testing.expect(@"." == .any_not_nl);

    const @"(d?e)+" = pattern.nodes[root.alternation.first_child + 1];
    try testing.expect(@"(d?e)+" == .repeat);
    try testing.expect(@"(d?e)+".repeat.kind == .once_or_more);

    const @"d?e" = pattern.nodes[@"(d?e)+".repeat.child];
    try testing.expect(@"d?e" == .sequence);
    try testing.expect(@"d?e".sequence.num_children == 2);

    const @"d?" = pattern.nodes[@"d?e".sequence.first_child];
    try testing.expect(@"d?" == .repeat);
    try testing.expect(@"d?".repeat.kind == .zero_or_once);

    const e = pattern.nodes[@"d?e".sequence.first_child + 1];
    try testing.expect(e.char == 'e');
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
    defer result.pattern.deinit(std.testing.allocator);
}

test "parser: escape sequences" {
    const result = try parse(std.testing.allocator, "\\n\\\"\\'\\-\\x123");
    var pattern = result.pattern;
    defer pattern.deinit(std.testing.allocator);

    const root = pattern.nodes[Pattern.Root].sequence;
    const nodes = pattern.nodes[root.first_child .. root.first_child + root.num_children];
    try testing.expect(nodes.len == 6);
    try testing.expect(nodes[0].char == '\n');
    try testing.expect(nodes[1].char == '"');
    try testing.expect(nodes[2].char == '\'');
    try testing.expect(nodes[3].char == '-');
    try testing.expect(nodes[4].char == '\x12');
    try testing.expect(nodes[5].char == '3');
}

test "parser: char set basics" {
    const result = try parse(std.testing.allocator, "[^abc-g\\n- x]");
    var pattern = result.pattern;
    defer pattern.deinit(std.testing.allocator);

    const set = pattern.nodes[Pattern.Root].char_set.*;
    try testing.expect(set.invert);
    try testing.expect(set.ranges.len == 3);
    try testing.expectEqual(CharSet.range('\n', ' '), set.ranges[0]);
    try testing.expectEqual(CharSet.range('a', 'g'), set.ranges[1]);
    try testing.expectEqual(CharSet.singleton('x'), set.ranges[2]);
}

test "parser: char set invalid range end" {
    const result = try parse(std.testing.allocator, "[a-]");
    try testing.expect(result.err.err == error.InvalidCharSetChar);
    try testing.expect(result.err.offset == 3);
}

test "parser: char set invalid range start" {
    const result = try parse(std.testing.allocator, "[-a]");
    try testing.expect(result.err.err == error.InvalidCharSetChar);
    try testing.expect(result.err.offset == 1);
}

test "parser: char set invalid range" {
    const result = try parse(std.testing.allocator, "[db-a]");
    try testing.expect(result.err.err == error.InvalidCharSetRange);
    try testing.expect(result.err.offset == 4);
}
