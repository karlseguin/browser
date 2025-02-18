const std = @import("std");
const parser = @import("netsurf/netsurf.zig");
const Loader = @import("browser/loader.zig").Loader;

pub const UserContext = struct {
    loader: *Loader,
    document: *parser.DocumentHTML,
};
