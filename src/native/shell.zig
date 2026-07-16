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
const update = @import("update.zig");
const builtin = @import("builtin");

const log = std.log.scoped(.native);

/// Per-connection server context handed to the server thread.
const ServerCtx = struct {
    allocator: std.mem.Allocator,
    router: *const mer.Router,
    manifest: manifest_mod.Manifest,
    ready: mer.ServerReady = .{},
    stop: mer.ServerStop = .{},
    watcher: ?*mer.Watcher = null,
    static_dir: ?[]const u8 = null,
    raw_handler: ?*const mer.RawHandler = null,
};

fn runServer(ctx: *ServerCtx) void {
    var srv = mer.Server.init(ctx.allocator, .{
        .host = ctx.manifest.host,
        .port = ctx.manifest.port,
        .dev = ctx.manifest.dev,
        .ready = &ctx.ready,
        .stop = &ctx.stop,
        .static_dir = ctx.static_dir,
        .raw_handler = ctx.raw_handler,
    }, ctx.router, if (ctx.manifest.dev) ctx.watcher else null);
    srv.listen() catch |err| {
        log.err("server listen failed: {}", .{err});
        ctx.ready.set(); // unblock the main thread even on failure
    };
}

fn wakeServer(host: []const u8, port: u16) void {
    if (port == 0) return;
    const address = std.Io.net.IpAddress.parse(host, port) catch return;
    const stream = address.connect(runtime.io, .{ .mode = .stream }) catch return;
    stream.close(runtime.io);
}

fn createBridgeToken(allocator: std.mem.Allocator) ![]u8 {
    var random: [32]u8 = undefined;
    try runtime.io.randomSecure(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    return try allocator.dupe(u8, &hex);
}

fn isSafeRelativeStaticDir(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '~') return false;
    var start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == ':' or c == '\\' or c <= 0x1f or c == 0x7f) return false;
        if (c == '/') {
            const part = path[start..i];
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
            start = i + 1;
        }
    }
    const last = path[start..];
    return last.len > 0 and !std.mem.eql(u8, last, ".") and !std.mem.eql(u8, last, "..");
}

fn resolvePackagedStaticDir(allocator: std.mem.Allocator, configured_static_dir: ?[]const u8) !?[]u8 {
    if (builtin.os.tag != .macos) return if (configured_static_dir) |dir| try allocator.dupe(u8, dir) else null;
    const relative = configured_static_dir orelse "public";
    if (!isSafeRelativeStaticDir(relative)) return try allocator.dupe(u8, "__mer_invalid_static_dir__");
    const exe_path = std.process.executablePathAlloc(runtime.io, allocator) catch
        return if (configured_static_dir) |dir| try allocator.dupe(u8, dir) else null;
    defer allocator.free(exe_path);
    const macos_dir = std.fs.path.dirname(exe_path) orelse
        return if (configured_static_dir) |dir| try allocator.dupe(u8, dir) else null;
    const contents_dir = std.fs.path.dirname(macos_dir) orelse
        return if (configured_static_dir) |dir| try allocator.dupe(u8, dir) else null;
    const app_dir = std.fs.path.dirname(contents_dir);
    const is_packaged_app = std.mem.eql(u8, std.fs.path.basename(contents_dir), "Contents") and
        app_dir != null and std.mem.endsWith(u8, app_dir.?, ".app");
    const candidate = try std.fs.path.join(allocator, &.{ contents_dir, "Resources", relative });
    std.Io.Dir.cwd().access(runtime.io, candidate, .{}) catch {
        allocator.free(candidate);
        if (is_packaged_app) return try allocator.dupe(u8, "__mer_missing_packaged_static_dir__");
        return if (configured_static_dir) |dir| try allocator.dupe(u8, dir) else null;
    };
    return candidate;
}

/// Options for `run`. Pass `.{}` for defaults (no raw handler and no custom commands).
pub const RunOpts = struct {
    /// Optional raw-request handler (e.g. SSE /events). Receives the live
    /// request so it can hold the connection open. See mer.RawHandler.
    raw_handler: ?*const mer.RawHandler = null,
    /// Optional app-provided static native bridge commands. These are validated
    /// by bridge.dispatch before any built-in or custom handler runs.
    commands: []const bridge.Command = &.{},
};

