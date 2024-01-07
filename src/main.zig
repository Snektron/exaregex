const std = @import("std");
const parse = @import("parse.zig").parse;
const OpenCLEngine = @import("engine.zig").OpenCLEngine;
const ParallelDfaSimulatorEngine = @import("engine.zig").ParallelDfaSimulatorEngine;
const DfaSimulatorEngine = @import("engine.zig").DfaSimulatorEngine;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const regex = "(([\\x00-\\x7F])|([\\xC2-\\xDF][\\x80-\\xBF])|((([\\xE0][\\xA0-\\xBF])|([\\xE1-\\xEC\\xEE-\\xEF][\\x80-\\xBF])|([\\xED][\\x80-\\x9F]))[\\x80-\\xBF])|((([\\xF0][\\x90-\\xBF])|([\\xF1-\\xF3][\\x80-\\xBF])|([\\xF4][\\x80-\\x8F]))[\\x80-\\xBF][\\x80-\\xBF]))*";
    var pattern = switch (try parse(allocator, regex)) {
        .err => |err| {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: {}\n{s}\n", .{err.err, regex});
            try stderr.writeByteNTimes(' ', err.offset);
            try stderr.writeAll("^\n");
            return;
        },
        .pattern => |pattern| pattern,
    };
    defer pattern.deinit(allocator);

    var engine = try OpenCLEngine.init(allocator, .{
        .platform = std.os.getenv("EXAREGEX_PLATFORM"),
        .device = std.os.getenv("EXAREGEX_DEVICE"),
    });
    // var engine = DfaSimulatorEngine.init();
    defer engine.deinit();

    const cp = try engine.compilePattern(allocator, pattern);
    defer engine.destroyCompiledPattern(allocator, cp);

    var timer = try std.time.Timer.start();
    const input = try allocator.alloc(u8, 1024 * 1024 * 1024);
    defer allocator.free(input);
    for (input, 0..) |*x, i| {
        x.* = @intCast(i % 8 + '0');
    }
    const generation = timer.lap();
    std.debug.print("input generation: {}us\n", .{generation / std.time.ns_per_us});

    for (0..10) |_| {
        _ = try engine.matches(cp, input);
    }

    _ = timer.lap();
    const result = try engine.matches(cp, input);
    const kernel = timer.lap();
    std.debug.print("match: {}\n", .{result});
    std.debug.print("runtime: {}us\n", .{kernel / std.time.ns_per_us});
}

test {
    _ = @import("parse.zig");
    _ = @import("CharSet.zig");
    _ = @import("automaton.zig");
    _ = @import("engine.zig");
}
