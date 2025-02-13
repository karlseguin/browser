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

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const query = @import("query.zig");

pub const Interfaces = .{
    URL,
    URLSearchParams,
};

// https://url.spec.whatwg.org/#url
//
// TODO we could avoid many of these getter string allocation in two differents
// way:
//
// 1. We can eventually get the slice of scheme *with* the following char in
// the underlying string. But I don't know if it's possible and how to do that.
// I mean, if the rawuri contains `https://foo.bar`, uri.scheme is a slice
// containing only `https`. I want `https:` so, in theory, I don't need to
// allocate data, I should be able to retrieve the scheme + the following `:`
// from rawuri.
//
// 2. The other way would bu to copy the `std.Uri` code to ahve a dedicated
// parser including the characters we want for the web API.
pub const URL = struct {
    rawuri: []const u8,
    uri: std.Uri,
    search_params: URLSearchParams,

    pub const mem_guarantied = true;

    pub fn constructor(alloc: std.mem.Allocator, url: []const u8, base: ?[]const u8) !URL {
        const normalized = std.mem.trim(u8, url, &std.ascii.whitespace);
        const raw = try std.mem.concat(alloc, u8, &[_][]const u8{ normalized, base orelse "" });
        errdefer alloc.free(raw);

        const uri = std.Uri.parse(raw) catch {
            return error.TypeError;
        };

        return .{
            .rawuri = raw,
            .uri = uri,
            .search_params = try URLSearchParams.constructor(
                alloc,
                uriComponentNullStr(uri.query),
            ),
        };
    }

    pub fn deinit(self: *URL, alloc: std.mem.Allocator) void {
        self.search_params.deinit(alloc);
        alloc.free(self.rawuri);
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_origin(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();

        try self.uri.writeToStream(.{
            .scheme = true,
            .authentication = false,
            .authority = true,
            .path = false,
            .query = false,
            .fragment = false,
        }, buf.writer());
        return try buf.toOwnedSlice();
    }

    // get_href returns the URL by writing all its components.
    // The query is replaced by a dump of search params.
    //
    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_href(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        // retrieve the query search from search_params.
        const cur = self.uri.query;
        defer self.uri.query = cur;
        var q = std.ArrayList(u8).init(alloc);
        defer q.deinit();
        try self.search_params.values.encode(q.writer());
        self.uri.query = .{ .percent_encoded = q.items };

        return try self._toString(alloc);
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_protocol(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        return try std.mem.concat(alloc, u8, &[_][]const u8{ self.uri.scheme, ":" });
    }

    pub fn get_username(self: *URL) []const u8 {
        return uriComponentNullStr(self.uri.user);
    }

    pub fn get_password(self: *URL) []const u8 {
        return uriComponentNullStr(self.uri.password);
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_host(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();

        try self.uri.writeToStream(.{
            .scheme = false,
            .authentication = false,
            .authority = true,
            .path = false,
            .query = false,
            .fragment = false,
        }, buf.writer());
        return try buf.toOwnedSlice();
    }

    pub fn get_hostname(self: *URL) []const u8 {
        return uriComponentNullStr(self.uri.host);
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_port(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        if (self.uri.port == null) return try alloc.dupe(u8, "");

        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();

        try std.fmt.formatInt(self.uri.port.?, 10, .lower, .{}, buf.writer());
        return try buf.toOwnedSlice();
    }

    pub fn get_pathname(self: *URL) []const u8 {
        if (uriComponentStr(self.uri.path).len == 0) return "/";
        return uriComponentStr(self.uri.path);
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_search(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        if (self.search_params.get_size() == 0) return try alloc.dupe(u8, "");

        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(alloc);

        try buf.append(alloc, '?');
        try self.search_params.values.encode(buf.writer(alloc));
        return buf.toOwnedSlice(alloc);
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_hash(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        if (self.uri.fragment == null) return try alloc.dupe(u8, "");

        return try std.mem.concat(alloc, u8, &[_][]const u8{ "#", uriComponentNullStr(self.uri.fragment) });
    }

    pub fn get_searchParams(self: *URL) *URLSearchParams {
        return &self.search_params;
    }

    pub fn _toJSON(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        return try self._toString(alloc);
    }

    pub fn _toString(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();

        try self.uri.writeToStream(.{
            .scheme = true,
            .authentication = true,
            .authority = true,
            .path = uriComponentNullStr(self.uri.path).len > 0,
            .query = uriComponentNullStr(self.uri.query).len > 0,
            .fragment = uriComponentNullStr(self.uri.fragment).len > 0,
        }, buf.writer());
        return try buf.toOwnedSlice();
    }
};

// uriComponentNullStr converts an optional std.Uri.Component to string value.
// The string value can be undecoded.
fn uriComponentNullStr(c: ?std.Uri.Component) []const u8 {
    if (c == null) return "";

    return uriComponentStr(c.?);
}

fn uriComponentStr(c: std.Uri.Component) []const u8 {
    return switch (c) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
}

// https://url.spec.whatwg.org/#interface-urlsearchparams
// TODO array like
pub const URLSearchParams = struct {
    values: query.Values,

    pub const mem_guarantied = true;

    pub fn constructor(alloc: std.mem.Allocator, init: ?[]const u8) !URLSearchParams {
        return .{
            .values = try query.parseQuery(alloc, init orelse ""),
        };
    }

    pub fn deinit(self: *URLSearchParams, _: std.mem.Allocator) void {
        self.values.deinit();
    }

    pub fn get_size(self: *URLSearchParams) u32 {
        return @intCast(self.values.count());
    }

    pub fn _append(self: *URLSearchParams, name: []const u8, value: []const u8) !void {
        try self.values.append(name, value);
    }

    pub fn _delete(self: *URLSearchParams, name: []const u8, value: ?[]const u8) !void {
        if (value) |v| return self.values.deleteValue(name, v);

        self.values.delete(name);
    }

    pub fn _get(self: *URLSearchParams, name: []const u8) ?[]const u8 {
        return self.values.first(name);
    }

    // TODO return generates an error: caught unexpected error 'TypeLookup'
    // pub fn _getAll(self: *URLSearchParams, name: []const u8) [][]const u8 {
    //     try self.values.get(name);
    // }

    // TODO
    pub fn _sort(_: *URLSearchParams) void {}
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var url = [_]Case{
        .{ .src = "var url = new URL('https://foo.bar/path?query#fragment')", .ex = "undefined" },
        .{ .src = "url.origin", .ex = "https://foo.bar" },
        .{ .src = "url.href", .ex = "https://foo.bar/path?query#fragment" },
        .{ .src = "url.protocol", .ex = "https:" },
        .{ .src = "url.username", .ex = "" },
        .{ .src = "url.password", .ex = "" },
        .{ .src = "url.host", .ex = "foo.bar" },
        .{ .src = "url.hostname", .ex = "foo.bar" },
        .{ .src = "url.port", .ex = "" },
        .{ .src = "url.pathname", .ex = "/path" },
        .{ .src = "url.search", .ex = "?query" },
        .{ .src = "url.hash", .ex = "#fragment" },
        .{ .src = "url.searchParams.get('query')", .ex = "" },
    };
    try checkCases(js_env, &url);

    var qs = [_]Case{
        .{ .src = "var url = new URL('https://foo.bar/path?a=~&b=%7E#fragment')", .ex = "undefined" },
        .{ .src = "url.searchParams.get('a')", .ex = "~" },
        .{ .src = "url.searchParams.get('b')", .ex = "~" },
        .{ .src = "url.searchParams.append('c', 'foo')", .ex = "undefined" },
        .{ .src = "url.searchParams.get('c')", .ex = "foo" },
        .{ .src = "url.searchParams.size", .ex = "3" },

        // search is dynamic
        .{ .src = "url.search", .ex = "?a=%7E&b=%7E&c=foo" },
        // href is dynamic
        .{ .src = "url.href", .ex = "https://foo.bar/path?a=%7E&b=%7E&c=foo#fragment" },

        .{ .src = "url.searchParams.delete('c', 'foo')", .ex = "undefined" },
        .{ .src = "url.searchParams.get('c')", .ex = "" },
        .{ .src = "url.searchParams.delete('a')", .ex = "undefined" },
        .{ .src = "url.searchParams.get('a')", .ex = "" },
    };
    try checkCases(js_env, &qs);
}

const testing = std.testing;
test "URL: constructor invalid" {
    const expectError = struct {
        fn expect(url: []const u8, base: ?[]const u8) !void {
            const actual = URL.constructor(testing.allocator, url, base);
            try testing.expectError(error.TypeError, actual);
        }
    }.expect;

    try expectError("", null);
    try expectError("http", null);
    try expectError("ht|tp://l", null);
    try expectError("ht%tp://l", null);
    try expectError("ht^tp://l", null);
    try expectError("ht tp://l", null);

    // TODO: compat, these should not be valid
    // try expectError("http:", null);
    // try expectError("http://local>host/", null);
    // try expectError("http://local%host/", null);

    // TODO: compat, base URL must be a full URL
    // try expectError("http://l", "");
    // try expectError("http://l", "/");
}

test "URL: constructor protocol and host" {
    const expectURL = struct {
        const Expected = struct {
            protocol: []const u8,
            host: []const u8,
            port: []const u8,
            path: []const u8,
        };

        fn expect(expected: Expected, url: []const u8) !void {
            const allocator = testing.allocator;
            var u = try URL.constructor(allocator, url, null);
            defer u.deinit(allocator);

            const protocol = try u.get_protocol(allocator);
            defer allocator.free(protocol);
            try testing.expectEqualStrings(expected.protocol, protocol);

            const host = try u.get_host(allocator);
            defer allocator.free(host);
            try testing.expectEqualStrings(expected.host, host);

            const port = try u.get_port(allocator);
            defer allocator.free(port);
            try testing.expectEqualStrings(expected.port, port);

            const path = u.get_pathname();
            try testing.expectEqualStrings(expected.path, path);
        }
    }.expect;

    // all these should result in the same protocol/host/port/pathname
    for ([_][]const u8{
        "http://localhost", "http://localhost/", "  http://localhost\t",
        "http://@localhost",
        // TODO: compat
        // these don't pass because of Zig's std.URI
        // "http://localhost:", "http://localhost:/", //"http://@localhost:",
        // "http:///localhost", "  http:///localhost:/\t",
    }) |url| {
        try expectURL(.{ .protocol = "http:", .host = "localhost", .port = "", .path = "/" }, url);
    }

    // TODO: compat
    // try expectURL(.{
    //     .protocol = "http:",
    //     .host = "%20",
    //     .port = "",
    //     .path = "//hello"
    // }, "http: //hello");

    // TODO: compat
    // try expectURL(.{
    //     .protocol = "http:",
    //     .host = "over%209000!",
    //     .port = "",
    //     .path = "/what"
    // }, "http://over 9000!/what");

    // TODO : compat
    // try expectURL(.{
    //     .protocol = "http:",
    //     .host = "over9000",
    //     .port = "",
    //     .path = "/what"
    // }, "http://over\t9000/wh\nat");

    // TODO: compat
    // these don't pass because of Zig's std.URI
    // "http://localhost:", "http://localhost:/", //"http://@localhost:",
    // "http:///localhost", "  http:///localhost:/\t",
    // These "special" schemes should should not support empty hosts, but FF
    // and Chrome are both flexible and not only allow empty hosts, they also
    // allow other variants.
    // inline for ([_][]const u8{"ftp", "http", "https", "ws", "wss"}) |scheme| {
    //     // http:/127.0.0.1 (single slash)
    //     try expectURL(.{
    //         .protocol = scheme ++ ":",
    //         .host = "127.0.01",
    //         .port = "",
    //         .path = "/"
    //     }, scheme ++ ":/127.0.0.1");

    //     // http:///127.0.0.1 (empty hosts, but treated as normal URL)
    //     try expectURL(.{
    //         .protocol = scheme ++ ":",
    //         .host = "127.0.01",
    //         .port = "",
    //         .path = "/"
    //     }, scheme ++ ":///127.0.0.1");

    //     // http:////127.0.0.1 (more slashes, but treated as normal URL)
    //     try expectURL(.{
    //         .protocol = scheme ++ ":",
    //         .host = "127.0.01",
    //         .port = "",
    //         .path = "/"
    //     }, scheme ++ ":////127.0.0.1");
    // }

    try expectURL(.{ .protocol = "file:", .host = "", .port = "", .path = "/tmp/a" }, "file:///tmp/a");

    try expectURL(.{ .protocol = "file:", .host = "over", .port = "", .path = "/9000" }, "file://over/9000");

    try expectURL(.{ .protocol = "ht.tp:", .host = "a.a", .port = "", .path = "/b.b" }, "ht.tp://a.a/b.b");

    // TODO: compat
    // try expectURL(.{
    //     .protocol = "other:",
    //     .host = "",
    //     .port = "",
    //     .path = ""
    // }, "other://");

    // TODO: compat
    // only a "special" prtocol has a default path of "/"
    // try expectURL(.{
    //     .protocol = "other:",
    //     .host = "a",
    //     .port = "",
    //     .path = ""
    // }, "other://a");
}

test "URL: constructor base" {
    const expect = struct {
        const Expected = struct {
            host: []const u8,
            path: []const u8,
        };

        fn expectURL(expected: Expected, url: []const u8, base: ?[]const u8) !void {
            const allocator = testing.allocator;
            var u = try URL.constructor(allocator, url, base);
            defer u.deinit(allocator);

            const host = try u.get_host(allocator);
            defer allocator.free(host);
            try testing.expectEqualStrings(expected.host, host);

            const path = u.get_pathname();
            try testing.expectEqualStrings(expected.path, path);
        }
    }.expectURL;
    _ = expect;
}
