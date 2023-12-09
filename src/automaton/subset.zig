const std = @import("std");
const Allocator = std.mem.Allocator;
const Wyhash = std.hash.Wyhash;
const assert = std.debug.assert;
const testing = std.testing;
const automaton = @import("../automaton.zig");
const Nfa = automaton.Nfa;
const Dfa = automaton.Dfa;

/// A type representing a collection of states. This type represents the ephemeral form,
/// bits are typically stored in `StateSet.Storage`.
const StateSet = struct {
    /// The type backing this state set. Technically this bitset is to be used with allocation,
    /// but we can hack around it.
    /// This bitset uses usize for storage; this leads to some waste but its probably fine.
    const BitSet = std.DynamicBitSetUnmanaged;
    /// The type backing the bit set.
    const MaskInt = BitSet.MaskInt;
    /// Each bit indicates whether the state with the corresponding index is present in this set.
    bits: BitSet,

    /// Init a state set by allocating a buffer.
    fn alloc(a: Allocator, states_per_set: usize) !StateSet {
        return StateSet{
            .bits = try BitSet.initEmpty(a, states_per_set),
        };
    }

    /// Deallocate a state set alloc'd by `alloc`.
    fn free(self: *StateSet, a: Allocator) void {
        self.bits.deinit(a);
        self.* = undefined;
    }

    /// Remove all states from this set.
    fn clear(self: *StateSet) void {
        // Hack because there is no clear function in std bitset.
        @memset(self.masks(), 0);
    }

    /// Set that a particular state is in this set.
    fn insert(self: *StateSet, state: Nfa.StateRef) void {
        self.bits.set(state);
    }

    /// Query whether this state set contains a particular state.
    fn contains(self: StateSet, state: Nfa.StateRef) bool {
        return self.bits.isSet(state);
    }

    /// Check if two state sets are equal
    fn eql(a: StateSet, b: StateSet) bool {
        // Padding bits are zeroed by the std implementation anyway.
        return std.mem.eql(MaskInt, a.masks(), b.masks());
    }

    /// Compute a 32-bit hash of this state set
    fn hash(self: StateSet) u32 {
        return @as(u32, @truncate(Wyhash.hash(0, std.mem.sliceAsBytes(self.masks()))));
    }

    /// Return the underlying masks as a slice.
    fn masks(self: StateSet) []MaskInt {
        const bit_length = self.bits.bit_length;
        const masks_len = std.math.divCeil(usize, bit_length, @bitSizeOf(MaskInt)) catch unreachable;
        return self.bits.masks[0..masks_len];
    }

    /// Return whether any state in this state set is an accept state.
    fn isAnyAccepting(self: StateSet, nfa: Nfa) bool {
        var it = self.iterator();
        while (it.next()) |state| {
            if (nfa.states[state].accept)
                return true;
        }

        return false;
    }

    fn iterator(self: StateSet) Iterator {
        return Iterator{ .inner = self.bits.iterator(.{}) };
    }

    const Iterator = struct {
        inner: BitSet.Iterator(.{}),

        fn next(self: *Iterator) ?Nfa.StateRef {
            return if (self.inner.next()) |state|
                @as(Nfa.StateRef, @intCast(state))
            else
                null;
        }
    };

    /// A storage for some number of state sets. This storage:
    /// - stores immutable state sets.
    /// - stores unique state sets.
    /// - insertions are ordered.
    /// - allows querying whether a state set already existed.
    /// - Refs (indices) are stable over insertion.
    const Storage = struct {
        /// A reference to some state set thats currently in a storage.
        /// This is just an into `storage`, divided by the number of words per set.
        const Ref = u32;
        /// An index generator used to map state sets to an index in the `storage` array.
        map: std.AutoArrayHashMapUnmanaged(void, void) = .{},
        /// This arraylist is used to actually store the bits of each state set.
        storage: std.ArrayListUnmanaged(MaskInt) = .{},
        /// The number of states make up a state set.
        states_per_set: usize,

        fn init(states_per_set: usize) Storage {
            return .{
                .states_per_set = states_per_set,
            };
        }

        fn deinit(self: *Storage, a: Allocator) void {
            self.map.deinit(a);
            self.storage.deinit(a);
            self.* = undefined;
        }

        /// Get the StateSet that is associated to some Ref. The return value is
        /// valid until this storage is modified.
        /// The return value should not be modified.
        fn get(self: Storage, ref: Ref) StateSet {
            const masks_per_set = std.math.divCeil(usize, self.states_per_set, @bitSizeOf(MaskInt)) catch unreachable;
            const offset = masks_per_set * ref;
            const bits = BitSet{
                .bit_length = self.states_per_set,
                .masks = self.storage.items[offset..].ptr,
            };
            return .{
                .bits = bits,
            };
        }

        /// Return the number of sets in this storage.
        fn count(self: Storage) usize {
            const masks_per_set = std.math.divCeil(usize, self.states_per_set, @bitSizeOf(MaskInt)) catch unreachable;
            return self.storage.items.len / masks_per_set;
        }

        const InsertResult = struct {
            /// A reference to the newly inserted item.
            ref: Ref,
            /// Whether a new item was inserted.
            found_existing: bool,
        };

        /// Insert a new state set into this storage.
        fn insert(self: *Storage, a: Allocator, set: StateSet) !InsertResult {
            const adapter = Adapter{ .storage = self };
            const result = try self.map.getOrPutAdapted(a, set, adapter);
            if (!result.found_existing) {
                // If the hash map didn't return a value, it created a new slot at the end, and so the indices
                // should correspond.
                try self.storage.appendSlice(a, set.masks());
            }

            return InsertResult{
                .ref = @as(Ref, @intCast(result.index)),
                .found_existing = result.found_existing,
            };
        }

        const Adapter = struct {
            storage: *const Storage,

            pub fn eql(self: @This(), a: StateSet, _: void, b_index: usize) bool {
                const b = self.storage.get(@as(Ref, @intCast(b_index)));
                return StateSet.eql(a, b);
            }

            pub fn hash(_: @This(), set: StateSet) u32 {
                return set.hash();
            }
        };
    };
};

