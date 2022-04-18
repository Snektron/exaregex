const Ast = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const CharSet = @import("CharSet.zig");

nodes: []Node,
extra_data_arena: ArenaAllocator.State,

pub const Root: Node.Index = 0;

pub const Node = union(enum) {
    pub const Index = u32;

    pub const Repeat = struct {
        pub const Max = enum(u16) {
            infinite = 0,
            _,
        };

        child: Index,
        min: u16,
        max: Max,
    };

    pub const NodeSeq = struct {
        first_child: Index,
        num_children: u32,
    };

    empty,
    any_not_nl, // '.'
    char: u8,
    char_set: *CharSet,
    sequence: NodeSeq,
    alternation: NodeSeq,
    repeat: Repeat,
};

pub fn deinit(self: *Ast, a: Allocator) void {
    a.free(self.nodes);
    self.extra_data_arena.promote(a).deinit();
}
