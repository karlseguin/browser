// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const parser = @import("browser/netsurf.zig");

pub const allocator = std.testing.allocator;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;
pub const expectEqualSlices = std.testing.expectEqualSlices;

const App = @import("app.zig").App;

// Merged std.testing.expectEqual and std.testing.expectString
// can be useful when testing fields of an anytype an you don't know
// exactly how to assert equality
pub fn expectEqual(expected: anytype, actual: anytype) !void {
    switch (@typeInfo(@TypeOf(actual))) {
        .array => |arr| if (arr.child == u8) {
            return std.testing.expectEqualStrings(expected, &actual);
        },
        .pointer => |ptr| {
            if (ptr.child == u8) {
                return std.testing.expectEqualStrings(expected, actual);
            } else if (comptime isStringArray(ptr.child)) {
                return std.testing.expectEqualStrings(expected, actual);
            } else if (ptr.child == []u8 or ptr.child == []const u8) {
                return expectString(expected, actual);
            }
        },
        .@"struct" => |structType| {
            inline for (structType.fields) |field| {
                try expectEqual(@field(expected, field.name), @field(actual, field.name));
            }
            return;
        },
        .optional => {
            if (@typeInfo(@TypeOf(expected)) == .null) {
                return std.testing.expectEqual(null, actual);
            }
            return expectEqual(expected, actual.?);
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("Unable to compare untagged union values");
            }
            const Tag = std.meta.Tag(@TypeOf(expected));

            const expectedTag = @as(Tag, expected);
            const actualTag = @as(Tag, actual);
            try expectEqual(expectedTag, actualTag);

            inline for (std.meta.fields(@TypeOf(actual))) |fld| {
                if (std.mem.eql(u8, fld.name, @tagName(actualTag))) {
                    try expectEqual(@field(expected, fld.name), @field(actual, fld.name));
                    return;
                }
            }
            unreachable;
        },
        else => {},
    }
    return std.testing.expectEqual(expected, actual);
}

pub fn expectDelta(expected: anytype, actual: anytype, delta: anytype) !void {
    if (@typeInfo(@TypeOf(expected)) == .null) {
        return std.testing.expectEqual(null, actual);
    }

    switch (@typeInfo(@TypeOf(actual))) {
        .optional => {
            if (actual) |value| {
                return expectDelta(expected, value, delta);
            }
            return std.testing.expectEqual(null, expected);
        },
        else => {},
    }

    switch (@typeInfo(@TypeOf(expected))) {
        .optional => {
            if (expected) |value| {
                return expectDelta(value, actual, delta);
            }
            return std.testing.expectEqual(null, actual);
        },
        else => {},
    }

    var diff = expected - actual;
    if (diff < 0) {
        diff = -diff;
    }
    if (diff <= delta) {
        return;
    }

    print("Expected {} to be within {} of {}. Actual diff: {}", .{ expected, delta, actual, diff });
    return error.NotWithinDelta;
}

fn isStringArray(comptime T: type) bool {
    if (!is(.array)(T) and !isPtrTo(.array)(T)) {
        return false;
    }
    return std.meta.Elem(T) == u8;
}

pub const TraitFn = fn (type) bool;
pub fn is(comptime id: std.builtin.TypeId) TraitFn {
    const Closure = struct {
        pub fn trait(comptime T: type) bool {
            return id == @typeInfo(T);
        }
    };
    return Closure.trait;
}

pub fn isPtrTo(comptime id: std.builtin.TypeId) TraitFn {
    const Closure = struct {
        pub fn trait(comptime T: type) bool {
            if (!comptime isSingleItemPtr(T)) return false;
            return id == @typeInfo(std.meta.Child(T));
        }
    };
    return Closure.trait;
}

pub fn isSingleItemPtr(comptime T: type) bool {
    if (comptime is(.pointer)(T)) {
        return @typeInfo(T).pointer.size == .one;
    }
    return false;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else {
        std.debug.print(fmt, args);
    }
}

// dummy opts incase we want to add something, and not have to break all the callers
pub fn app(_: anytype) *App {
    return App.init(allocator, .{ .run_mode = .serve }) catch unreachable;
}

pub const Random = struct {
    var instance: ?std.Random.DefaultPrng = null;

    pub fn fill(buf: []u8) void {
        var r = random();
        r.bytes(buf);
    }

    pub fn fillAtLeast(buf: []u8, min: usize) []u8 {
        var r = random();
        const l = r.intRangeAtMost(usize, min, buf.len);
        r.bytes(buf[0..l]);
        return buf;
    }

    pub fn intRange(comptime T: type, min: T, max: T) T {
        var r = random();
        return r.intRangeAtMost(T, min, max);
    }

    pub fn random() std.Random {
        if (instance == null) {
            var seed: u64 = undefined;
            std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
            instance = std.Random.DefaultPrng.init(seed);
            // instance = std.Random.DefaultPrng.init(0);
        }
        return instance.?.random();
    }
};

pub const Document = struct {
    doc: *parser.Document,
    arena: std.heap.ArenaAllocator,

    pub fn init(html: []const u8) !Document {
        parser.deinit();
        try parser.init();

        var fbs = std.io.fixedBufferStream(html);
        const html_doc = try parser.documentHTMLParse(fbs.reader(), "utf-8");

        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .doc = parser.documentHTMLToDocument(html_doc),
        };
    }

    pub fn deinit(self: *Document) void {
        parser.deinit();
        self.arena.deinit();
    }

    pub fn querySelectorAll(self: *Document, selector: []const u8) ![]const *parser.Node {
        const css = @import("browser/dom/css.zig");
        const node_list = try css.querySelectorAll(self.arena.allocator(), parser.documentToNode(self.doc), selector);
        return node_list.nodes.items;
    }

    pub fn querySelector(self: *Document, selector: []const u8) !?*parser.Node {
        const css = @import("browser/dom/css.zig");
        return css.querySelector(self.arena.allocator(), parser.documentToNode(self.doc), selector);
    }
};

