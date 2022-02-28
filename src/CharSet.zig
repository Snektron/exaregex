/// An immutable range of chars.
/// Memory is owned externally.
const CharSet = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// The ranges which make up this char set. They are sorted and non overlapping.
ranges: []Range = &.{},

/// Invert this range
invert: bool,

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

    /// Order two ranges by start- and end offset.
    /// [a,b] and [a,c] will return cmp(b, c)
    /// [a,b] and [c,b] will return cmp(a, a)
    pub fn cmp(a: Range, b: Range) std.math.Order {
        if (a.min != b.min) {
            return std.math.order(a.min, b.min);
        } else if (a.max != b.max) {
            return std.math.order(a.max, b.max);
        }
        return .eq;
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
