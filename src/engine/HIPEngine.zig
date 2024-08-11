const HIPEngine = @This();

const kernel = @import("match.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;

const Pattern = @import("../Pattern.zig");
const automaton = @import("../automaton.zig");
const ParallelDfa = automaton.parallel.ParallelDfa;

const hip = @import("../hip.zig");

const block_size = kernel.block_size;
const items_per_thread = kernel.items_per_thread;
const items_per_block = kernel.items_per_block;

module: hip.Module,
initial_kernel: hip.Function,
reduce_kernel: hip.Function,

pub const Options = struct {};

pub const CompiledPattern = struct {
    pdfa: ParallelDfa,
    d_initial: []u8,
    d_merge_table: []u8,
};

pub fn init(a: Allocator, options: Options) !HIPEngine {
    _ = a;
    _ = options;

    std.log.debug("loading HIP module", .{});
    const module = try hip.Module.loadData(@embedFile("match-offload-bundle"));
    errdefer module.unload();

    return .{
        .module = module,
        .initial_kernel = try module.getFunction("initial"),
        .reduce_kernel = try module.getFunction("reduce"),
    };
}

pub fn deinit(self: *HIPEngine) void {
    self.module.unload();
    self.* = undefined;
}

pub fn compilePattern(self: *HIPEngine, a: Allocator, pattern: Pattern) !CompiledPattern {
    _ = self;

    var nfa = try automaton.thompson(a, pattern, .{});
    defer nfa.deinit(a);

    var dfa = try automaton.subset(a, nfa, .{});
    defer dfa.deinit(a);

    var pdfa = try automaton.parallelize(a, dfa, .{});
    errdefer pdfa.deinit(a);

    var initial: [256]u8 = undefined;
    for (&initial, 0..) |*x, i| {
        x.* = switch (pdfa.initial_states[i]) {
            .reject => 0,
            else => |state| if (@intFromEnum(state) >= 255) {
                return error.TodoLargeAutomatons;
            } else @intCast(@intFromEnum(state) + 1),
        };
    }

    const d_initial = try hip.malloc(u8, initial.len);
    errdefer hip.free(d_initial);
    hip.memcpy(u8, d_initial, &initial, .host_to_device);

    const size = pdfa.stateCount() + 1;
    if (size * size + initial.len > 32768) {
        return error.TodoLargeAutomatons;
    }
    if (size > 120) {
        return error.TodoLargeAutomatons;
    }

    const merge_table = try a.alloc(u8, size * size);
    defer a.free(merge_table);
    @memset(merge_table, 0); // Fill with reject

    for (0..pdfa.stateCount()) |x| {
        for (0..pdfa.stateCount()) |y| {
            const result = pdfa.merge(@enumFromInt(x), @enumFromInt(y));
            merge_table[(x + 1) * size + (y + 1)] = switch (result) {
                .reject => 0,
                else => |state| if (@intFromEnum(state) >= 255) {
                    return error.TodoLargeAutomatons;
                } else @intCast(@intFromEnum(state) + 1),
            };
        }
    }

    std.log.debug("parallel states: {}", .{size});
    std.log.debug("merge table size: {}", .{merge_table.len});

    const d_merge_table = try hip.malloc(u8, merge_table.len);
    errdefer hip.free(d_merge_table);
    hip.memcpy(u8, d_merge_table, merge_table, .host_to_device);

    return .{
        .pdfa = pdfa,
        .d_initial = d_initial,
        .d_merge_table = d_merge_table,
    };
}

pub fn destroyCompiledPattern(self: *HIPEngine, a: Allocator, pattern: CompiledPattern) void {
    _ = self;
    var pdfa = pattern.pdfa;
    pdfa.deinit(a);
    hip.free(pattern.d_initial);
    hip.free(pattern.d_merge_table);
}

pub fn matches(self: *HIPEngine, pattern: CompiledPattern, input: []const u8) !bool {
    const compute_units = 200; // TODO: Get this from somewhere
    const blocks: u32 = @intCast(std.math.divCeil(usize, input.len, items_per_block) catch unreachable);

    const output_size = blocks;

    std.log.debug("compute units: {}", .{compute_units});
    std.log.debug("work size: {}", .{blocks});

    var d_input = try hip.malloc(u8, input.len);
    defer hip.free(d_input);
    hip.memcpy(u8, d_input, input, .host_to_device);

    var d_output = try hip.malloc(u8, output_size);
    defer hip.free(d_output);

    const d_counter = try hip.malloc(i32, 1);
    defer hip.free(d_counter);
    const i_blocks: i32 = @intCast(blocks);
    hip.memcpy(i32, d_counter, (&i_blocks)[0..1], .host_to_device);

    const begin = hip.Event.create();
    defer begin.destroy();

    const end = hip.Event.create();
    defer end.destroy();

    begin.record(null);

    self.initial_kernel.launch(
        .{
            .grid_dim = .{ .x = compute_units },
            .block_dim = .{ .x = block_size },
        },
        .{
            pattern.d_initial.ptr,
            pattern.d_merge_table.ptr,
            @as(u32, @intCast(pattern.pdfa.stateCount() + 1)),
            d_input.ptr,
            @as(u32, @intCast(input.len)),
            d_output.ptr,
            d_counter.ptr,
        },
    );

    _ = &d_input;
    _ = &d_output;

    var size: u32 = output_size;
    while (size > 1) {
        const out_size: u32 = @intCast(std.math.divCeil(usize, size, items_per_block) catch unreachable);
        const out_blocks: u32 = @intCast(std.math.divCeil(usize, size, items_per_block) catch unreachable);
        std.log.debug("reducing: {} -> {}", .{ size, out_size });

        std.mem.swap([]u8, &d_input, &d_output);

        self.reduce_kernel.launch(
            .{
                .grid_dim = .{ .x = out_blocks },
                .block_dim = .{ .x = block_size },
            },
            .{
                pattern.d_merge_table.ptr,
                @as(u32, @intCast(pattern.pdfa.stateCount() + 1)),
                d_input.ptr,
                size,
                d_output.ptr,
            },
        );

        size = out_size;
    }

    end.record(null);

    var result: u8 = undefined;
    hip.memcpy(u8, (&result)[0..1], d_output[0..1], .device_to_host);

    const elapsed = hip.Event.elapsed(begin, end);
    std.log.debug("result: {}", .{result});
    std.log.debug("kernel runtime: {d:.2}us", .{elapsed * std.time.us_per_ms});
    std.log.debug("kernel throughput: {d:.2} GB/s", .{@as(f32, @floatFromInt(input.len)) / (elapsed / std.time.ms_per_s) / 1000_000_000});

    const result_state = switch (result) {
        0 => .reject,
        else => @as(ParallelDfa.StateRef, @enumFromInt(result - 1)),
    };
    return pattern.pdfa.isAccepting(result_state);
}

test "HIPEngine - cases" {
    var engine = try HIPEngine.init(std.testing.allocator, .{});
    defer engine.deinit();

    try @import("test.zig").testEngineCases(HIPEngine, &engine);
}

test "HIPEngine - utf8 fuzz" {
    var engine = try HIPEngine.init(std.testing.allocator, .{});
    defer engine.deinit();

    try @import("test.zig").testEngineFuzzUtf8(HIPEngine, &engine);
}
