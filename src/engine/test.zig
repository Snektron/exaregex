const std = @import("std");
const testing = std.testing;
const parsePattern = @import("../parse.zig").parse;

pub fn testEngine(comptime Engine: type, engine: *Engine) !void {
    var pattern = switch (try parsePattern(testing.allocator, "a*b")) {
        .err => unreachable,
        .pattern => |pattern| pattern,
    };
    defer pattern.deinit(testing.allocator);

    const compiled = try engine.compilePattern(testing.allocator, pattern);
    defer engine.destroyCompiledPattern(testing.allocator, compiled);

    try testing.expect(engine.matches(compiled, "b"));
    try testing.expect(engine.matches(compiled, "aaaab"));
    try testing.expect(!engine.matches(compiled, "ba"));
    try testing.expect(!engine.matches(compiled, ""));
    try testing.expect(!engine.matches(compiled, "c"));
}
