const std = @import("std");
const testing = std.testing;
const parsePattern = @import("../parse.zig").parse;

const Case = struct {
    pattern: []const u8,
    accept: []const []const u8,
    reject: []const []const u8,
};

const cases = [_]Case{
    .{
        .pattern = "",
        .accept = &.{""},
        .reject = &.{"a"},
    },
    .{
        .pattern = "abc",
        .accept = &.{"abc"},
        .reject = &.{"", "ab", "abcd"},
    },
    .{
        .pattern = "abc|def",
        .accept = &.{"abc", "def"},
        .reject = &.{"", "ab", "abcd", "abcdef"},
    },
    .{
        .pattern = "a*b",
        .accept = &.{"b", "aaaab"},
        .reject = &.{"ba", "", "c"},
    },
    .{
        .pattern = "a+b",
        .accept = &.{"ab", "aaaaab"},
        .reject = &.{"", "b", "abc"},
    },
    .{
        .pattern = "a(bc)*a",
        .accept = &.{"aa", "abca", "abcbcbca"},
        .reject = &.{"", "abc", "abcbc"},
    },
    .{
        .pattern = "ab?c?d",
        .accept = &.{"ad", "abd", "acd", "abcd"},
        .reject = &.{"", "ab", "abc", "abcde"},
    },
    .{
        .pattern = "a.b",
        .accept = &.{"abb", "a b"},
        .reject = &.{"a\nb"},
    },
    .{
        .pattern = "a[bdh]c",
        .accept = &.{"abc", "adc", "ahc"},
        .reject = &.{"ac", "acc"},
    },
    .{
        .pattern = "a[bd-h]c",
        .accept = &.{"abc", "adc", "ahc"},
        .reject = &.{"acc", "akc"},
    },
    .{
        .pattern = "a[^bx]c",
        .accept = &.{"acc", "adc"},
        .reject = &.{"abc", "axc"},
    },
    .{
        .pattern = "a[^b-l]c",
        .accept = &.{"aac", "amc"},
        .reject = &.{"abc", "alc"},
    },
    .{
        .pattern = "[A-Za-z_][A-Za-z0-9_]*",
        .accept = &.{"test", "test123", "_test_", "_1234"},
        .reject = &.{"@test", "test$", "123test"},
    },
    .{
        .pattern = "0[Xx][0-9A-Fa-f]+|0[Bb][01]+|[0-9]+",
        .accept = &.{"123", "0xABC123", "0b1101", "0B11", "0X0"},
        .reject = &.{"_123", "0xX", "0b123", "0o123", "123AB"},
    },
    .{
        .pattern = "((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.)((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.)((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.)(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)",
        .accept = &.{"127.0.0.1", "255.26.011.000"},
        .reject = &.{"abc", "123.123.123.123.123", "256."},
    },
};

pub fn testEngine(comptime Engine: type, engine: *Engine) !void {
    var fail = false;
    for (cases) |test_case| {
        var pattern = switch (try parsePattern(testing.allocator, test_case.pattern)) {
            .err => |err| {
                std.debug.print("Error parsing test regex '{s}': {} at offset {}\n", .{test_case.pattern, err.err, err.offset});
                unreachable;
            },
            .pattern => |pattern| pattern,
        };
        defer pattern.deinit(testing.allocator);

        const compiled = try engine.compilePattern(testing.allocator, pattern);
        defer engine.destroyCompiledPattern(testing.allocator, compiled);

        for (test_case.accept) |test_input| {
            if (!engine.matches(compiled, test_input)) {
                std.debug.print("Testing regex '{s}' against input '{s}' yields reject, expected accept\n", .{
                    test_case.pattern,
                    test_input,
                });
                fail = true;
            }
        }

        for (test_case.reject) |test_input| {
            if (engine.matches(compiled, test_input)) {
                std.debug.print("Testing regex '{s}' against input '{s}' yields accept, expected reject\n", .{
                    test_case.pattern,
                    test_input,
                });
                fail = true;
            }
        }
    }
    if (fail) {
        return error.InvalidMatchResult;
    }
}
