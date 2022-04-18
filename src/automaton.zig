const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// An enum used to configure automaton behavior.
pub const AutomatonKind = enum {
    /// Automaton which does not allow epsilon and duplicate transitions.
    deterministic,
    /// Automaton which deoes allow epsilon and duplicate transitions.
    non_deterministic,
};

pub const DFA = FiniteAutomaton(.deterministic);
pub const NFA = FiniteAutomaton(.non_deterministic);

pub fn FiniteAutomaton(comptime kind: AutomatonKind) type {
    return struct {
        const Self = @This();

        pub const automaton_kind = kind;

        pub const StateRef = u32;
        pub const TransitionRef = u32;

        pub const Symbol = switch (automaton_kind) {
            .deterministic => u8,
            .non_deterministic => ?u8,
        };

        /// This struct represents a state of the state machine.
        pub const State = struct {
            /// The first outgoing transition that is associated to this state,
            /// forms an index into `FiniteAutomaton.transitions`.
            first_transition: TransitionRef,
            /// The number of outgoing transitions that are associated to this state.
            num_transitions: u32,
            /// Whether this is an accepting state.
            accept: bool,
        };

        /// This struct represents a single transition.
        pub const Transition = struct {
            /// The target state.
            dst: StateRef,
            /// The symbol that this transition bears.
            sym: Symbol,
        };

        /// The states which appear in this state machine. States are referenced to using a `StateRef`,
        /// which is just an index into this array.
        states: []State,
        /// The transitions which appear in this state machine. Transitions are referenced to using a
        /// `TransitionRef`, which is just an index into this array. Transitions are ordered in such a way that
        /// all transitions that originate from a particular state are consecutive in memory. Furthermore,
        /// subsequences of transitions that belong to a particular state are ordered by symbol. Note that the
        /// null symbol compares lowest, and so is always ordered first.
        transitions: []Transition,

        pub fn deinit(self: *Self, a: Allocator) void {
            a.free(self.states);
            a.free(self.transitions);
            self.* = undefined;
        }

        pub fn transitionsForState(self: Self, state_ref: StateRef) []Transition {
            const state = self.states[state_ref];
            return self.transitions[state.first_transition .. state.first_transition + state.num_transitions];
        }

        /// Utility function used to order two symbols.
        fn symLessThan(lhs: Symbol, rhs: Symbol) bool {
            switch (automaton_kind) {
                .deterministic => return lhs < rhs,
                .non_deterministic => {
                    // If rhs is null:
                    // - if lhs is also null, we compare equal => return false.
                    // - else, lhs will compare larger => return false.
                    const rhs_val = rhs orelse return false;
                    // If lhs is null at this point, it will always compare smaller since rhs is non-null.
                    const lhs_val = lhs orelse return true;
                    return lhs_val < rhs_val;
                },
            }
        }

        /// A helper utility for building state machines. This type can be used
        /// to create a state machine from a number of transitions, but cannot
        /// be use to perform computations using the state machine.
        pub const Builder = struct {
            /// Type of a state that is under construction.
            const State = struct {
                accept: bool,
            };

            /// Type of a transition that is under construction.
            const Transition = struct {
                /// The source state, an index allocated with `addState`.
                src: StateRef,
                /// The destination state, an index allocated with `addState`.
                dst: StateRef,
                /// The symbol that this transition bears.
                sym: Symbol,
            };

            /// Allocator used during construction. This allocator is not necessarily the
            /// allocator used for the final allocation of the FSA, it is only used
            /// during construction.
            a: Allocator,

            /// The list of states currently in the builder. This arraylist can be indexed
            /// using `StateRef`. Note that this index survives the building process.
            states: std.ArrayListUnmanaged(Builder.State) = .{},
            /// The list of transitions in the builder. This is just
            /// an edge list. Note that at this point, one cannot make a transition
            /// reference that survives the building process.
            transitions: std.ArrayListUnmanaged(Builder.Transition) = .{},

            pub fn init(a: Allocator) Builder {
                return .{.a = a};
            }

            pub fn deinit(self: *Builder) void {
                self.states.deinit(self.a);
                self.transitions.deinit(self.a);
                self.* = undefined;
            }

            /// Add a new state to the state machine.
            pub fn addState(self: *Builder, accept: bool) !StateRef {
                const ref = @intCast(u32, self.states.items.len);
                try self.states.append(self.a, .{.accept = accept});
                return ref;
            }

            /// Add a new transition to the state machine.
            pub fn addTransition(self: *Builder, src: StateRef, dst: StateRef, sym: Symbol) !void {
                assert(self.isValidStateRef(src));
                assert(self.isValidStateRef(dst));
                try self.transitions.append(self.a, .{.src = src, .dst = dst, .sym = sym});
            }

            /// Finalize this state machine and turn it into a proper `FiniteAutomaton`.
            /// After this operation, the Builder is in a valid, empty state, and can be recycled
            /// or `deinit`ialized.
            pub fn build(self: *Builder, a: Allocator) !Self {
                // First, sort the transitions by source node and by symbol so that all transitions
                // are grouped and subsequences are ordered.
                const Ctx = struct {
                    fn lessThan(_: @This(), lhs: Builder.Transition, rhs: Builder.Transition) bool {
                        if (lhs.src != rhs.src) {
                            return lhs.src < rhs.src;
                        }
                        return symLessThan(lhs.sym, rhs.sym);
                    }
                };
                std.sort.sort(Builder.Transition, self.transitions.items, Ctx{}, Ctx.lessThan);

                // The builder has changed now, so be sure to "reset" it when exiting this function,
                // regardless of whether an erro happened.
                defer {
                    self.states.items.len = 0;
                    self.transitions.items.len = 0;
                }

                // Now, group them and construct the final states and transitions arrays.
                const states = try a.alloc(Self.State, self.states.items.len);
                errdefer a.free(states);
                const transitions = try a.alloc(Self.Transition, self.transitions.items.len);
                errdefer a.free(transitions);

                for (self.states.items) |state, i| {
                    states[i] = .{
                        .first_transition = 0,
                        .num_transitions = 0,
                        .accept = state.accept,
                    };
                }

                var first_transition: StateRef = 0;
                var run_len: u32 = 0;
                for (self.transitions.items) |t, i| {
                    transitions[i] = .{.dst = t.dst, .sym = t.sym};
                    run_len += 1;
                    if (i == self.transitions.items.len - 1 or t.src != self.transitions.items[i + 1].src) {
                        states[t.src].first_transition = first_transition;
                        states[t.src].num_transitions = run_len;
                        first_transition = @intCast(u32, i + 1);
                        run_len = 0;
                    }
                }

                return Self{
                    .states = states,
                    .transitions = transitions,
                };
            }

            fn isValidStateRef(self: Builder, ref: StateRef) bool {
                return ref < self.states.items.len;
            }
        };
    };
}

