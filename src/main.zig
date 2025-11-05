const std = @import("std");
const parse = @import("parse.zig").parse;
const OpenCLEngine = @import("engine.zig").OpenCLEngine;
const HIPEngine = @import("engine.zig").HIPEngine;
const ParallelDfaSimulatorEngine = @import("engine.zig").ParallelDfaSimulatorEngine;
const DfaSimulatorEngine = @import("engine.zig").DfaSimulatorEngine;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const regex = "(([\\x00-\\x7F])|([\\xC2-\\xDF][\\x80-\\xBF])|((([\\xE0][\\xA0-\\xBF])|([\\xE1-\\xEC\\xEE-\\xEF][\\x80-\\xBF])|([\\xED][\\x80-\\x9F]))[\\x80-\\xBF])|((([\\xF0][\\x90-\\xBF])|([\\xF1-\\xF3][\\x80-\\xBF])|([\\xF4][\\x80-\\x8F]))[\\x80-\\xBF][\\x80-\\xBF]))*";
    var pattern = switch (try parse(allocator, regex)) {
        .err => |err| {
            var buf: [1024]u8 = undefined;
            var stderr_writer = std.fs.File.stderr().writer(&buf);
            var stderr = stderr_writer.interface;
            try stderr.print("Error: {}\n{s}\n", .{ err.err, regex });
            try stderr.splatByteAll(' ', err.offset);
            try stderr.writeAll("^\n");
            try stderr.flush();
            return;
        },
        .pattern => |pattern| pattern,
    };
    defer pattern.deinit(allocator);

    // var engine = DfaSimulatorEngine.init();
    // var engine = ParallelDfaSimulatorEngine.init();
    // var engine = try OpenCLEngine.init(allocator, .{
    //     .platform = std.posix.getenv("EXAREGEX_PLATFORM"),
    //     .device = std.posix.getenv("EXAREGEX_DEVICE"),
    // });
    var engine = try HIPEngine.init(allocator, .{});
    defer engine.deinit();

    const p = try engine.compilePattern(allocator, pattern);
    defer engine.destroyCompiledPattern(allocator, p);

    std.log.debug("generating input...", .{});
    var timer = try std.time.Timer.start();

    const size = 1024 * 1024 * 128;
    const input = try allocator.alloc(u8, size);
    defer allocator.free(input);
    const accept = blk: {
        var dfa_engine = DfaSimulatorEngine.init();
        defer dfa_engine.deinit();
        const dfa = try dfa_engine.compilePattern(allocator, pattern);
        defer dfa_engine.destroyCompiledPattern(allocator, dfa);

        var buf: [8]u8 = undefined;
        try std.posix.getrandom(&buf);
        const seed: usize = @bitCast(buf);

        std.debug.print("seed: {}\n", .{seed});
        var rng = std.Random.DefaultPrng.init(seed);
        var random = rng.random();
        break :blk dfa_engine.generateRandom(dfa, &random, input);
    };

    const generation = timer.lap();
    std.debug.print("input generation: {}us\n", .{generation / std.time.ns_per_us});

    for (0..10) |_| {
        _ = try engine.matches(p, input);
    }

    _ = timer.lap();
    const match = try engine.matches(p, input);
    const kernel = timer.lap();
    std.debug.print("match: {}\n", .{match});
    std.debug.print("expected: {}\n", .{accept});
    std.debug.print("runtime: {}us\n", .{kernel / std.time.ns_per_us});

    if (match != accept) {
        return error.Fail;
    }
}

test {
    _ = @import("parse.zig");
    _ = @import("CharSet.zig");
    _ = @import("automaton.zig");
    _ = @import("engine.zig");
}
