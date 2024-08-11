const std = @import("std");
const testing = std.testing;
const parsePattern = @import("../parse.zig").parse;

const DfaSimulatorEngine = @import("DfaSimulatorEngine.zig");

const Case = struct {
    pattern: []const u8,
    accept: []const []const u8,
    reject: []const []const u8,
};

const utf8tests = Case{
    .pattern = "(([\\x00-\\x7F])|([\\xC2-\\xDF][\\x80-\\xBF])|((([\\xE0][\\xA0-\\xBF])|([\\xE1-\\xEC\\xEE-\\xEF][\\x80-\\xBF])|([\\xED][\\x80-\\x9F]))[\\x80-\\xBF])|((([\\xF0][\\x90-\\xBF])|([\\xF1-\\xF3][\\x80-\\xBF])|([\\xF4][\\x80-\\x8F]))[\\x80-\\xBF][\\x80-\\xBF]))*",
    // From https://github.com/flenniken/utf8tests/
    .reject = &.{
        " !!#$\xfe",
        "123\xed\xa0\x801",
        "123\xef\x80",
        "123\xef\x80\xf0",
        "789\xfe",
        "78\xfe",
        "7\xff",
        " \x00 \xff",
        " \x80",
        " \x80 ",
        "\x80",
        "\x80",
        "\x80",
        "\x80 ",
        "\x80\x81\x82\x83\x84\x85\x86\x87",
        "\x80\xbf",
        "\x80\xbf\x80",
        "\x80\xbf\x80\xbf",
        "\x80\xbf\x80\xbf\x80",
        "\x80\xbf\x80\xbf\x80\xbf",
        "\x81",
        "\x81 ",
        "\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f",
        "\x90\x91\x92\x93\x94\x95\x96\x97",
        "\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f",
        "\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7",
        "\xa8\xa9\xaa\xab\xac\xad\xae\xaf",
        "\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7",
        "\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf",
        "\xbf",
        "\xc0",
        "\xc0\x80",
        "\xc0\xaf",
        "\xc0\xaf\xe0\x80\xbf\xf0\x81\x82A",
        "\xc0 \xc1 \xc2 \xc3 ",
        "\xc1 ",
        "\xc1\xbf",
        "\xc2AB",
        "\xc2\x00",
        "\xc2\x7f",
        "\xc2\xc0",
        "\xc2\xff",
        "\xc4 \xc5 \xc6 \xc7 ",
        "\xc8 \xc9 \xca \xcb ",
        "\xcc \xcd \xce \xcf ",
        "\xd0 \xd1 \xd2 \xd3 ",
        "\xd4 \xd5 \xd6 \xd7 ",
        "\xd8 \xd9 \xda \xdb ",
        "\xdc \xdd \xde \xdf ",
        "\xdf",
        "\xdf\x00",
        "\xdf\x7f",
        "\xdf\xc0",
        "\xdf\xff",
        "\xe0\x80",
        "\xe0\x80\x00",
        "\xe0\x80\x7f",
        "\xe0\x80\x80",
        "\xe0\x80\xaf",
        "\xe0\x80\xc0",
        "\xe0\x80\xff",
        "\xe0\x9f\xbf",
        "\xe0 \xe1 \xe2 \xe3 ",
        "\xe1\x80\xe2\xf0\x91\x92\xf1\xbfA",
        "\xe4 \xe5 \xe6 \xe7 ",
        "\xe8 \xe9 \xea \xeb ",
        "\xec \xed \xee \xef ",
        "\xed\x80\x00",
        "\xed\x80\x7f",
        "\xed\x80\xc0",
        "\xed\x80\xff",
        "\xed\xa0\x80",
        "\xed\xa0\x805",
        "\xed\xa0\x80\xed\xb0\x80",
        "\xed\xa0\x80\xed\xbf\xbf",
        "\xed\xa0\x80\xed\xbf\xbf\xed\xafA",
        "\xed\xad\xbf",
        "\xed\xad\xbf\xed\xb0\x80",
        "\xed\xad\xbf\xed\xbf\xbf",
        "\xed\xae\x80",
        "\xed\xae\x80\xed\xb0\x80",
        "\xed\xae\x80\xed\xbf\xbf",
        "\xed\xaf\xbf",
        "\xed\xaf\xbf\xed\xb0\x80",
        "\xed\xaf\xbf\xed\xbf\xbf",
        "\xed\xb0\x80",
        "\xed\xbe\x80",
        "\xed\xbf\xbf",
        "\xef\xbf",
        "\xef\xbf\xbd\xef\xbf\xbd=\xe0\x80.",
        "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd=\xe0\x80\xaf.",
        "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd=\xed\xa0\x80.",
        "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd=\xe0\x80\xe0\x80.",
        "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd=\xf0\x80\x80\x80.",
        "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd=\xf7\xbf\xbf\xbf.",
        "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd=\xf0\x80\x80.",
        "\xef\xbf\xbd=\xff.",
        "\xf0\x80\x80",
        "\xf0\x80\x80\x80",
        "\xf0\x80\x80\xaf",
        "\xf0\x8f\xbf\xbf",
        "\xf0\x90\x80\x00",
        "\xf0\x90\x80\x7f",
        "\xf0\x90\x80\xc0",
        "\xf0\x90\x80\xff",
        "\xf0 \xf1 ",
        "\xf1\x80\x80\x00",
        "\xf1\x80\x80\x7f",
        "\xf1\x80\x80\xc0",
        "\xf1\x80\x80\xff",
        "\xf2 \xf3 ",
        "\xf4\x80\x80\x00",
        "\xf4\x80\x80\x7f",
        "\xf4\x80\x80\xc0",
        "\xf4\x80\x80\xff",
        "\xf4\x90\x80\x80",
        "\xf4\x91\x92\x93\xffA\x80\xbfB",
        "\xf4 \xf5 ",
        "\xf5 ",
        "\xf6 \xf7 ",
        "\xf7\xbf\xbf",
        "\xf7\xbf\xbf",
        "\xf7\xbf\xbf\xbf",
        "\xf7\xbf\xbf\xbf\xbf",
        "\xf7\xbf\xbf\xbf\xbf\xbf",
        "\xf7\xbf\xbf\xbf\xbf\xbf\xbf",
        "\xf8 ",
        "\xf8\x80\x80\x80",
        "\xf8\x80\x80\x80\xaf",
        "\xf8\x87\xbf\xbf\xbf",
        "\xf8\x88\x80\x80\x80",
        "\xf9 ",
        "\xfa ",
        "\xfb ",
        "\xfb\xbf\xbf\xbf",
        "\xfc ",
        "\xfc\x80\x80\x80\x80",
        "\xfc\x80\x80\x80\x80\xaf",
        "\xfc\x84\x80\x80\x80\x80",
        "\xfd ",
        "\xfd\xbf\xbf\xbf\xbf",
        " !!#\xfe ",
        "\xfe",
        "\xff",
        "\xff ",
    },
    .accept = &.{
        "/",
        "/",
        "1",
        "abc",
        "replacement character=\xef\xbf\xbd=\xef\xbf\xbd.",
        " \x00",
        "\x00",
        " \x005",
        "\x7f",
        "\xc2\x80",
        "\xc2\x80",
        "\xc2\x81",
        "\xc2\x82",
        "\xc2\xa9",
        "\xdf\xbf",
        "\xe0\xa0\x80",
        "\xe0\xa0\x80",
        "\xe2\x80\x90",
        "\xee\x80\x80",
        "\xef\xb7\x90",
        "\xef\xb7\x91",
        "\xef\xb7\x92",
        "\xef\xb7\x93",
        "\xef\xb7\x94",
        "\xef\xb7\x95",
        "\xef\xb7\x96",
        "\xef\xb7\x97",
        "\xef\xb7\x98",
        "\xef\xb7\x99",
        "\xef\xb7\x9a",
        "\xef\xb7\x9b",
        "\xef\xb7\x9c",
        "\xef\xb7\x9d",
        "\xef\xb7\x9e",
        "\xef\xb7\x9f",
        "\xef\xbf\xbd",
        "\xef\xbf\xbe",
        "\xef\xbf\xbe=\xef\xbf\xbe.",
        "\xef\xbf\xbf",
        "\xef\xbf\xbf",
        "\xef\xbf\xbf=\xef\xbf\xbf.",
        "\xf0\x90\x80\x80",
        "\xf0\x9d\x92\x9c",
        "\xf0\x9f\xbf\xbe",
        "\xf0\x9f\xbf\xbf",
        "\xf0\xaf\xbf\xbe",
        "\xf0\xaf\xbf\xbf",
        "\xf0\xbf\xbf\xbe",
        "\xf0\xbf\xbf\xbf",
        "\xf1\x8f\xbf\xbe",
        "\xf1\x8f\xbf\xbf",
        "\xf1\x9f\xbf\xbe",
        "\xf1\x9f\xbf\xbf",
        "\xf1\xaf\xbf\xbe",
        "\xf1\xaf\xbf\xbf",
        "\xf1\xbf\xbf\xbe",
        "\xf1\xbf\xbf\xbf",
        "\xf2\x8f\xbf\xbe",
        "\xf2\x8f\xbf\xbf",
        "\xf2\x9f\xbf\xbe",
        "\xf2\x9f\xbf\xbf",
        "\xf2\xaf\xbf\xbe",
        "\xf2\xaf\xbf\xbf",
        "\xf2\xbf\xbf\xbe",
        "\xf2\xbf\xbf\xbf",
        "\xf3\x8f\xbf\xbe",
        "\xf3\x8f\xbf\xbf",
        "\xf3\x9f\xbf\xbe",
        "\xf3\x9f\xbf\xbf",
        "\xf3\xaf\xbf\xbe",
        "\xf3\xaf\xbf\xbf",
        "\xf3\xbf\xbf\xbe",
        "\xf3\xbf\xbf\xbf",
        "\xf4\x8f\xbf\xbe",
        "\xf4\x8f\xbf\xbf",
        "\xf4\x8f\xbf\xbf",
        "\xf4\x8f\xbf\xbf",
    },
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
        .reject = &.{ "", "ab", "abcd" },
    },
    .{
        .pattern = "abc|def",
        .accept = &.{ "abc", "def" },
        .reject = &.{ "", "ab", "abcd", "abcdef" },
    },
    .{
        .pattern = "a*b",
        .accept = &.{ "b", "aaaab" },
        .reject = &.{ "ba", "", "c" },
    },
    .{
        .pattern = "a+b",
        .accept = &.{ "ab", "aaaaab" },
        .reject = &.{ "", "b", "abc" },
    },
    .{
        .pattern = "a(bc)*a",
        .accept = &.{ "aa", "abca", "abcbcbca" },
        .reject = &.{ "", "abc", "abcbc" },
    },
    .{
        .pattern = "ab?c?d",
        .accept = &.{ "ad", "abd", "acd", "abcd" },
        .reject = &.{ "", "ab", "abc", "abcde" },
    },
    .{
        .pattern = "a.b",
        .accept = &.{ "abb", "a b" },
        .reject = &.{"a\nb"},
    },
    .{
        .pattern = "a[bdh]c",
        .accept = &.{ "abc", "adc", "ahc" },
        .reject = &.{ "ac", "acc" },
    },
    .{
        .pattern = "a[bd-h]c",
        .accept = &.{ "abc", "adc", "ahc" },
        .reject = &.{ "acc", "akc" },
    },
    .{
        .pattern = "a[^bx]c",
        .accept = &.{ "acc", "adc" },
        .reject = &.{ "abc", "axc" },
    },
    .{
        .pattern = "a[^b-l]c",
        .accept = &.{ "aac", "amc" },
        .reject = &.{ "abc", "alc" },
    },
    .{
        .pattern = "[A-Za-z_][A-Za-z0-9_]*",
        .accept = &.{ "test", "test123", "_test_", "_1234" },
        .reject = &.{ "@test", "test$", "123test" },
    },
    .{
        .pattern = "0[Xx][0-9A-Fa-f]+|0[Bb][01]+|[0-9]+",
        .accept = &.{ "123", "0xABC123", "0b1101", "0B11", "0X0" },
        .reject = &.{ "_123", "0xX", "0b123", "0o123", "123AB" },
    },
    utf8tests,
    // TODO: Large automatons for OpenCL / HIP
    // .{
    //     .pattern = "((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.)((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.)((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.)(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)",
    //     .accept = &.{ "127.0.0.1", "255.26.011.000" },
    //     .reject = &.{ "abc", "123.123.123.123.123", "256." },
    // },
};

