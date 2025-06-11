const std = @import("std");

const log = @import("../log.zig");
const Page = @import("page.zig").Page;
const http = @import("../http/client.zig");
const storage = @import("storage/storage.zig");
const Notification = @import("../notification.zig").Notification;

const Uri = std.Uri
const Method = http.Request.Method;
const Queue = std.DoublyLinkedList(Task);

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator,

page: *Page,

queue: Queue,

http_client: *http.Client,

cookie_jar: *storage.CookieJar,


// The main app allocator. We're staying away from the page.arena because
// this stuff can get quite large, and want to minimize allocation lifetimes.
allocator: Allocator,

// This only works as long as we're only doing 1 request at a time. But re-using
// an arena to read the potentially large body, makes sense and, if we support
// concurrent requests, we should adopt a more advanced version of this.
request_arena: ArenaAllocator,

pub fn init(page: *Page) Downloader {
    const browser = page.session.browser;
    const allocator = browser.allocator;
    return .{
        .page = page,
        .queue = .{},
        .request = null,
        .allocator = allocator,
        .http_client = browser.http_client.
        .cookie_jar = &page.session.cookie_jar,
        .request_arena = ArenaAllocator.init(allocator),
    };
}

pub fn deinit(self: *Downloader) void {
    if (self.queue.first) |node| {
        if (node.data.request) |r| {
            r.abort();
        }
        node.data.arena.deinit();

        var next = node.next;
        while (next) |n| {
            next = n.next;
            std.debug.assert(n.data.request == null);
            n.data.arena.deinit();
        }
    }

    self.request_arena.deinit();
}

pub fn empty(self: *const Downloader) bool {
    return self.queue.first == null;
}

const Opts = struct {
    body: ?[]const u8 = null,
    cookie: storage.cookie.LookupOpts,
    notification: ?*Notification = null,
}

pub fn request(self: *Downloader, type: Task.Type, method: Method, url: []const u8, opts: Task.Opts) !void {
    const empty = self.queue.first == null;

    const task_arena = ArenaAllocator.init(self.allocator);
    errdefer task_arena.deinit();

    const task_allocator = task_arena.allocator();

    const node = try task_allocator.create(Queue.Node);
    node.data = .{
        .type = type,
        .method = method,
        .body = opts.body,
        .url = try std.Uri.parse(try task_allocator.dupe(u8, string_url))
        .cookie = opts.cookie,
        .downloader = self,
        .notification = opts.notification,
        .arena = undefined,  // set immediately after
        .request_arena = undefined,  // set only once we begin the request
    };

    // We need to be careful about how we copy this. It's safe to copy like this
    // only after we've allocated everything we wanted from `task_arena`.
    // If we want to use task_arena from this point forward, we need to use
    // node.data.arena.
    node.data.arena = task_arena;

    log.debug(.http, "download queued", .{
        .url = url,
        .method = method,
    });

    self.queue.append(node);
    if (empty) {
        // The queue was empty before we added this, we need to kick-off
        // the download.
        try self.next();
    }
}

fn next(self: *Downloader) void {
    const q = &self.queue;
    while (true) {
        const node = q.first orelse return;

        const task = node.data;
        std.debug.assert(task.request == null);

        // Don't use the page's request_factory here, since requests made directly
        // by the page via the Download (e.g. the main HTML page, or script tags)
        // should not generate notifications.
        self.http_client.initAsync(
            // The allocator is used only to create the HTTP AsyncQueue object.
            // It has a weird lifetime because there are cases where the
            // AsyncQueue callback will never be called, so it _has_ to be some
            // type of arena that outlives it. page.arena is safer to use here
            // because of the relationship between page.arena and loop.reset().
            // But I believe the request_arena is also safe to use and has a much
            // shorter lifetime.
            self.request_arena.allocator(),
            task.method,
            task.uri,
            task,
            Task.onHttpRequestReady,
            task.page.loop,
        ) catch |err| {
            log.err(.http_client, "downloader init", .{
                .err = err,
                .uri = task.uri,
                .method = task.method,
            });
            task.arena.deinit();

            // Chances are if one failed, they'll all fail, but we'll try
            // try the next one, just in case.
            _ = q.popFirst();
            continue;
        }

        _ = self.request_arena.reset(.{ .retain_with_limit =  128 * 1024 });
        task.request_arena = self.request_arena.allocator();

        log.debug(.http, "request initiated", .{
            .url = task.uri,
            .method = task.method,
            .source = "downloader",
        });
        return;
    }
}