/// Run the native shell. Blocks until the window is closed.
///
/// `router` must outlive this call (it is borrowed by the server thread).
pub fn run(
    allocator: std.mem.Allocator,
    app_manifest: manifest_mod.Manifest,
    router: *const mer.Router,
    opts: RunOpts,
) !void {
    if (builtin.os.tag != .macos) {
        log.err("native shell currently supports macOS only; {s} backend is planned", .{@tagName(builtin.os.tag)});
        return error.UnsupportedPlatform;
    }

    // std.Io runtime must be initialized before Server.listen touches runtime.io.
    try runtime.init(allocator);
    defer runtime.deinit();
    mer.telemetry.init();
    defer mer.telemetry.deinit();

    if (!std.mem.eql(u8, app_manifest.web_engine, "system")) {
        log.err("web_engine='{s}' is not supported in this release (use \"system\")", .{app_manifest.web_engine});
        return error.UnsupportedWebEngine;
    }

    if (!manifest_mod.isLoopbackHost(app_manifest.host)) {
        log.err("native server host '{s}' is not loopback; use 127.0.0.1 for the hardened native shell", .{app_manifest.host});
        return error.UnsafeNativeHost;
    }

    try update.validateFeedConfig(app_manifest.update);

    // Dev mode: start the file watcher so hot-reload SSE works in the window.
    var watcher: ?mer.Watcher = null;
    defer if (watcher) |*w| w.deinit();
    var watcher_thread: ?std.Thread = null;
    var watcher_joined = false;
    defer if (!watcher_joined) {
        if (watcher) |*w| w.stop();
        if (watcher_thread) |thread| thread.join();
    };
    if (app_manifest.dev) {
        watcher = mer.Watcher.init(allocator, app_manifest.watch_dir);
        watcher_thread = try std.Thread.spawn(.{}, mer.Watcher.run, .{&watcher.?});
        log.info("hot reload active — watching {s}/", .{app_manifest.watch_dir});
    }

    // AppKit requires the main thread. The shell retains ownership of both
    // background threads and joins them before any borrowed state is released.
    const effective_static_dir = try resolvePackagedStaticDir(allocator, app_manifest.static_dir);
    defer if (effective_static_dir) |dir| allocator.free(dir);
    var ctx = ServerCtx{
        .allocator = allocator,
        .router = router,
        .manifest = app_manifest,
        .watcher = if (watcher) |*w| w else null,
        .static_dir = effective_static_dir,
        .raw_handler = opts.raw_handler,
    };
    const server_thread = try std.Thread.spawn(.{}, runServer, .{&ctx});
    defer {
        if (watcher) |*w| w.stop();
        if (watcher_thread) |thread| thread.join();
        watcher_joined = true;
        ctx.stop.request();
        wakeServer(ctx.manifest.host, ctx.ready.port);
        server_thread.join();
    }

    // Block until the server is bound and ready.
    ctx.ready.wait();
    const port = ctx.ready.port;
    if (port == 0) return error.ServerFailed;
    log.info("merjs server ready on port {d}", .{port});

    // Build the loopback URL the WebView will load.
    var url_buf: [128]u8 = undefined;
    const url_z = try std.fmt.bufPrintZ(&url_buf, "http://{s}:{d}/", .{ app_manifest.host, port });

    const runtime_origin = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ app_manifest.host, port });
    defer allocator.free(runtime_origin);
    const allowed_origins = try allocator.alloc([]const u8, app_manifest.security.allowed_origins.len + 1);
    defer allocator.free(allowed_origins);
    allowed_origins[0] = runtime_origin;
    @memcpy(allowed_origins[1..], app_manifest.security.allowed_origins);

    // Bridge context (heap-allocated; outlives the blocking event loop). The
    // ObjC IMP reaches it via the macos backend's g_bridge_ctx global.
    const token = try createBridgeToken(allocator);
    defer allocator.free(token);
    if (!bridge.isValidBridgeToken(token)) return error.InvalidBridgeToken;
    const bctx = try allocator.create(bridge.Ctx);
    defer allocator.destroy(bctx);
    bctx.* = .{
        .allocator = allocator,
        .permissions = app_manifest.permissions,
        .allowed_origins = allowed_origins,
        .allowed_commands = app_manifest.security.bridge.allowed_commands,
        .command_origins = app_manifest.security.bridge.command_origins,
        .extra_commands = opts.commands,
        .bridge_token = token,
        .external_url_schemes = app_manifest.security.open.external_schemes,
        .open_path_roots = app_manifest.security.open.path_roots,
    };

    // Hand off to the platform backend (blocks on the event loop).
    switch (builtin.os.tag) {
        .macos => return @import("macos.zig").openWindow(url_z.ptr, app_manifest.window, bctx),
        else => unreachable, // guarded before any side effects above
    }
}
