const Ast = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

nodes: []Node,
extra_data_arena: ArenaAllocator.State,

pub const Root: Node.Index = 0;

pub const Node = union(enum) {
    pub const Index = u32;

    pub const Repeat = struct {
        child: Index,
        min: u16,
        max: u16,
    };

    pub const NodeSeq = struct {
        first_child: Index,
        num_children: u32,
    };

    empty,
    any_not_nl, // '.'
    char: u8,
    char_set, // TODO
    sequence: NodeSeq,
    alternation: NodeSeq,
    repeat: Repeat,
};

pub fn deinit(self: *Ast, a: Allocator) void {
    a.free(self.nodes);
    self.extra_data_arena.promote(a).deinit();
}
