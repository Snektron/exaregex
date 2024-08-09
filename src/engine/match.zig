const std = @import("std");

const StateRef = u8;

// KEEP SYNCED
pub const block_size = 512;
pub const items_per_thread = 16;
pub const items_per_block = block_size * items_per_thread;

// Custom panic handler, to prevent stack traces etc on this target.
pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    _ = stack_trace;
    unreachable;
}

const InitialStorage = struct {
    initial_table: [256]StateRef,
    merge_table: [120 * 120]StateRef,
    reduce: [block_size]StateRef,
    block_id: i32,
};

var initial_storage: InitialStorage addrspace(.shared) = undefined;

const ReduceStorage = struct {
    merge_table: [120 * 120]StateRef,
    reduce: [block_size]StateRef,
};

var reduce_storage: ReduceStorage addrspace(.shared) = undefined;

inline fn merge(
    merge_table: [*]addrspace(.shared) const StateRef,
    merge_table_size: u32,
    a: StateRef,
    b: StateRef,
) StateRef {
    return merge_table[a * merge_table_size + b];
}

inline fn blockReduceLimit(
    merge_table: [*]addrspace(.shared) const StateRef,
    merge_table_size: u32,
    exchange: [*]addrspace(.shared) StateRef,
    thread_result: StateRef,
    num_valid_items: u32,
) StateRef {
    const thread_id = @workItemId(0);
    var result = thread_result;

    exchange[thread_id] = result;
    asm volatile ("s_barrier");

    comptime var i = 1;
    inline while (i < block_size) : (i <<= 1) {
        if (thread_id + i < num_valid_items) {
            result = merge(
                merge_table,
                merge_table_size,
                result,
                exchange[thread_id + i],
            );
        }
        asm volatile ("s_barrier");
        exchange[thread_id] = result;
        asm volatile ("s_barrier");
    }

    return exchange[0];
}

export fn initial(
    initial_table: *addrspace(.global) const [256]StateRef,
    merge_table: [*]addrspace(.global) const StateRef,
    merge_table_size: u32,
    input: [*]addrspace(.global) const u8,
    input_size: u32,
    output: [*]addrspace(.global) u8,
    counter: *i32,
) callconv(.Kernel) void {
    const thread_id = @workItemId(0);

    // Read the initial and merge tables into their shared storage.
    {
        var i = thread_id;
        while (i < 256) : (i += block_size) {
            initial_storage.initial_table[i] = initial_table[i];
        }
    }

    {
        var i = thread_id;
        while (i < merge_table_size * merge_table_size) : (i += block_size) {
            initial_storage.merge_table[i] = merge_table[i];
        }
    }

    while (true) {
        if (thread_id == 0) {
            initial_storage.block_id = @atomicRmw(i32, counter, .Sub, 1, .acquire);
        }
        asm volatile ("s_barrier");
        const i_block_id = initial_storage.block_id;

        if (i_block_id < 0) {
            return;
        }

        const block_id: u32 = @intCast(i_block_id);

        const global_id = block_id * block_size + thread_id;
        const is_last_block = (block_id + 1) * items_per_block > input_size;
        const block_state: StateRef = if (is_last_block) blk: {
            var in: [items_per_thread]u8 = undefined;
            for (&in, 0..) |*c, i| {
                if (global_id * items_per_thread + i < input_size) {
                    c.* = input[global_id * items_per_thread + i];
                }
            }

            // Apply initial mapping
            var states: [items_per_thread]StateRef = undefined;
            for (0..items_per_thread) |i| {
                if (global_id * items_per_thread + i < input_size) {
                    states[i] = initial_table[in[i]];
                }
            }

            var local_result_state: StateRef = states[0];
            for (1..items_per_thread) |i| {
                if (global_id * items_per_thread + i < input_size) {
                    local_result_state = merge(&initial_storage.merge_table, merge_table_size, local_result_state, states[i]);
                }
            }

            const valid_items_in_block = (input_size - items_per_block * block_id + items_per_thread - 1) / items_per_thread;
            break :blk blockReduceLimit(
                &initial_storage.merge_table,
                merge_table_size,
                &initial_storage.reduce,
                local_result_state,
                valid_items_in_block,
            );
        } else blk: {
            var in: [items_per_thread]u8 = undefined;
            // TODO: Optimize load!!
            for (&in, 0..) |*c, i| {
                c.* = input[global_id * items_per_thread + i];
            }

            // Apply initial mapping
            var states: [items_per_thread]StateRef = undefined;
            for (0..items_per_thread) |i| {
                states[i] = initial_storage.initial_table[in[i]];
            }

            var local_result_state: StateRef = states[0];
            for (1..items_per_thread) |i| {
                local_result_state = merge(&initial_storage.merge_table, merge_table_size, local_result_state, states[i]);
            }

            break :blk blockReduceLimit(
                &initial_storage.merge_table,
                merge_table_size,
                &initial_storage.reduce,
                local_result_state,
                block_size,
            );
        };

        if (thread_id == 0) {
            output[block_id] = block_state;
        }
    }
}

export fn reduce(
    merge_table: [*]addrspace(.global) const StateRef,
    merge_table_size: u32,
    input: [*]addrspace(.global) const StateRef,
    input_size: u32,
    output: [*]addrspace(.global) StateRef,
) callconv(.Kernel) void {
    const thread_id = @workItemId(0);
    const block_id = @workGroupId(0);
    const global_id = block_id * block_size + thread_id;

    // Read the merge table into shared storage.
    {
        var i = thread_id;
        while (i < merge_table_size * merge_table_size) : (i += block_size) {
            initial_storage.merge_table[i] = merge_table[i];
        }
    }

    asm volatile ("s_barrier");

    const is_last_block = true; //(block_id + 1) * items_per_block > input_size;
    const block_state: StateRef = if (is_last_block) blk: {
        var states: [items_per_thread]StateRef = undefined;
        for (&states, 0..) |*c, i| {
            if (global_id * items_per_thread + i < input_size) {
                c.* = input[global_id * items_per_thread + i];
            }
        }

        var local_result_state: StateRef = states[0];
        for (1..items_per_thread) |i| {
            if (global_id * items_per_thread + i < input_size) {
                local_result_state = merge(&initial_storage.merge_table, merge_table_size, local_result_state, states[i]);
            }
        }

        const valid_items_in_block = (input_size - items_per_block * block_id + items_per_thread - 1) / items_per_thread;
        break :blk blockReduceLimit(
            &initial_storage.merge_table,
            merge_table_size,
            &initial_storage.reduce,
            local_result_state,
            valid_items_in_block,
        );
    } else blk: {
        var states: [items_per_thread]StateRef = undefined;
        // TODO: Optimize load!!
        for (&states, 0..) |*c, i| {
            c.* = input[global_id * items_per_thread + i];
        }

        var local_result_state: StateRef = states[0];
        for (1..items_per_thread) |i| {
            local_result_state = merge(&initial_storage.merge_table, merge_table_size, local_result_state, states[i]);
        }

        break :blk blockReduceLimit(
            &initial_storage.merge_table,
            merge_table_size,
            &initial_storage.reduce,
            local_result_state,
            block_size,
        );
    };

    if (thread_id == 0) {
        output[block_id] = block_state;
    }
}