pub const JsRunner = struct {
    const Env = @import("browser/env.zig").Env;
    const URL = @import("browser/url/url.zig").URL;
    const Loop = @import("runtime/loop.zig").Loop;
    const HttpClient = @import("http/client.zig").Client;
    const storage = @import("browser/storage/storage.zig");
    const Window = @import("browser/html/window.zig").Window;
    const SessionState = @import("browser/env.zig").SessionState;
    const Location = @import("browser/html/location.zig").Location;

    env: *Env,
    loop: Loop,
    url: URL,
    window: Window,
    location: Location,
    state: SessionState,
    http_client: HttpClient,
    executor: *Env.Executor,
    buf: [1024 * 64]u8,
    storage_shelf: storage.Shelf,
    cookie_jar: storage.CookieJar,
    fba: std.heap.FixedBufferAllocator,

    fn init(opts: RunnerOpts) !*JsRunner {
        parser.deinit();
        try parser.init();

        const runner = try allocator.create(JsRunner);
        errdefer allocator.destroy(runner);

        runner.buf = undefined;
        runner.fba = std.heap.FixedBufferAllocator.init(&runner.buf);

        const aa = runner.fba.allocator();

        runner.env = try Env.init(aa, .{});
        errdefer runner.env.deinit();

        runner.cookie_jar = storage.CookieJar.init(aa);
        runner.loop = try Loop.init(aa);
        errdefer runner.loop.deinit();

        var html = std.io.fixedBufferStream(opts.html);
        const document = try parser.documentHTMLParse(html.reader(), "UTF-8");

        runner.state = .{
            .arena = aa,
            .loop = &runner.loop,
            .document = document,
            .uri = undefined, // we'll set this a few lines down
            .cookie_jar = &runner.cookie_jar,
            .http_client = &runner.http_client,
        };

        runner.window = Window.create(null, null);
        try runner.window.replaceDocument(document);

        runner.url = try URL.constructor(&runner.state, "https://lightpanda.io/opensource-browser/", null);
        runner.state.uri = runner.url.uri;
        runner.location = .{ .url = &runner.url };
        try runner.window.replaceLocation(&runner.location);

        runner.storage_shelf = storage.Shelf.init(aa);
        runner.window.setStorageShelf(&runner.storage_shelf);

        // don't use fba here, since our http client pre-allocates large buffers
        runner.http_client = try HttpClient.init(allocator, 1, .{
            .tls_verify_host = false,
        });

        runner.executor = try runner.env.startExecutor(Window, &runner.state, runner);
        errdefer runner.env.stopExecutor(runner.executor);

        try runner.executor.startScope(&runner.window);
        return runner;
    }

    pub fn deinit(self: *JsRunner) void {
        self.executor.endScope();
        self.http_client.deinit();
        self.loop.deinit();
        self.env.deinit();
        self.storage_shelf.deinit();

        allocator.destroy(self);
        // everything else is allocated in our FixedBufferAlloctor
    }

    const RunOpts = struct {};
    pub const Case = std.meta.Tuple(&.{ []const u8, []const u8 });
    pub fn testCases(self: *JsRunner, cases: []const Case, _: RunOpts) !void {
        for (cases, 0..) |case, i| {
            var try_catch: Env.TryCatch = undefined;
            try_catch.init(self.executor);
            defer try_catch.deinit();

            const value = self.executor.exec(case.@"0", null) catch |err| {
                if (try try_catch.err(self.fba.allocator())) |msg| {
                    std.debug.print("{s}\n\nCase: {d}\n{s}\n", .{ msg, i + 1, case.@"0" });
                }
                return err;
            };
            try self.loop.run();

            const actual = try value.toString(self.fba.allocator());
            if (std.mem.eql(u8, case.@"1", actual) == false) {
                std.debug.print("Expected:\n{s}\n\nGot:\n{s}\n\nCase: {d}\n{s}\n", .{ case.@"1", actual, i + 1, case.@"0" });
                return error.UnexpectedResult;
            }
        }
    }

    pub fn exec(self: *JsRunner, src: []const u8) !void {
        var try_catch: Env.TryCatch = undefined;
        try_catch.init(self.executor);
        defer try_catch.deinit();
        _ = self.executor.exec(src, null) catch |err| {
            if (try try_catch.err(self.fba.allocator())) |msg| {
                std.debug.print("Error runnign script: {s}\n", .{msg});
            }
            return err;
        };
    }

    pub fn fetchModuleSource(ctx: *anyopaque, specifier: []const u8) ![]const u8 {
        _ = ctx;
        _ = specifier;
        return error.DummyModuleLoader;
    }
};

const RunnerOpts = struct {
    html: []const u8 =
        \\ <div id="content">
        \\   <a id="link" href="foo" class="ok">OK</a>
        \\   <p id="para-empty" class="ok empty">
        \\     <span id="para-empty-child"></span>
        \\   </p>
        \\   <p id="para"> And</p>
        \\   <!--comment-->
        \\ </div>
        \\
    ,
};

pub fn jsRunner(opts: RunnerOpts) !*JsRunner {
    return JsRunner.init(opts);
}