const Context = struct {
    /// The NFA for which were are generating a DFA.
    nfa: Nfa,
    /// The builder for the DFA we are generating.
    b: Dfa.Builder,
    /// The state set storage used to store all the state sets we have encountered so far.
    state_sets: StateSet.Storage,
    /// The number of state sets we have already processed.
    /// Because of the insertion guarantees on StageSet.Storage, we can just take an index to the last
    /// processed element for this.
    queue_index: StateSet.Storage.Ref = 0,
    /// Queue of yet-to-be processed items during closure computation.
    closure_queue: std.fifo.LinearFifo(Nfa.StateRef, .Slice),

    /// Just steal the allocator from the DFA builder.
    fn allocator(self: Context) Allocator {
        return self.b.a;
    }

    /// Add a state set to the internal queue, if it has not been processed before.
    fn enqueue(self: *Context, set: StateSet) !Dfa.StateRef {
        const result = try self.state_sets.insert(self.allocator(), set);
        // Both Dfa.Builder.addState and StateSet.Storage.insert return indices sequentially,
        // so the result.ref corresponds with the Dfa.StateRef.
        const state = @as(Dfa.StateRef, @intCast(result.ref));
        if (!result.found_existing) {
            assert((try self.b.addState(false)) == state);
        }

        return state;
    }

    /// Fetch the next state set from the queue, if any.
    fn next(self: *Context) ?StateSet.Storage.Ref {
        if (self.queue_index < self.state_sets.count()) {
            defer self.queue_index += 1;
            return self.queue_index;
        }

        return null;
    }

    /// Move over all epsilon symbols in a set.
    fn closure(self: *Context, set: *StateSet) void {
        assert(self.closure_queue.readableLength() == 0);

        var it = set.iterator();
        while (it.next()) |state| {
            self.closure_queue.writeItemAssumeCapacity(state);
        }

        while (self.closure_queue.readItem()) |src| {
            for (self.nfa.outgoing(src)) |tx| {
                if (set.contains(tx.dst)) {
                    // Already processed or queued.
                    continue;
                } else if (tx.sym != null) {
                    // Symbols are ordered null first, so we can break early here.
                    break;
                }
                set.insert(tx.dst);
                self.closure_queue.writeItemAssumeCapacity(tx.dst);
            }
        }
    }

    /// Get all outgoing symbols from a set of states
    /// Ignores epsilon-transitions, see `closure`.
    fn follow(self: *Context, set: StateSet) std.StaticBitSet(256) {
        var syms = std.StaticBitSet(256).initEmpty();
        var it = set.iterator();
        while (it.next()) |src| {
            for (self.nfa.outgoing(src)) |tx| {
                if (tx.sym) |sym| {
                    syms.set(sym);
                }
            }
        }

        return syms;
    }

    /// Compute the state set that is generated by moving all states in `set` over `sym`.
    /// Ignores epsilon-transitions, see `closure`.
    fn move(self: *Context, result: *StateSet, set: StateSet, sym: u8) void {
        result.clear();
        var it = set.iterator();
        while (it.next()) |src| {
            for (self.nfa.outgoing(src)) |tx| {
                if (tx.sym != null and sym == tx.sym.?) {
                    result.insert(tx.dst);
                }
            }
        }
    }
};

