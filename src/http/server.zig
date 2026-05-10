const std = @import("std");
const httpz = @import("httpz");

const Config = @import("../config.zig").Config;
const Store = @import("../repo/store.zig").Store;
const handlers = @import("handlers.zig");

pub const App = struct {
    config: Config,
    store: Store,

    pub fn notFound(self: *App, req: *httpz.Request, res: *httpz.Response) !void {
        return handlers.dispatch(self, req, res);
    }

    pub fn uncaughtError(_: *App, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        std.log.err("uncaught error on {s}: {s}", .{ req.url.path, @errorName(err) });
        res.status = 500;
        res.body = "internal server error";
    }
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, config: Config) !void {
    var app = App{
        .config = config,
        .store = Store.init(gpa, config.repo_root),
    };
    defer app.store.deinit();

    var server = try httpz.Server(*App).init(io, gpa, .{
        .address = .localhost(config.port),
        .request = .{ .max_body_size = 256 * 1024 * 1024 },
        .workers = .{ .large_buffer_size = 64 * 1024 },
    }, &app);
    defer server.deinit();
    defer server.stop();

    // No routes are registered; all requests flow through App.notFound,
    // which calls handlers.dispatch(). This lets us match git's URL shape
    // (multi-segment repo prefix + fixed endpoint suffix) cleanly.
    _ = try server.router(.{});

    std.log.info("gitblob listening on http://localhost:{d} (repos: {s})", .{
        config.port,
        config.repo_root,
    });
    try server.listen();
}
