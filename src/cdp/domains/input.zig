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
const Page = @import("../../browser/browser.zig").Page;

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        dispatchMouseEvent,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .dispatchMouseEvent => return dispatchMouseEvent(cmd),
    }
}

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-dispatchMouseEvent
fn dispatchMouseEvent(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        x: i32,
        y: i32,
        type: Type,

        const Type = enum {
            mousePressed,
            mouseReleased,
            mouseMoved,
            mouseWheel,
        };
    })) orelse return error.InvalidParams;

    try cmd.sendResult(null, .{});

    // quickly ignore types we know we don't handle
    switch (params.type) {
        .mouseMoved, .mouseWheel => return,
        else => {},
    }

    const bc = cmd.browser_context orelse return;
    const page = bc.session.currentPage() orelse return;

    const mouse_event = Page.MouseEvent{
        .x = params.x,
        .y = params.y,
        .type = switch (params.type) {
            .mousePressed => .pressed,
            .mouseReleased => .released,
            else => unreachable,
        },
    };
    const click_result = (try page.mouseEvent(cmd.arena, mouse_event)) orelse return;

    switch (click_result) {
        .navigate => |uri| try clickNavigate(cmd, uri),
    }
    // result already sent
}

fn clickNavigate(cmd: anytype, uri: std.Uri) !void {
    const bc = cmd.browser_context.?;

    var url_buf: std.ArrayListUnmanaged(u8) = .{};
    try uri.writeToStream(.{
        .scheme = true,
        .authentication = true,
        .authority = true,
        .port = true,
        .path = true,
        .query = true,
    }, url_buf.writer(cmd.arena));
    const url = url_buf.items;

    try cmd.sendEvent("Page.frameRequestedNavigation", .{
        .url = url,
        .frameId = bc.target_id.?,
        .reason = "anchorClick",
        .disposition = "currentTab",
    }, .{ .session_id = bc.session_id.? });

    bc.session.removePage();
    _ = try bc.session.createPage(null);

    try @import("page.zig").navigateToUrl(cmd, url, false);
}
