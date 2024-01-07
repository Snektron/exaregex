#ifndef BLOCK_SIZE
    #define BLOCK_SIZE (64)
#endif

#ifndef ITEMS_PER_THREAD
    #define ITEMS_PER_THREAD (2)
#endif

#define ITEMS_PER_BLOCK (ITEMS_PER_THREAD * BLOCK_SIZE)

typedef unsigned char stateref_t;

stateref_t merge(
    local stateref_t* merge_table,
    int merge_table_size,
    stateref_t a,
    stateref_t b
) {
    return merge_table[a * merge_table_size + b];
}

stateref_t block_reduce_aligned(
    local stateref_t* merge_table,
    int merge_table_size,
    local stateref_t* storage,
    stateref_t state
) {
    const int sub_group_size = get_sub_group_size();
    const int warps = get_num_sub_groups();
    const int warp_id = get_sub_group_id();
    const int lane_id = get_sub_group_local_id();

    for (int i = sub_group_size >> 1; i > 0; i >>= 1) {
        const stateref_t other = sub_group_shuffle_xor(state, i);
        state = merge(
            merge_table,
            merge_table_size,
            state,
            other
        );
    }

    if (lane_id == 0) {
        storage[warp_id] = state;
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    // Assume that warps * warps < BLOCK_SIZE

    if (warp_id == 0) {
        state = storage[warp_id];

        for (int i = sub_group_size >> 1; i > 0; i >>= 1) {
            if ((lane_id ^ i) < warps) {
                const stateref_t other = sub_group_shuffle_xor(state, i);
                state = merge(
                    merge_table,
                    merge_table_size,
                    state,
                    other
                );
            }
        }
    }

    return state;
}

stateref_t block_reduce_limit(
    local stateref_t* merge_table,
    int merge_table_size,
    local stateref_t* storage,
    stateref_t thread_result,
    int num_valid_items
) {
    int thread_id = get_local_id(0);
    storage[thread_id] = thread_result;
    barrier(CLK_LOCAL_MEM_FENCE);
    for (int i = 1; i < BLOCK_SIZE; i <<= 1) {
        if (thread_id + i < num_valid_items) {
             thread_result = merge(
                merge_table,
                merge_table_size,
                thread_result,
                storage[thread_id + i]
            );
        }
        barrier(CLK_LOCAL_MEM_FENCE);
        storage[thread_id] = thread_result;
        barrier(CLK_LOCAL_MEM_FENCE);
    }
    return storage[0];
}

stateref_t block_reduce(
    local stateref_t* merge_table,
    int merge_table_size,
    local stateref_t* storage,
    stateref_t thread_result,
    int num_valid_items
) {
    if (num_valid_items == BLOCK_SIZE) {
        return block_reduce_aligned(merge_table, merge_table_size, storage, thread_result);
    } else {
        return block_reduce_limit(merge_table, merge_table_size, storage, thread_result, num_valid_items);
    }
}

kernel void initial(
    constant stateref_t* initial_table,
    constant stateref_t* merge_table,
    int merge_table_size,
    constant unsigned char* input,
    int input_size,
    global stateref_t* output,
    global uint* counter
) {
    int thread_id = get_local_id(0);

    local struct {
        stateref_t initial_table[256];
        stateref_t merge_table[120 * 120];
        stateref_t reduce[BLOCK_SIZE];
        int block_id;
    } storage;

    // Read the initial and merge tables into their local storage.
    for (int i = thread_id; i < 256; i += BLOCK_SIZE) {
        storage.initial_table[i] = initial_table[i];
    }

    // Load the merge table into local storage.
    for (int i = thread_id; i < merge_table_size * merge_table_size; i += BLOCK_SIZE) {
        storage.merge_table[i] = merge_table[i];
    }

    while (true) {
        if (thread_id == 0) {
            storage.block_id = atomic_dec(counter);
        }
        barrier(CLK_LOCAL_MEM_FENCE);

        int block_id = storage.block_id;
        if (block_id < 0)
            break;

        int global_id = block_id * BLOCK_SIZE + thread_id;
        bool is_last_block = (block_id + 1) * ITEMS_PER_BLOCK > input_size;

        stateref_t block_state;
        if (is_last_block) {
            unsigned char in[ITEMS_PER_THREAD];
            for (int i = 0; i < ITEMS_PER_THREAD; ++i) {
                if (global_id * ITEMS_PER_THREAD + i < input_size) {
                    in[i] = input[global_id * ITEMS_PER_THREAD + i];
                }
            }

            // Apply the initial mapping of characters to states.
            stateref_t states[ITEMS_PER_THREAD];
            for (int i = 0; i < ITEMS_PER_THREAD; ++i) {
                if (global_id * ITEMS_PER_THREAD + i < input_size) {
                    states[i] = storage.initial_table[in[i]];
                }
            }

            // Perform the local reduction
            stateref_t local_result_state = states[0];
            for (int i = 1; i < ITEMS_PER_THREAD; ++i) {
                if (global_id * ITEMS_PER_THREAD + i < input_size) {
                    local_result_state = merge(storage.merge_table, merge_table_size, local_result_state, states[i]);
                }
            }

            // Perform the block reduction.
            int valid_items_in_block = (input_size - ITEMS_PER_BLOCK * block_id + ITEMS_PER_THREAD - 1) / ITEMS_PER_THREAD;
            block_state = block_reduce_limit(
                storage.merge_table,
                merge_table_size,
                storage.reduce,
                local_result_state,
                valid_items_in_block
            );
        } else {
            unsigned char in[ITEMS_PER_THREAD];
            for (int i = 0; i < ITEMS_PER_THREAD; i += sizeof(ulong)) {
                *(ulong*)&in[i] = *(constant ulong*)&input[global_id * ITEMS_PER_THREAD + i];
            }

            // Apply the initial mapping of characters to states.
            stateref_t states[ITEMS_PER_THREAD];
            for (int i = 0; i < ITEMS_PER_THREAD; ++i) {
                states[i] = storage.initial_table[in[i]];
            }

            // Perform the local reduction
            stateref_t local_result_state = states[0];
            for (int i = 1; i < ITEMS_PER_THREAD; ++i) {
                local_result_state = merge(storage.merge_table, merge_table_size, local_result_state, states[i]);
            }

            // Perform the block reduction.
            block_state = block_reduce_aligned(
                storage.merge_table,
                merge_table_size,
                storage.reduce,
                local_result_state
            );
        }

        if (thread_id == 0) {
            output[block_id] = block_state;
        }
    }
}

kernel void reduce(
    constant stateref_t* merge_table,
    int merge_table_size,
    constant stateref_t* input,
    int input_size,
    global stateref_t* output
) {
    int block_id = get_group_id(0);
    int thread_id = get_local_id(0);
    int global_id = get_global_id(0);
    int number_of_blocks = get_num_groups(0);
    bool is_last_block = block_id == number_of_blocks - 1;

    local struct {
        stateref_t merge_table[32768 - 256];
        stateref_t reduce[BLOCK_SIZE];
    } storage;

    stateref_t block_state;
    if (is_last_block) {
        stateref_t states[ITEMS_PER_THREAD];
        for (int i = 0; i < ITEMS_PER_THREAD; ++i) {
            if (global_id * ITEMS_PER_THREAD + i < input_size) {
                states[i] = input[global_id * ITEMS_PER_THREAD + i];
            }
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        // Load the merge table into storage - we dont need the initial table anymore now.
        // Assume that BLOCK_SIZE divides 256 evenly.
        for (int i = thread_id; i < merge_table_size * merge_table_size; i += BLOCK_SIZE) {
            storage.merge_table[i] = merge_table[i];
        }

        barrier(CLK_LOCAL_MEM_FENCE);
        // Perform the local reduction
        stateref_t thread_state = states[0];
        for (int i = 1; i < ITEMS_PER_THREAD; ++i) {
            if (global_id * ITEMS_PER_THREAD + i < input_size) {
                thread_state = merge(storage.merge_table, merge_table_size, thread_state, states[i]);
            }
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        // Perform the block reduction.
        int valid_items_in_block = (input_size - ITEMS_PER_BLOCK * block_id + ITEMS_PER_THREAD - 1) / ITEMS_PER_THREAD;
        block_state = block_reduce_limit(
            storage.merge_table,
            merge_table_size,
            storage.reduce,
            thread_state,
            valid_items_in_block
        );
    } else {
        stateref_t states[ITEMS_PER_THREAD];
        for (int i = 0; i < ITEMS_PER_THREAD; ++i) {
            states[i] = input[global_id * ITEMS_PER_THREAD + i];
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        // Load the merge table into storage - we dont need the initial table anymore now.
        // Assume that BLOCK_SIZE divides 256 evenly.
        for (int i = thread_id; i < merge_table_size * merge_table_size; i += BLOCK_SIZE) {
            storage.merge_table[i] = merge_table[i];
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        // Perform the local reduction
        stateref_t thread_state = states[0];
        for (int i = 1; i < ITEMS_PER_THREAD; ++i) {
            thread_state = merge(storage.merge_table, merge_table_size, thread_state, states[i]);
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        // Perform the block reduction.
        block_state = block_reduce_aligned(
            storage.merge_table,
            merge_table_size,
            storage.reduce,
            thread_state
        );
    }

    if (thread_id == 0) {
        output[block_id] = block_state;
    }
}
