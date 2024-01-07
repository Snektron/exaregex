const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Wyhash = std.hash.Wyhash;
const automaton = @import("../automaton.zig");
const Dfa = automaton.Dfa;

/// This structure models a 'parallel' dfa: Symbols may be transformed to states
/// regardless of their position and the symbols around them, and consecutive states
/// may be merged in any order to produce the result.
pub const ParallelDfa = struct {
    pub const Symbol = u8;
    pub const StateRef = enum(u32) {
        reject = 0xFFFF_FFFF,
        _, // ((2^32)-)1^2 is still more memory than any computer has anyway...
    };

    /// Maps each symbol to the initial state.
    initial_states: [256]StateRef,
    /// maps pairs of states to the result state.
    /// This is a flattened, square 2D array.
    merges: [*]StateRef,
    /// set bits indicate that a state ref is an accepting state.
    /// .bit_length holds the number of states in this parallel dfa.
    accepting_states: std.DynamicBitSetUnmanaged,
    /// We need a special case for the empty input.
    empty_is_accepting: bool,

    pub fn deinit(self: *ParallelDfa, a: Allocator) void {
        const state_count = self.stateCount();
        a.free(self.merges[0 .. state_count * state_count]);
        self.accepting_states.deinit(a);
        self.* = undefined;
    }

    /// Return the total number of states in this parallel dfa.
    pub fn stateCount(self: ParallelDfa) usize {
        return self.accepting_states.bit_length;
    }

    /// Return the initial state corresponding to some character.
    pub fn initial(self: ParallelDfa, sym: Symbol) StateRef {
        return self.initial_states[sym];
    }

    /// Return the result state of merging any two (consecutive) states.
    pub fn merge(self: ParallelDfa, a: StateRef, b: StateRef) StateRef {
        const i = switch (a) {
            .reject => return .reject,
            else => |x| @intFromEnum(x),
        };
        const j = switch (b) {
            .reject => return .reject,
            else => |x| @intFromEnum(x),
        };

        assert(i < self.stateCount());
        assert(j < self.stateCount());
        return self.merges[i * self.stateCount() + j];
    }

    /// Return whether `state` is an accept state.
    pub fn isAccepting(self: ParallelDfa, state: StateRef) bool {
        return switch (state) {
            .reject => false,
            else => |x| self.accepting_states.isSet(@intFromEnum(x)),
        };
    }
};

/// A square 2D array list, used to store merges during construction.
const MergeTable = struct {
    /// Minimum allocation size of one dimension.
    const min_capacity = 16;
    /// The size of one dimension of the merge table; the number of states currently in it.
    size: u32 = 0,
    /// The allocated size of one dimension of the merge table.
    capacity: u32 = 0,
    /// The actual array of merges.
    merges: [*]ParallelDfa.StateRef = undefined,

    fn deinit(self: MergeTable, a: Allocator) void {
        a.free(self.merges[0 .. self.capacity * self.capacity]);
    }

    /// Resize (grow) the merge table. New entries are initialized with ParallelDfa.reject.
    fn resize(self: *MergeTable, a: Allocator, new_size: u32) !void {
        if (new_size <= self.capacity) {
            // We don't need shrinking, just implement this for style points.
            self.size = new_size;
            return;
        }

        // Crude computation of a better capacity.
        var new_capacity = @max(min_capacity, self.capacity);
        while (new_capacity < new_size) {
            new_capacity *= 2;
        }

        const merges = try a.realloc(self.allocatedSlice(), @as(usize, new_capacity) * new_capacity);
        // Since we are growing, we need to walk back in memory in order to place the items at the new location.
        var i = @as(usize, self.size);
        while (i > 0) {
            i -= 1;
            std.mem.copyBackwards(ParallelDfa.StateRef, merges[i * new_capacity ..], merges[i * self.capacity ..][0..self.size]);
        }

        // Fill in the new entries with the reject state.
        i = 0;
        while (i < self.size) : (i += 1) {
            @memset(merges[i * new_capacity + self.size .. (i + 1) * new_capacity], .reject);
        }
        @memset(merges[i * new_capacity ..], .reject);

        self.size = new_size;
        self.capacity = new_capacity;
        self.merges = merges.ptr;
    }

    /// Add space for a single new state
    fn addOne(self: *MergeTable, a: Allocator) !void {
        try self.resize(a, self.size + 1);
    }

    /// Turn this merge table into a tightly allocated merge table of self.size by self.size elements.
    fn toOwnedSquarray(self: *MergeTable, a: Allocator) ![*]ParallelDfa.StateRef {
        // First pack the items in memory.
        const merges = self.allocatedSlice();
        var i: usize = 0;
        while (i < self.size) : (i += 1) {
            std.mem.copyForwards(ParallelDfa.StateRef, merges[i * self.size ..], merges[i * self.capacity ..][0..self.size]);
        }
        const slice = try a.realloc(merges, @as(usize, self.size) * self.size);
        self.size = 0;
        self.capacity = 0;
        self.merges = undefined;
        return slice.ptr;
    }

    fn allocatedSlice(self: MergeTable) []ParallelDfa.StateRef {
        return self.merges[0 .. @as(usize, self.capacity) * self.capacity];
    }

    /// Set the result state at a combination of states.
    fn set(self: MergeTable, i: ParallelDfa.StateRef, j: ParallelDfa.StateRef, result: ParallelDfa.StateRef) void {
        assert(i != .reject);
        assert(j != .reject);
        self.merges[@as(usize, @intFromEnum(i)) * self.capacity + @intFromEnum(j)] = result;
    }
};

