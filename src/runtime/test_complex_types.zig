// Copyright 2023-2024 Lightpanda (Selecy SAS)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const Allocator = std.mem.Allocator;

const MyList = struct {
    items: []u8,

    pub fn constructor(state: State, elem1: u8, elem2: u8, elem3: u8) MyList {
        var items = state.arena.alloc(u8, 3) catch unreachable;
        items[0] = elem1;
        items[1] = elem2;
        items[2] = elem3;
        return .{ .items = items };
    }

    pub fn _first(self: *const MyList) u8 {
        return self.items[0];
    }

    pub fn _symbol_iterator(self: *const MyList) IterableU8 {
        return IterableU8.init(self.items);
    }
};

const MyVariadic = struct {
    member: u8,

    pub fn constructor() MyVariadic {
        return .{ .member = 0 };
    }

    pub fn _len(_: *const MyVariadic, variadic: []bool) u64 {
        return @as(u64, variadic.len);
    }

    pub fn _first(_: *const MyVariadic, _: []const u8, variadic: []bool) bool {
        return variadic[0];
    }

    pub fn _last(_: *const MyVariadic, variadic: []bool) bool {
        return variadic[variadic.len - 1];
    }

    pub fn _empty(_: *const MyVariadic, _: []bool) bool {
        return true;
    }

    pub fn _myListLen(_: *const MyVariadic, variadic: []*const MyList) u8 {
        return @as(u8, @intCast(variadic.len));
    }

    pub fn _myListFirst(_: *const MyVariadic, variadic: []*const MyList) ?u8 {
        if (variadic.len == 0) return null;
        return variadic[0]._first();
    }
};

const MyErrorUnion = struct {
    pub fn constructor(is_err: bool) !MyErrorUnion {
        if (is_err) return error.MyError;
        return .{};
    }

    pub fn get_withoutError(_: *const MyErrorUnion) !u8 {
        return 0;
    }

    pub fn get_withError(_: *const MyErrorUnion) !u8 {
        return error.MyError;
    }

    pub fn set_withoutError(_: *const MyErrorUnion, _: bool) !void {}

    pub fn set_withError(_: *const MyErrorUnion, _: bool) !void {
        return error.MyError;
    }

    pub fn _funcWithoutError(_: *const MyErrorUnion) !void {}

    pub fn _funcWithError(_: *const MyErrorUnion) !void {
        return error.MyError;
    }
};

pub const MyException = struct {
    err: ErrorSet,

    const errorNames = [_][]const u8{
        "MyCustomError",
    };
    const errorMsgs = [_][]const u8{
        "Some custom message.",
    };
    fn errorStrings(comptime i: usize) []const u8 {
        return errorNames[0] ++ ": " ++ errorMsgs[i];
    }

    // interface definition

    pub const ErrorSet = error{
        MyCustomError,
    };

    pub fn init(_: Allocator, err: anyerror, _: []const u8) !MyException {
        return .{ .err = @as(ErrorSet, @errorCast(err)) };
    }

    pub fn get_name(self: *const MyException) []const u8 {
        return switch (self.err) {
            ErrorSet.MyCustomError => errorNames[0],
        };
    }

    pub fn get_message(self: *const MyException) []const u8 {
        return switch (self.err) {
            ErrorSet.MyCustomError => errorMsgs[0],
        };
    }

    pub fn _toString(self: *const MyException) []const u8 {
        return switch (self.err) {
            ErrorSet.MyCustomError => errorStrings(0),
        };
    }
};

const MyTypeWithException = struct {
    pub const Exception = MyException;

    pub fn constructor() MyTypeWithException {
        return .{};
    }

    pub fn _withoutError(_: *const MyTypeWithException) MyException.ErrorSet!void {}

    pub fn _withError(_: *const MyTypeWithException) MyException.ErrorSet!void {
        return MyException.ErrorSet.MyCustomError;
    }

    pub fn _superSetError(_: *const MyTypeWithException) !void {
        return MyException.ErrorSet.MyCustomError;
    }

    pub fn _outOfMemory(_: *const MyTypeWithException) !void {
        return error.OutOfMemory;
    }
};

