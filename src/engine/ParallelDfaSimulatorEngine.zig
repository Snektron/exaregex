/// This engine compiles Patterns to a Parallel DFA, and simulates that sequentially to check if the input is valid.
const ParallelDfaSimulatorEngine = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Pattern = @import("../Pattern.zig");
const automaton = @import("../automaton.zig");
const ParallelDfa = automaton.parallel.ParallelDfa;

/// Representation of a pattern after compilation.
pub const CompiledPattern = struct {
    pdfa: ParallelDfa,
};

pub fn init() ParallelDfaSimulatorEngine {
    return .{};
}

pub fn deinit(self: *ParallelDfaSimulatorEngine) void {
    _ = self;
}

/// Compile a Pattern into an engine-specific representation.
pub fn compilePattern(self: *ParallelDfaSimulatorEngine, a: Allocator, pattern: Pattern) !CompiledPattern {
    _ = self;
    var nfa = try automaton.thompson(a, pattern, .{});
    defer nfa.deinit(a);

    var dfa = try automaton.subset(a, nfa, .{});
    defer dfa.deinit(a);

    const pdfa = try automaton.parallelize(a, dfa, .{});
    return CompiledPattern{
        .pdfa = pdfa,
    };
}

/// Free the resources owned by a particular compiled pattern. This pattern must be created by
/// the call to `compilePattern` on this same engine instance.
pub fn destroyCompiledPattern(self: *ParallelDfaSimulatorEngine, a: Allocator, pattern: CompiledPattern) void {
    _ = self;
    var pdfa = pattern.pdfa;
    pdfa.deinit(a);
}

/// Check if a (compiled) pattern matches a character sequence.
pub fn matches(self: *ParallelDfaSimulatorEngine, pattern: CompiledPattern, input: []const u8) bool {
    _ = self;
    const pdfa = pattern.pdfa;

    if (input.len == 0) {
        return pdfa.empty_is_accepting;
    }

    var state = pdfa.initial(input[0]);
    for (input[1..]) |sym| {
        state = pdfa.merge(state, pdfa.initial(sym));
    }

    return pdfa.isAccepting(state);
}

test "ParallelDfaSimulatorEngine" {
    var engine = ParallelDfaSimulatorEngine.init();
    defer engine.deinit();

    try @import("test.zig").testEngine(ParallelDfaSimulatorEngine, &engine);
}
