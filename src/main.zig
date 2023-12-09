const std = @import("std");
const parse = @import("parse.zig").parse;
const OpenCLEngine = @import("engine.zig").OpenCLEngine;
const ParallelDfaSimulatorEngine = @import("engine.zig").ParallelDfaSimulatorEngine;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const regex = "^(([\\x00-\\x7F])|([\\xC2-\\xDF][\\x80-\\xBF])|((([\\xE0][\\xA0-\\xBF])|([\\xE1-\\xEC\\xEE-\\xEF][\\x80-\\xBF])|([\\xED][\\x80-\\x9F]))[\\x80-\\xBF])|((([\\xF0][\\x90-\\xBF])|([\\xF1-\\xF3][\\x80-\\xBF])|([\\xF4][\\x80-\\x8F]))[\\x80-\\xBF][\\x80-\\xBF]))*$";
    var pattern = switch (try parse(allocator, regex)) {
        .err => |err| {
            std.debug.print("Error parsing test regex '{s}': {} at offset {}\n", .{ regex, err.err, err.offset });
            return;
        },
        .pattern => |pattern| pattern,
    };
    defer pattern.deinit(allocator);

    var engine = try OpenCLEngine.init(allocator);
    defer engine.deinit();

    const cp = try engine.compilePattern(allocator, pattern);
    defer engine.destroyCompiledPattern(allocator, cp);

    const input = try allocator.alloc(u8, 1024 * 1024 * 1024);
    defer allocator.free(input);
    for (input, 0..) |*x, i| {
        x.* = @as(u8, @intCast(i % 10 + '0'));
    }

    var timer = try std.time.Timer.start();
    const result = try engine.matches(cp, input);
    const elapsed = timer.lap();
    std.debug.print("match: {}\n", .{result});
    std.debug.print("runtime: {}us\n", .{elapsed / std.time.ns_per_us});
}

test "main" {
    _ = @import("parse.zig");
    _ = @import("CharSet.zig");
    _ = @import("automaton.zig");
    _ = @import("engine.zig");
}