pub fn testEngine(comptime Engine: type, engine: *Engine) !void {
    try testEngineCases(Engine, engine);
}

pub fn testEngineCases(comptime Engine: type, engine: *Engine) !void {
    var fail = false;
    for (cases) |test_case| {
        if (test_case.pattern.len == 0) {
            // TODO: OpenCL engine support
            continue;
        }

        var pattern = switch (try parsePattern(testing.allocator, test_case.pattern)) {
            .err => |err| {
                std.debug.print("Error parsing test regex '{s}': {} at offset {}\n", .{ test_case.pattern, err.err, err.offset });
                unreachable;
            },
            .pattern => |pattern| pattern,
        };
        defer pattern.deinit(testing.allocator);

        const compiled = try engine.compilePattern(testing.allocator, pattern);
        defer engine.destroyCompiledPattern(testing.allocator, compiled);

        for (test_case.accept) |test_input| {
            if (test_input.len == 0) {
                // TODO: OpenCL engine support
                continue;
            }
            if (!try engine.matches(compiled, test_input)) {
                std.debug.print("Testing regex '{s}' against input '{s}' yields reject, expected accept\n", .{
                    test_case.pattern,
                    test_input,
                });
                fail = true;
            }
        }

        for (test_case.reject) |test_input| {
            if (test_input.len == 0) {
                // TODO: OpenCL engine support
                continue;
            }

            if (try engine.matches(compiled, test_input)) {
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

pub fn testEngineFuzzUtf8(comptime Engine: type, engine: *Engine) !void {
    const a = testing.allocator;

    var pattern = switch (try parsePattern(a, utf8tests.pattern)) {
        .err => |err| {
            std.debug.print("Error parsing test regex '{s}': {} at offset {}\n", .{ utf8tests.pattern, err.err, err.offset });
            unreachable;
        },
        .pattern => |pattern| pattern,
    };
    defer pattern.deinit(a);

    var dfa_engine = DfaSimulatorEngine.init();
    defer dfa_engine.deinit();
    const dfa = try dfa_engine.compilePattern(a, pattern);
    defer dfa_engine.destroyCompiledPattern(a, dfa);

    const compiled = try engine.compilePattern(a, pattern);
    defer engine.destroyCompiledPattern(a, compiled);

    const size = 1024 * 1024 * 8;
    const input = try a.alloc(u8, size);
    defer a.free(input);

    var seeds = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));

    for (0..100) |i| {
        const seed = seeds.random().int(usize);
        var rng = std.Random.DefaultPrng.init(seed);
        var random = rng.random();
        const accept = dfa_engine.generateRandom(dfa, &random, input);
        const match = try engine.matches(compiled, input);
        std.debug.print("case {}: {s} (expected {s})\n", .{ i, if (match) "accept" else "reject", if (accept) "accept" else "reject" });
        if (match != accept) {
            std.debug.print("case {}: invalid utf-8 match result with seed {}\n", .{i, seed});
            // std.debug.print("input: {s}\n", .{input});
            std.debug.print("expected valid: {}\n", .{accept});
            return error.InvalidMatchResult;
        }
    }
}