/// This structure represents a collection of states that the state machine may currently be in.
const ParallelState = struct {
    /// A transition that takes a source state to either a destination,
    /// or the reject state.
    const Transition = enum(u32) {
        reject = 0xFFFF_FFFF,
        _,

        fn init(ref: Dfa.StateRef) Transition {
            assert(ref != 0xFFFF_FFFF); // Too many states in state machine.
            return @as(Transition, @enumFromInt(ref));
        }
    };

    /// The outgoing transitions.
    /// This maps each DFA source state to a DFA desintation state.
    transitions: []Transition,

    /// Init a parallel state by allocating a buffer.
    fn alloc(a: Allocator, states_per_parallel_state: usize) !ParallelState {
        return ParallelState{
            .transitions = try a.alloc(Transition, states_per_parallel_state),
        };
    }

    /// Deallocate a parallel state alloc'd by `alloc`.
    fn free(self: *ParallelState, a: Allocator) void {
        a.free(self.transitions);
        self.* = undefined;
    }

    /// Compare this parallel state with another and see if theyre equal.
    fn eql(a: ParallelState, b: ParallelState) bool {
        return std.mem.eql(Transition, a.transitions, b.transitions);
    }

    /// Compute a 32-bit hash for this parallel state.
    fn hash(self: ParallelState) u32 {
        return @as(u32, @truncate(Wyhash.hash(0, std.mem.sliceAsBytes(self.transitions))));
    }

    // Compute the merged state from two source states.
    fn merge(self: *ParallelState, a: ParallelState, b: ParallelState) void {
        for (self.transitions, 0..) |*dst, i| {
            dst.* = switch (a.transitions[i]) {
                .reject => .reject,
                else => |j| b.transitions[@intFromEnum(j)],
            };
        }
    }

    // Check if there are only reject states in this parallel state.
    fn isAlwaysReject(self: ParallelState) bool {
        for (self.transitions) |dst| {
            if (dst != .reject) {
                return false;
            }
        }

        return true;
    }

    /// A storage for some number of parallel states. This storage:
    /// - stores immutable parallel states..
    /// - stores unique parallel states.
    /// - insertions are ordered.
    /// - allows querying whether a parallel state already exists.
    /// - Refs (indices) are stable over insertions.
    const Storage = struct {
        /// A reference to some parallel state that is currently in a storage.
        /// This is just an index into `storage`, divided by the number of states in a parallel state (256).
        const Ref = u32;
        /// An index generator used to map state sets to an index in the `storage` array.
        map: std.AutoArrayHashMapUnmanaged(void, void) = .{},
        /// This arraylist is used to actually store the elements of each state set.
        storage: std.ArrayListUnmanaged(Transition) = .{},
        /// The number of DFA states in a parallel DFA state.
        states_per_parallel_state: u32,

        fn deinit(self: *Storage, a: Allocator) void {
            self.map.deinit(a);
            self.storage.deinit(a);
            self.* = undefined;
        }

        /// Get the StateSet that is associated to some Ref. The return value is
        /// valid until this storage is modified.
        /// The return value should not be modified.
        fn get(self: Storage, ref: Ref) ParallelState {
            return .{
                .transitions = self.storage.items[ref * self.states_per_parallel_state ..][0..self.states_per_parallel_state],
            };
        }

        /// Return the number of parallel states in this storage.
        fn count(self: Storage) usize {
            return self.storage.items.len / self.states_per_parallel_state;
        }

        const InsertResult = struct {
            /// A reference to the newly inserted item.
            ref: Ref,
            /// Whether a new item was inserted.
            found_existing: bool,
        };

        /// Insert a new parallel state into this storage.
        fn insert(self: *Storage, a: Allocator, state: ParallelState) !InsertResult {
            const adapter = Adapter{ .storage = self };
            const result = try self.map.getOrPutAdapted(a, state, adapter);
            if (!result.found_existing) {
                // If the hash map didn't return a value, it created a new slot at the end, and so the indices
                // should correspond.
                try self.storage.appendSlice(a, state.transitions);
            }

            return InsertResult{
                .ref = @as(Ref, @intCast(result.index)),
                .found_existing = result.found_existing,
            };
        }

        const Adapter = struct {
            storage: *const Storage,

            pub fn eql(self: @This(), a: ParallelState, _: void, b_index: usize) bool {
                const b = self.storage.get(@as(Ref, @intCast(b_index)));
                return ParallelState.eql(a, b);
            }

            pub fn hash(_: @This(), a: ParallelState) u32 {
                return a.hash();
            }
        };
    };
};

