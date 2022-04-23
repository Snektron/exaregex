/// This engine compiles Patterns to a DFA, and simulates that to check if the input is valid.
const DfaSimulatorEngine = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Pattern = @import("../Pattern.zig");
const automaton = @import("../automaton.zig");
const Dfa = automaton.Dfa;

/// Representation of a pattern after compilation.
pub const CompiledPattern = struct {
    dfa: Dfa,
};

pub fn init() DfaSimulatorEngine {
    return .{};
}

/// Compile a Pattern into an engine-specific representation.
pub fn compilePattern(self: *DfaSimulatorEngine, a: Allocator, pattern: Pattern) !CompiledPattern {
    _ = self;
    var nfa = try automaton.thompson(a, pattern, .{});
    defer nfa.deinit(a);

    const dfa = try automaton.subset(a, nfa, .{});
    return CompiledPattern{
        .dfa = dfa,
    };
}

/// Free the resources owned by a particular compiled pattern. This pattern must be created by
/// the call to `compilePattern` on this same engine instance.
pub fn destroyCompiledPattern(self: *DfaSimulatorEngine, a: Allocator, pattern: CompiledPattern) void {
    _ = self;
    var dfa = pattern.dfa;
    dfa.deinit(a);
}

/// Check if a (compiled) pattern matches a character sequence.
pub fn matches(self: *DfaSimulatorEngine, pattern: CompiledPattern, input: []const u8) bool {
    _ = self;
    var state = Dfa.start;
    for (input) |sym| {
        // TODO: Maybe this could be improved by a LUT instead of a binary search.
        // Increases the memory requirements but makes lookup constant time.
        state = pattern.dfa.getTransitionTarget(state, sym) orelse return false;
    }

    return pattern.dfa.states[state].accept;
}

test "DfaSimulatorEngine" {
    var engine = DfaSimulatorEngine.init();
    try @import("test.zig").testEngine(DfaSimulatorEngine, &engine);
}
