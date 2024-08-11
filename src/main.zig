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
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: {}\n{s}\n", .{ err.err, regex });
            try stderr.writeByteNTimes(' ', err.offset);
            try stderr.writeAll("^\n");
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

        const seed: usize = @bitCast(std.time.milliTimestamp());
        // const seed: usize = 1723289427195;
        std.debug.print("seed: {}\n", .{seed});
        var rng = std.Random.DefaultPrng.init(seed);
        var random = rng.random();
        break :blk dfa_engine.generateRandom(dfa, &random, input);
    };

    // {
    //     var pdfa_engine = ParallelDfaSimulatorEngine.init();
    //     defer pdfa_engine.deinit();
    //     const pdfa = try pdfa_engine.compilePattern(allocator, pattern);
    //     defer pdfa_engine.destroyCompiledPattern(allocator, pdfa);

    //     var i: usize = 0;
    //     while (i < input.len) : (i += 128) {
    //         var state = pdfa.pdfa.initial(input[i]);
    //         for (input[i..][1..128]) |sym| {
    //             state = pdfa.pdfa.merge(state, pdfa.pdfa.initial(sym));
    //         }

    //         const mapped = switch (state) {
    //             .reject => 0,
    //             else => @intFromEnum(state) + 1,
    //         };

    //         std.debug.print("{} ", .{mapped});
    //         // return pdfa.isAccepting(state);
    //     }
    //     std.debug.print("\n", .{});
    // }

    // const input = try allocator.alloc(u8, 1024 * 1024 * 1024);
    // defer allocator.free(input);
    // for (input, 0..) |*x, i| {
    //     x.* = @intCast(i % 37 + '0');
    // }
    // // input[1024 * 1024 * 76 - 16624] = '\xFE';
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