const Context = struct {
    /// The storage used to store all the parallel states.
    parallel_states: ParallelState.Storage,
    /// The merge table, under construction.
    merge_table: MergeTable = .{},
    /// A temporary parallel state used during merging.
    work_state: ParallelState,

    /// Add a parallel state to the internal queue, if it has not been processed before.
    fn enqueue(self: *Context, a: Allocator, state: ParallelState) !ParallelDfa.StateRef {
        const result = try self.parallel_states.insert(a, state);
        // ParallelState.Storage insert and MergeTable insert sequentially, so the
        // result index corresponds with the ParallelDfa state.
        const result_state = @as(ParallelDfa.StateRef, @enumFromInt(result.ref));
        if (!result.found_existing) {
            assert(self.merge_table.size == result.ref);
            try self.merge_table.addOne(a);
        }

        return result_state;
    }

    /// Merge two states, and enqueue the result.
    fn merge(self: *Context, a: Allocator, i: ParallelState.Storage.Ref, j: ParallelState.Storage.Ref) !void {
        const x = self.parallel_states.get(i);
        const y = self.parallel_states.get(j);
        self.work_state.merge(x, y);
        if (!self.work_state.isAlwaysReject()) { // Don't bother if not required. Merge table is defaulted to reject anyway.
            const result = try self.enqueue(a, self.work_state);
            self.merge_table.set(@as(ParallelDfa.StateRef, @enumFromInt(i)), @as(ParallelDfa.StateRef, @enumFromInt(j)), result);
        }
    }
};

/// Configuration options for the `parallelize` algorithm.
pub const Options = struct {
    /// Limit the number maximum number of states. Memory consumption of the parallel DFA
    /// scales quadratically with this.
    state_limit: u32 = std.math.maxInt(u32),
};

/// Turn a regular DFA into a parallel DFA.
/// Note: Depending on the DFA, this may be a time and memory consuming operation!
/// Some DFAs explode in the total number of states.
pub fn parallelize(a: Allocator, dfa: Dfa, opts: Options) !ParallelDfa {
    const states_per_parallel_state = @as(u32, @intCast(dfa.states.len));
    assert(states_per_parallel_state < 0xFFFF_FFFF); // We use the last value as explicit reject state here.

    var work_state = try ParallelState.alloc(a, states_per_parallel_state);
    defer work_state.free(a);

    var ctx = Context{
        .parallel_states = .{
            .states_per_parallel_state = states_per_parallel_state,
        },
        .work_state = work_state,
    };
    defer ctx.parallel_states.deinit(a);
    defer ctx.merge_table.deinit(a);

    // Insert the initial states, which are guaranteed to map to the symbol with the corresponding index.
    const initial_states = blk: {
        var initial_state_storage = ParallelState.Storage{ .states_per_parallel_state = states_per_parallel_state };
        defer initial_state_storage.deinit(a);
        // Allocate space for the 256 initial states.
        try initial_state_storage.storage.resize(a, states_per_parallel_state * 256);
        @memset(initial_state_storage.storage.items, .reject);

        for (0..dfa.states.len) |i| {
            const src = @as(Dfa.StateRef, @intCast(i));
            for (dfa.outgoing(src)) |tx| {
                const ps = initial_state_storage.get(tx.sym);
                ps.transitions[src] = ParallelState.Transition.init(tx.dst);
            }
        }

        var initial_states = [_]ParallelDfa.StateRef{.reject} ** 256;
        var sym: u32 = 0;
        while (sym < 256) : (sym += 1) {
            const ps = initial_state_storage.get(sym);
            if (!ps.isAlwaysReject()) { // Don't bother if it always rejects.
                initial_states[sym] = try ctx.enqueue(a, ps);
            }
        }

        break :blk initial_states;
    };

    // Repeatedly perform the merges until no new merge is added.
    // Note: careful, we're iterating while also inserting here!
    {
        var i: u32 = 0;
        while (i < ctx.parallel_states.count()) : (i += 1) {
            var j: u32 = 0;
            while (j < ctx.parallel_states.count()) : (j += 1) {
                try ctx.merge(a, i, j);
                try ctx.merge(a, j, i);
                if (ctx.parallel_states.count() > opts.state_limit) {
                    return error.StateLimitReached;
                }
            }
        }
    }

    // To find out of a parallel state is accepting, check if the transition from the start state
    // leads to an accepting state.
    var accepting_states = try std.DynamicBitSetUnmanaged.initEmpty(a, ctx.merge_table.size);
    errdefer accepting_states.deinit(a);
    {
        var i: ParallelState.Storage.Ref = 0;
        while (i < ctx.parallel_states.count()) : (i += 1) {
            const ps = ctx.parallel_states.get(i);
            switch (ps.transitions[Dfa.start]) {
                .reject => {},
                else => |final| if (dfa.states[@intFromEnum(final)].accept) {
                    accepting_states.set(i);
                },
            }
        }
    }

    return ParallelDfa{
        .initial_states = initial_states,
        .merges = try ctx.merge_table.toOwnedSquarray(a),
        .accepting_states = accepting_states,
        .empty_is_accepting = dfa.states[Dfa.start].accept,
    };
}

test "parallelize" {
    _ = parallelize;
}
