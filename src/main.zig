const std = @import("std");
const parse = @import("parse.zig");

pub fn main() !void {
    std.log.info("All your codebase are belong to us.", .{});
}

test "main" {
    _ = @import("parse.zig");
}
