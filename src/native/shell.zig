// shell.zig — platform-agnostic native shell entry point.
//
// Spawns the merjs HTTP server on a loopback ephemeral port (port=0), waits for
// the ServerReady handshake to read back the bound port, then hands the URL to
// the platform backend (macos.zig) which opens a WebView window.
//
// This is the generalized product form of examples/desktop/main.zig:
//   - manifest-driven (window size/title, host/port, dev mode)
//   - runtime.io is initialized (the desktop spike forgot this — runtime.io was
//     undefined at runtime, crashing Server.listen)
//   - dev mode optionally starts the file watcher so /_mer/events SSE hot
//     reload works inside the native window.

const std = @import("std");
const mer = @import("mer");
const runtime = @import("runtime");
const manifest_mod = @import("manifest.zig");
const bridge = @import("bridge.zig");
const builtin = @import("builtin");

const log = std.log.scoped(.native);

/// Per-connection server context handed to the server thread.
const ServerCtx = struct {
    allocator: std.mem.Allocator,
    router: *const mer.Router,
    manifest: manifest_mod.Manifest,
    ready: mer.ServerReady = .{},
    watcher: ?*mer.Watcher = null,
};

fn runServer(ctx: *ServerCtx) void {
    var srv = mer.Server.init(ctx.allocator, .{
        .host = ctx.manifest.host,
        .port = ctx.manifest.port,
        .dev = ctx.manifest.dev,
        .ready = &ctx.ready,
    }, ctx.router, if (ctx.manifest.dev) ctx.watcher else null);
    srv.listen() catch |err| {
        log.err("server listen failed: {}", .{err});
        ctx.ready.set(); // unblock the main thread even on failure
    };
}

/// Run the native shell. Blocks until the window is closed.
///
/// `router` must outlive this call (it is borrowed by the server thread).
pub fn run(
    allocator: std.mem.Allocator,
    app_manifest: manifest_mod.Manifest,
    router: *const mer.Router,
) !void {
    // std.Io runtime must be initialized before Server.listen touches runtime.io.
    try runtime.init(allocator);
    defer runtime.deinit();

    if (!std.mem.eql(u8, app_manifest.web_engine, "system")) {
        log.err("web_engine='{s}' is not supported in this release (use \"system\")", .{app_manifest.web_engine});
        return error.UnsupportedWebEngine;
    }

    // Dev mode: start the file watcher so hot-reload SSE works in the window.
    var watcher: ?mer.Watcher = null;
    var watcher_ref: ?*mer.Watcher = null;
    if (app_manifest.dev) {
        watcher = mer.Watcher.init(allocator, app_manifest.watch_dir);
        watcher_ref = &watcher.?;
        const wt = try std.Thread.spawn(.{}, mer.Watcher.run, .{&watcher.?});
        wt.detach();
        log.info("hot reload active — watching {s}/", .{app_manifest.watch_dir});
    }
    defer if (watcher) |*w| w.deinit();

    // Spawn HTTP server on a background thread (AppKit requires the main thread).
    // The server/watcher are detached for this macOS-first shell. Closing the
    // last window terminates the process through AppKit; cooperative shutdown
    // can replace this once Server.listen has a stop signal.
    const ctx = try allocator.create(ServerCtx);
    ctx.* = .{
        .allocator = allocator,
        .router = router,
        .manifest = app_manifest,
        .watcher = watcher_ref,
    };
    const thread = try std.Thread.spawn(.{}, runServer, .{ctx});
    thread.detach();

    // Block until the server is bound and ready.
    ctx.ready.wait();
    const port = ctx.ready.port;
    if (port == 0) return error.ServerFailed;
    log.info("merjs server ready on port {d}", .{port});

    // Build the loopback URL the WebView will load.
    var url_buf: [128]u8 = undefined;
    const url_z = try std.fmt.bufPrintZ(&url_buf, "http://{s}:{d}/", .{ app_manifest.host, port });

    // Bridge context (heap-allocated; outlives the blocking event loop). The
    // ObjC IMP reaches it via the macos backend's g_bridge_ctx global.
    const bctx = try allocator.create(bridge.Ctx);
    bctx.* = .{
        .allocator = allocator,
        .permissions = app_manifest.permissions,
        .allowed_origins = app_manifest.security.allowed_origins,
    };

    // Hand off to the platform backend (blocks on the event loop).
    switch (builtin.os.tag) {
        .macos => @import("macos.zig").openWindow(url_z.ptr, app_manifest.window, bctx),
        else => {
            log.err("native shell not yet implemented for {s}", .{@tagName(builtin.os.tag)});
            return error.UnsupportedPlatform;
        },
    }
}
