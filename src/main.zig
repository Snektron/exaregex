const std = @import("std");
const parse = @import("parse.zig").parse;
const OpenCLEngine = @import("engine.zig").OpenCLEngine;
const HIPEngine = @import("engine.zig").HIPEngine;
const ParallelDfaSimulatorEngine = @import("engine.zig").ParallelDfaSimulatorEngine;
const DfaSimulatorEngine = @import("engine.zig").DfaSimulatorEngine;

pub const std_options: std.Options = .{
    .log_level = .debug,
};

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

    var stats: HIPEngine.Statistics = .{};

    // var engine = DfaSimulatorEngine.init();
    // var engine = ParallelDfaSimulatorEngine.init();
    // var engine = try OpenCLEngine.init(allocator, .{
    //     .platform = std.posix.getenv("EXAREGEX_PLATFORM"),
    //     .device = std.posix.getenv("EXAREGEX_DEVICE"),
    // });
    var engine = try HIPEngine.init(allocator, .{
        .collect_stats = &stats,
    });
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

        const seed = std.crypto.random.int(usize);
        std.log.debug("seed: {}", .{seed});
        var rng = std.Random.DefaultPrng.init(seed);
        var random = rng.random();
        break :blk dfa_engine.generateRandom(dfa, &random, input);
    };

    const generation = timer.lap();
    std.log.info("input generation: {}us", .{generation / std.time.ns_per_us});

    // Warmup
    for (0..10) |_| {
        _ = try engine.matches(p, input);
    }

    stats.reset();
    // for realz
    for (0..10) |_| {
        _ = try engine.matches(p, input);
    }

    const final_stats = stats;

    _ = timer.lap();
    const match = try engine.matches(p, input);
    const kernel = timer.lap();
    std.log.info("match: {}", .{match});
    std.log.info("expected: {}", .{accept});
    std.log.info("total runtime: {}us", .{kernel / std.time.ns_per_us});

    std.log.info("input size: {} bytes", .{size});
    std.log.info("avg upload time: {:.3} us", .{final_stats.upload.avg() * std.time.us_per_ms});
    std.log.info("avg kernel time: {:.3} us", .{final_stats.kernel.avg() * std.time.us_per_ms});
    std.log.info("avg download time: {:.3} us", .{final_stats.download.avg() * std.time.us_per_ms});

    std.log.info("upload performance: {:.3} GB/s", .{size / final_stats.upload.avg() / 1_000_000});
    std.log.info("kernel performance: {:.3} GB/s", .{size / final_stats.kernel.avg() / 1_000_000});

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