test "DFA.Builder - empty" {
    var builder = DFA.Builder.init(testing.allocator);
    defer builder.deinit();

    var fsa = try builder.build(testing.allocator);
    defer fsa.deinit(testing.allocator);

    try testing.expectEqualSlices(DFA.State, &.{}, fsa.states);

    try testing.expectEqualSlices(DFA.Transition, &.{}, fsa.transitions);
}

test "NFA.Builder - simple" {
    var builder = NFA.Builder.init(testing.allocator);
    defer builder.deinit();

    const a = try builder.addState(false);
    try testing.expect(a == 0);
    const b = try builder.addState(false);
    try testing.expect(b == 1);
    const c = try builder.addState(true);
    try testing.expect(c == 2);

    try builder.addTransition(b, a, '1');
    try builder.addTransition(a, b, '0');
    try builder.addTransition(b, c, null);

    var fsa = try builder.build(testing.allocator);
    defer fsa.deinit(testing.allocator);

    try testing.expectEqualSlices(NFA.State, &.{
        .{.first_transition = 0, .num_transitions = 1, .accept = false},
        .{.first_transition = 1, .num_transitions = 2, .accept = false},
        .{.first_transition = 0, .num_transitions = 0, .accept = true},
    }, fsa.states);

    const expected_transitions = [_]NFA.Transition{
        .{.dst = b, .sym = '0'},
        .{.dst = c, .sym = null},
        .{.dst = a, .sym = '1'},
    };
    try testing.expectEqualSlices(NFA.Transition, &expected_transitions, fsa.transitions);
}