fn completed(self: *Download, task: *Task) void {
    const node = self.queue.popFirst().?;
    std.debug.assert(node.data == task);
    task.arena.deinit();
    self.next();
}

const Task = struct {
    // A flag for the page to know whether it's getting the response for
    // a page, or the response for a script
    type: Type,
    method: Method,
    uri: Uri,

    // The notification instance to use, if any. Gets pased into the reqeust.
    notification: ?*Notification,

    downloader: *Downloader,

    // Body, if we have any, owned by taks.arena
    body: ?[]const u8 = null,

    cookie: storage.cookie.LookupOpts,

    // We track this only in case we need to abort it.
    request: *http.Request = null,

    // Owns the Queue.Node (which owns the Task itself), the URL and the body.
    // Does not own the response.
    arena: ArenaAllocator,

    // Owns the response. The reason we don't use Task.arena is that this can get
    // quite large, so it's re-used. It's owned by the Downloader and, from our
    // point of view, it has the lifetime of request start -> request stop.
    // Task.arena on, the other hand, has a longer lifetime, as it has to exists
    // before request start, as it's queued.
    request_arena: Allocator,

    response: ?Response,

    const Type = enum {
        page,
        script,
    };

    fn onHttpRequestReady(ctx: *anyopaque, request: *http.Request) !void {
        // on error, our caller will cleanup request
        const self: *Task = @alignCast(@ptrCast(ctx));

        std.debug.assert(self.request == null);

        const arena = self.request_arena.allocator();

        {
            // write any cookies we have
            var arr: std.ArrayListUnmanaged(u8) = .{};
            try page.cookie_jar.forRequest(self.uri, arr.writer(arena), self.cookie);

            if (arr.items.len > 0) {
                try request.addHeader("Cookie", arr.items, .{});
            }
        }

        request.body = task.body;
        request.notification = task.notification;

        // TODO: when we refactor the http/client to be async-only, I think
        // wel'l be able to bake the loop into the client.
        try request.sendAsync(self.downloader.page.loop, self, .{});
        self.request = request;
    }

    pub fn onHttpResponse(self: *Task, progress_: anyerror!http.Progress) !void {
        const progress = progress_ catch |err| {
            // The request has been closed internally by the client, it isn't safe
            // for us to keep it around.
            self.request = null;
            self.download.completed(self);
            return;
        };

        self.process(progress) catch |err| {
            self.download.completed(self);
            return err;
        }
    }

    fn process(self: *Task, progress: http.Progress) !void {
        if (progress.first) {
            const header = progress.header;
            log.debug(.http, "request header", .{
                .source = "downloader",
                .url = self.url,
                .status = header.status,
            });

            try self.cookie_jar.populateFromResponse(&self.uri, &header);

            std.debug.assert(self.response == null);
            self.response = .{
                .status = header.status,
                .content_type = header.get("content-type"),
            }
        }

        if (progress.data) |data| {
            try self.response.?.body.appendSlice(self.request_arena, data);
        }

        if (progress.done == false) {
            return;
        }

        // Now that the request is done, the http/client will free the request
        // object. It isn't safe to keep it around.
        self.request = null;

        // don't use downloader.completed. We want the node popped off the queue
        // before we call page.downloadComplete, so that it can check if there's
        // more to do
        defer {
            const download = self.downloader;
            self.arena.deinit();
            downloader.next();
        }

        const node = self.queue.popFirst();
        std.debug.assert(node.data = self);

        log.info(.http, "request complete", .{
            .source = "downloader",
            .url = task.uri,
            .method = taks.method,
            .status = self.response_status,
        });

        page.downloadComplete(self.response);
    }
};

const Response = struct {
    status: u16,
    // cna be different than the requested URI because of redirects
    uri: *const Uri
    content_type: ?[]const u8,
    body: std.ArrayListUnmanaged(u8) = .empty,
};