const IterableU8 = Iterable(u8);

pub fn Iterable(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        index: usize = 0,

        pub fn init(items: []T) Self {
            return .{ .items = items };
        }

        pub const Return = struct {
            value: ?T,
            done: bool,
        };

        pub fn _next(self: *Self) Return {
            if (self.items.len > self.index) {
                const val = self.items[self.index];
                self.index += 1;
                return .{ .value = val, .done = false };
            } else {
                return .{ .value = null, .done = true };
            }
        }
    };
}

const State = struct {
    arena: Allocator,
};

const testing = @import("testing.zig");
test "JS: complex types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var runner = try testing.Runner(State, void, .{
        MyList,
        IterableU8,
        MyVariadic,
        MyErrorUnion,
        MyException,
        MyTypeWithException,
    }).init(.{ .arena = arena.allocator() }, {});

    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let myList = new MyList(1, 2, 3);", "undefined" },
        .{ "myList.first();", "1" },
        .{ "let iter = myList[Symbol.iterator]();", "undefined" },
        .{ "iter.next().value;", "1" },
        .{ "iter.next().value;", "2" },
        .{ "iter.next().value;", "3" },
        .{ "iter.next().done;", "true" },
        .{ "let arr = Array.from(myList);", "undefined" },
        .{ "arr.length;", "3" },
        .{ "arr[0];", "1" },
    }, .{});

    try runner.testCases(&.{
        .{ "let myVariadic = new MyVariadic();", "undefined" },
        .{ "myVariadic.len(true, false, true)", "3" },
        .{ "myVariadic.first('a_str', true, false, true, false)", "true" },
        .{ "myVariadic.last(true, false)", "false" },
        .{ "myVariadic.empty()", "true" },
        .{ "myVariadic.myListLen(myList)", "1" },
        .{ "myVariadic.myListFirst(myList)", "1" },
    }, .{});

    try runner.testCases(&.{
        .{ "var myErrorCstr = ''; try {new MyErrorUnion(true)} catch (error) {myErrorCstr = error}; myErrorCstr", "Error: MyError" },
        .{ "let myErrorUnion = new MyErrorUnion(false);", "undefined" },
        .{ "myErrorUnion.withoutError", "0" },
        .{ "var myErrorGetter = ''; try {myErrorUnion.withError} catch (error) {myErrorGetter = error}; myErrorGetter", "Error: MyError" },
        .{ "myErrorUnion.withoutError = true", "true" },
        .{ "var myErrorSetter = ''; try {myErrorUnion.withError = true} catch (error) {myErrorSetter = error}; myErrorSetter", "Error: MyError" },
        .{ "myErrorUnion.funcWithoutError()", "undefined" },
        .{ "var myErrorFunc = ''; try {myErrorUnion.funcWithError()} catch (error) {myErrorFunc = error}; myErrorFunc", "Error: MyError" },
    }, .{});

    try runner.testCases(&.{
        .{ "MyException.prototype.__proto__ === Error.prototype", "true" },
        .{ "let myTypeWithException = new MyTypeWithException();", "undefined" },
        .{ "myTypeWithException.withoutError()", "undefined" },
        .{ "var myCustomError = ''; try {myTypeWithException.withError()} catch (error) {myCustomError = error}", "MyCustomError: Some custom message." },
        .{ "myCustomError instanceof MyException", "true" },
        .{ "myCustomError instanceof Error", "true" },
        .{ "var mySuperError = ''; try {myTypeWithException.superSetError()} catch (error) {mySuperError = error}", "MyCustomError: Some custom message." },
        .{ "var oomError = ''; try {myTypeWithException.outOfMemory()} catch (error) {oomError = error}; oomError", "Error: out of memory" },
    }, .{});
}
