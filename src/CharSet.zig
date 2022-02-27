/// An immutable range of chars.
/// Memory is owned externally.
const CharSet = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Range of characters. They are not sorted, but are not overlapping.
/// If performance becomes a problem we can always do that later. Charsets aren't
/// expected to be particularly large anyway.
ranges: []Range = &.{},

/// Invert this range
invert: bool,

/// This struct represents a char range which is mutable - new entries can be added, at the
/// expense of some extra memory.
pub const Mutable = struct {
    /// Range of characters. They are not sorted, but are not overlapping.
    ranges: std.ArrayListUnmanaged(Range) = .{},
    invert: bool,

    pub fn deinit(self: *Mutable, a: Allocator) void {
        self.ranges.deinit(a);
        self.* = undefined;
    }

    pub fn toImmutable(self: Mutable) CharSet {
        return CharSet{
            .ranges = self.ranges.items,
            .invert = self.invert,
        };
    }

    pub fn insert(self: *Mutable, a: Allocator, r: Range) !void {
        for (self.ranges.items) |*current| {
            if (r.merge(current.*)) |merged| {
                current.* = merged;
                return;
            }
        }

        try self.ranges.append(a, r);
    }

    pub fn clear(self: *Mutable) void {
        self.ranges.items.len = 0;
    }
};

pub fn deinit(self: *CharSet, a: Allocator) void {
    a.free(self.ranges);
    self.* = undefined;
}

/// Models a range of characters. Both ends are inclusive.
pub const Range = struct {
    min: u8,
    max: u8,

    pub fn contains(self: Range, c: u8) bool {
        return self.min <= c and c <= self.max;
    }

    pub fn merge(a: Range, b: Range) ?Range {
        if (a.min > b.max or a.max + 1 < b.min)
            return null;

        return Range{
            .min = @minimum(a.min, b.min),
            .max = @maximum(a.max, b.max),
        };
    }
};

pub fn range(min: u8, max: u8) Range {
    std.debug.assert(min <= max);
    return Range{
        .min = min,
        .max = max,
    };
}

pub fn singleton(c: u8) Range {
    return Range{
        .min = c,
        .max = c,
    };
}

test "char range: contains" {
    try testing.expect(singleton('a').contains('a'));
    try testing.expect(!singleton('b').contains('a'));
    try testing.expect(!singleton('b').contains('c'));

    try testing.expect(!range('b', 'd').contains('a'));
    try testing.expect(range('b', 'd').contains('b'));
    try testing.expect(range('b', 'd').contains('c'));
    try testing.expect(range('b', 'd').contains('d'));
    try testing.expect(!range('b', 'd').contains('e'));
}

test "char range: merge" {
    try testing.expectEqual(@as(?Range, null), Range.merge(singleton('a'), singleton('c')));
    try testing.expectEqual(@as(?Range, range('a', 'c')), Range.merge(singleton('a'), range('b', 'c')));
}
