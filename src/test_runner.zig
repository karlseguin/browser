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
const builtin = @import("builtin");

pub const Types = @import("main.zig").Types;
pub const UserContext = @import("main.zig").UserContext;
pub const IO = @import("main.zig").IO;

pub fn main() !void {
    const out = std.io.getStdOut().writer();

    for (builtin.test_functions) |t| {
        t.func() catch |err| {
            try std.fmt.format(out, "{s} fail: {}\n", .{t.name, err});
            continue;
        };
        try std.fmt.format(out, "{s} passed\n", .{t.name});
    }
}
