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
    if (a == 255 || b == 255) {
        return 255;
    }
    return merge_table[a * merge_table_size + b];
}

stateref_t block_reduce_aligned(
    local stateref_t* merge_table,
    int merge_table_size,
    local stateref_t* storage,
    stateref_t thread_result
) {
    int thread_id = get_local_id(0);
    storage[thread_id] = thread_result;
    barrier(CLK_LOCAL_MEM_FENCE);
    for (int i = 1; i < BLOCK_SIZE; i <<= 1) {
        if (thread_id & i) {
            thread_result = merge(
                merge_table,
                merge_table_size,
                storage[thread_id - i],
                thread_result
            );
        }
        barrier(CLK_LOCAL_MEM_FENCE);
        storage[thread_id] = thread_result;
        barrier(CLK_LOCAL_MEM_FENCE);
    }
    return storage[BLOCK_SIZE - 1];
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
        if (thread_id < num_valid_items && thread_id >= i) {
             thread_result = merge(
                merge_table,
                merge_table_size,
                storage[thread_id - i],
                thread_result
            );
        }
        barrier(CLK_LOCAL_MEM_FENCE);
        storage[thread_id] = thread_result;
        barrier(CLK_LOCAL_MEM_FENCE);
    }
    return storage[num_valid_items - 1];
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

kernel void match(
    constant stateref_t* initial_table,
    constant stateref_t* merge_table,
    int merge_table_size,
    constant unsigned char* input,
    int input_size,
    global stateref_t* reduce_exchange
) {
    int block_id = get_group_id(0);
    int thread_id = get_local_id(0);
    int global_id = get_global_id(0);
    int number_of_blocks = get_num_groups(0);
    bool is_last_block = block_id == number_of_blocks - 1;

    local union {
        stateref_t initial_table[256];
        struct {
            stateref_t merge_table[32768 - 256];
            stateref_t reduce[BLOCK_SIZE];
        };
    } storage;

    // Read the initial and merge tables into their local storage.
    // Assume that BLOCK_SIZE divides 256 evenly.
    for (int i = 0; i < 256; i += BLOCK_SIZE) {
        storage.initial_table[i + thread_id] = initial_table[i + thread_id];
    }

    stateref_t block_result;
    if (is_last_block) {
        unsigned char in[ITEMS_PER_THREAD];
        for (int i = 0; i < ITEMS_PER_THREAD; ++i) {
            if (global_id * ITEMS_PER_THREAD + i < input_size) {
                in[i] = input[global_id * ITEMS_PER_THREAD + i];
            }
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        // Apply the initial mapping of characters to states.
        stateref_t states[ITEMS_PER_THREAD];
        for (int i = 0; i < ITEMS_PER_THREAD; ++i) {
            if (global_id * ITEMS_PER_THREAD + i < input_size) {
                states[i] = storage.initial_table[in[i]];
            } else {
                states[i] = 255;
            }
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        // Load the merge table into storage - we dont need the initial table anymore now.
        // Assume that BLOCK_SIZE divides 256 evenly.
        for (int i = 0; i < 32768 - 256; i += BLOCK_SIZE) {
            storage.merge_table[i + thread_id] = merge_table[i + thread_id];
        }

        barrier(CLK_LOCAL_MEM_FENCE);
        // Perform the local reduction
        stateref_t local_result_state = states[0];
        for (int i = 1; i < ITEMS_PER_THREAD; ++i) {
            if (global_id * ITEMS_PER_THREAD + i < input_size) {
                local_result_state = merge(storage.merge_table, merge_table_size, local_result_state, states[i]);
            }
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        // Perform the block reduction.
        int valid_items_in_block = (input_size - BLOCK_SIZE * (number_of_blocks - 1)) / ITEMS_PER_THREAD;
        block_result = block_reduce_limit(
            storage.merge_table,
            merge_table_size,
            storage.reduce,
            local_result_state,
            valid_items_in_block
        );
    } else {
        // TODO: block transposed load?
        unsigned char in[ITEMS_PER_THREAD];
        for (int i = 0; i < ITEMS_PER_THREAD; ++i) {
            in[i] = input[global_id * ITEMS_PER_THREAD + i];
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        // Apply the initial mapping of characters to states.
        stateref_t states[ITEMS_PER_THREAD];
        for (int i = 0; i < ITEMS_PER_THREAD; ++i) {
            states[i] = storage.initial_table[in[i]];
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        // Load the merge table into storage - we dont need the initial table anymore now.
        // Assume that BLOCK_SIZE divides 256 evenly.
        for (int i = 0; i < 32768 - 256; i += BLOCK_SIZE) {
            storage.merge_table[i + thread_id] = merge_table[i + thread_id];
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        // Perform the local reduction
        stateref_t local_result_state = states[0];
        for (int i = 1; i < ITEMS_PER_THREAD; ++i) {
            local_result_state = merge(storage.merge_table, merge_table_size, local_result_state, states[i]);
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        // Perform the block reduction.
        block_result = block_reduce_aligned(
            storage.merge_table,
            merge_table_size,
            storage.reduce,
            local_result_state
        );
    }

    // TODO: Global reduce, but test with one block for now.

    if (thread_id == 0) {
        reduce_exchange[block_id] = block_result;
    }

    input_size = (input_size + ITEMS_PER_BLOCK - 1) / ITEMS_PER_BLOCK;
    // TODO: process ITEMS_PER_BLOCK instead of ITEMS_PER_THREAD
    while (input_size > 1 && block_id * BLOCK_SIZE < input_size) {
        barrier(CLK_GLOBAL_MEM_FENCE);
        int valid_in_block = min(BLOCK_SIZE, input_size - BLOCK_SIZE * block_id);
        bool thread_valid = thread_id < valid_in_block;
        stateref_t state = thread_valid ? reduce_exchange[global_id] : 255;
        state = block_reduce(storage.merge_table, merge_table_size, storage.reduce, state, valid_in_block);
        barrier(CLK_GLOBAL_MEM_FENCE);
        if (thread_id == 0) {
            reduce_exchange[block_id] = state;
        }

        input_size = (input_size + BLOCK_SIZE - 1) / BLOCK_SIZE;
    }
}