/// Configuration options that may be passed to `subset.
pub const Options = struct {
    /// Special allocator used for temporary allocations.
    tmp_allocator: ?Allocator = null,
};

/// Perform a subset construction, which transforms an NFA into an equivalent DFA.
/// The final automaton will be allocated using `a`.
pub fn subset(a: Allocator, nfa: Nfa, opts: Options) !Dfa {
    const tmp_allocator = opts.tmp_allocator orelse a;

    // There can't be more items in the queue than that there are states, so just preallocate the maximum required memory.
    const closure_queue_mem = try tmp_allocator.alloc(Nfa.StateRef, nfa.states.len);
    defer tmp_allocator.free(closure_queue_mem);

    var ctx = Context{
        .nfa = nfa,
        .b = Dfa.Builder.init(tmp_allocator),
        .state_sets = StateSet.Storage.init(nfa.states.len),
        .closure_queue = std.fifo.LinearFifo(Nfa.StateRef, .Slice).init(closure_queue_mem),
    };
    defer ctx.b.deinit();
    defer ctx.state_sets.deinit(tmp_allocator);

    var work_set = try StateSet.alloc(tmp_allocator, nfa.states.len);
    defer work_set.free(tmp_allocator);

    // Insert the initial set.
    {
        work_set.insert(Nfa.start);
        ctx.closure(&work_set);
        assert((try ctx.enqueue(work_set)) == Dfa.start);
    }

    // Process the remaining sets.
    while (ctx.next()) |ref| {
        const src = @as(Dfa.StateRef, @intCast(ref));
        const follow_set = ctx.follow(ctx.state_sets.get(ref));

        var it = follow_set.iterator(.{});
        while (it.next()) |bit| {
            const sym = @as(u8, @intCast(bit));
            const set = ctx.state_sets.get(ref); // Re-fetch because it was invalidated in the call to enqueue().
            ctx.move(&work_set, set, sym);
            ctx.closure(&work_set);
            const dst = try ctx.enqueue(work_set);
            try ctx.b.addTransition(src, dst, sym);
        }
    }

    // Finally, figure out which states are accepting.
    for (ctx.b.states.items, 0..) |*state, index| {
        const ref = @as(StateSet.Storage.Ref, @intCast(index));
        const set = ctx.state_sets.get(ref);
        if (set.isAnyAccepting(nfa)) {
            state.accept = true;
        }
    }

    return try ctx.b.build(a);
}

test "subset" {
    var b = Nfa.Builder.init(testing.allocator);
    defer b.deinit();

    const x = try b.addState(false);
    const y = try b.addState(false);
    const z = try b.addState(false);

    try b.addTransition(x, y, null);
    try b.addTransition(y, z, '1');

    var nfa = try b.build(testing.allocator);
    defer nfa.deinit(testing.allocator);

    var dfa = try subset(testing.allocator, nfa, .{});
    defer dfa.deinit(testing.allocator);

    try testing.expect(dfa.states.len == 2);
}
