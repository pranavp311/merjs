// server.zig — HTTP server backbone (Zig 0.16).
// std.http.Server now takes *Io.Reader + *Io.Writer from a net.Stream (with Io param).

const std = @import("std");
const mer = @import("mer");
const Router = @import("router.zig").Router;
const dispatch_mod = @import("dispatch.zig");
const static = @import("static.zig");
const watcher_mod = @import("watcher.zig");
const kuri_mod = @import("kuri.zig");
const runtime = @import("runtime");
const telemetry = mer.telemetry;
const dev_mod = mer.dev;

const log = std.log.scoped(.server);

/// Thread-local TTFB tracking: set before serveRequest, read after first response write.
threadlocal var _request_start_ns: i128 = 0;
threadlocal var _ttfb_ns: i128 = 0;

/// Called internally by sendResponse/streaming paths to mark first-byte time.
pub fn markTtfb() void {
    if (_ttfb_ns == 0 and _request_start_ns != 0) {
        _ttfb_ns = nanoTimestamp() - _request_start_ns;
    }
}

/// Security headers applied to every page/API response.
pub const security_headers = [_]std.http.Header{
    .{ .name = "strict-transport-security", .value = "max-age=63072000; includeSubDomains; preload" },
    .{ .name = "content-security-policy", .value = "default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' blob: https://cdn.jsdelivr.net https://unpkg.com https://static.cloudflareinsights.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://unpkg.com; font-src https://fonts.gstatic.com; img-src 'self' data: https://*.tile.openstreetmap.org https://*.basemaps.cartocdn.com https://unpkg.com; connect-src 'self' https://api.open-meteo.com https://cloudflareinsights.com https://api-open.data.gov.sg https://api-production.data.gov.sg https://cdn.jsdelivr.net https://unpkg.com https://nominatim.openstreetmap.org; frame-ancestors 'none'; base-uri 'self'; form-action 'self'" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "referrer-policy", .value = "strict-origin-when-cross-origin" },
    .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
    .{ .name = "permissions-policy", .value = "camera=(), microphone=(), geolocation=()" },
};

/// Passed (optional) to Server.listen() so callers can wait for the server
/// to be ready and read back the actual bound port (useful when port=0).
/// Uses std.atomic.Value(bool) since std.Thread.ResetEvent was removed in 0.16.
pub const ServerReady = struct {
    event: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    port: u16 = 0,

    /// Block until the server signals readiness.
    pub fn wait(self: *ServerReady) void {
        while (!self.event.load(.acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    /// Signal that the server is ready.
    pub fn set(self: *ServerReady) void {
        self.event.store(true, .release);
    }
};

pub const TargetMetadata = struct {
    raw_target: []const u8,
    path: []const u8,
    query_string: []const u8,
};

pub fn splitRequestTarget(head_target: []const u8) TargetMetadata {
    const query_index = std.mem.indexOfScalar(u8, head_target, '?');
    return .{
        .raw_target = head_target,
        .path = if (query_index) |q| head_target[0..q] else head_target,
        .query_string = if (query_index) |q|
            if (q + 1 < head_target.len) head_target[q + 1 ..] else ""
        else
            "",
    };
}

pub fn shouldTrySpaFallback(static_dir: ?[]const u8, has_route: bool, has_framed_body: bool) bool {
    return static_dir != null and !has_route and !has_framed_body;
}

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3000,
    dev: bool = false,
    verbose: bool = false,
    debug: bool = false,
    kuri_port: u16 = 9222,
    /// If non-null, listen() sets .port to the actual bound port then signals .event.
    ready: ?*ServerReady = null,
    /// Static-file root directory (default "public"). Set to "dist" to serve a
    /// Vite/SSG build. When set, index.html is served at "/" and unknown paths
    /// fall back to index.html (SPA history fallback).
    static_dir: ?[]const u8 = null,
    /// Optional raw-handler hook, checked before routing/static. Use this to
    /// register long-lived endpoints that must own the connection (e.g. SSE)
    /// which normal API routes (returning a single `mer.Response`) cannot do.
    /// Return `true` if the request was fully handled; `false` to fall through.
    raw_handler: ?*const RawHandler = null,
};

/// Raw request handler: receives the live `std.http.Server.Request` so it can
/// call `respondStreaming` and hold the connection open (SSE, websockets).
/// `alloc` is a per-connection arena; `io` is the runtime I/O instance.
/// Return `true` if handled (no further processing), `false` to fall through.
pub const RawHandler = struct {
    ctx: *anyopaque,
    callback: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, std_req: *std.http.Server.Request, io: std.Io) bool,
};

pub const Server = struct {
    config: Config,
    router: *const Router,
    watcher: ?*watcher_mod.Watcher,
    kuri: ?kuri_mod.Kuri,
    allocator: std.mem.Allocator,
    io: std.Io = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        config: Config,
        router: *const Router,
        watcher: ?*watcher_mod.Watcher,
    ) Server {
        return .{
            .allocator = allocator,
            .config = config,
            .router = router,
            .watcher = watcher,
            .kuri = null,
        };
    }

    pub fn listen(self: *Server) !void {
        // Init static file cache.
        static.initCache(self.allocator);

        // Spawn kuri sidecar in debug mode.
        if (self.config.debug) {
            self.kuri = kuri_mod.Kuri.spawn(self.allocator, self.config.port, self.config.kuri_port);
        }
        defer if (self.kuri) |*k| k.deinit();

        // Use shared runtime.io for all I/O (Threaded now, Evented for io_uring later)
        const io = runtime.io;
        self.io = io;
        const addr = try std.Io.net.IpAddress.parse(self.config.host, self.config.port);
        var net_server = try addr.listen(io, .{ .reuse_address = true });
        defer net_server.deinit(io);

        // Signal readiness with actual bound port (supports port=0 for desktop/testing).
        if (self.config.ready) |r| {
            r.port = net_server.socket.address.getPort();
            r.set();
        }

        log.info("merjs dev server -> http://{s}:{d}", .{ self.config.host, net_server.socket.address.getPort() });

        while (true) {
            const stream = net_server.accept(io) catch |err| {
                log.debug("accept: {}", .{err});
                continue;
            };
            const ctx = self.allocator.create(ConnCtx) catch {
                stream.close(io);
                continue;
            };
            ctx.* = .{
                .stream = stream,
                .io = io,
                .router = self.router,
                .watcher = self.watcher,
                .kuri = if (self.kuri) |*k| k else null,
                .allocator = self.allocator,
                .dev = self.config.dev,
                .verbose = self.config.verbose,
                .static_dir = self.config.static_dir,
                .raw_handler = self.config.raw_handler,
            };
            // 0.16: Thread.Pool removed; spawn a detached thread per connection.
            const t = std.Thread.spawn(.{}, handleConn, .{ctx}) catch {
                ctx.allocator.destroy(ctx);
                stream.close(io);
                continue;
            };
            t.detach();
        }
    }
};

const ConnCtx = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    router: *const Router,
    watcher: ?*watcher_mod.Watcher,
    kuri: ?*kuri_mod.Kuri,
    allocator: std.mem.Allocator,
    dev: bool,
    verbose: bool,
    static_dir: ?[]const u8,
    raw_handler: ?*const RawHandler,
};

fn handleConn(ctx: *ConnCtx) void {
    defer ctx.allocator.destroy(ctx);
    defer ctx.stream.close(ctx.io);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var read_buf: [16384]u8 = undefined;
    var write_buf: [65536]u8 = undefined;
    // 0.16: Stream.reader/writer now take (stream, io, buffer).
    var in = ctx.stream.reader(ctx.io, &read_buf);
    var out = ctx.stream.writer(ctx.io, &write_buf);
    var http_server = std.http.Server.init(&in.interface, &out.interface);

    while (true) {
        var std_req = http_server.receiveHead() catch |err| {
            if (err != error.HttpConnectionClosing and err != error.ReadFailed) {
                log.debug("receiveHead: {}", .{err});
            }
            return;
        };
        const error_target = alloc.dupe(u8, std_req.head.target) catch "<unknown>";

        _request_start_ns = nanoTimestamp();
        _ttfb_ns = 0;
        const start = _request_start_ns;
        serveRequest(alloc, &std_req, ctx.router, ctx.watcher, ctx.kuri, ctx.dev, ctx.verbose, ctx.io, ctx.static_dir, ctx.raw_handler) catch |err| {
            log.err("serveRequest: {}", .{err});
            if (ctx.dev) {
                dev_mod.sendErrorOverlay(&std_req, error_target, err, mer.version) catch {};
            }
            telemetry.sentryCapture(@errorName(err), error_target, mer.version);
            telemetry.ddError(error_target, @tagName(std_req.head.method), @errorName(err));
            return;
        };

        const elapsed_ns = nanoTimestamp() - start;
        const elapsed_us: u64 = @intCast(@divFloor(elapsed_ns, 1000));
        const ttfb_us: u64 = if (_ttfb_ns > 0) @intCast(@divFloor(_ttfb_ns, 1000)) else elapsed_us;

        telemetry.ddTiming(error_target, @tagName(std_req.head.method), 200, elapsed_us);

        if (ctx.verbose) {
            const elapsed_f: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1000.0;
            if (elapsed_f < 1000.0) {
                log.info("{s} {s} {d:.0}us (ttfb: {d}us)", .{ @tagName(std_req.head.method), error_target, elapsed_f, ttfb_us });
            } else {
                log.info("{s} {s} {d:.1}ms (ttfb: {d}us)", .{ @tagName(std_req.head.method), error_target, elapsed_f / 1000.0, ttfb_us });
            }
        }

        // Reset arena between requests on the same connection (keep-alive).
        _ = arena.reset(.retain_capacity);
    }
}

/// Replacement for std.time.nanoTimestamp() which was removed in Zig 0.16.
fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

fn serveRequest(
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    router: *const Router,
    watcher: ?*watcher_mod.Watcher,
    kuri: ?*const kuri_mod.Kuri,
    dev: bool,
    verbose: bool,
    io: std.Io,
    static_dir: ?[]const u8,
    raw_handler: ?*const RawHandler,
) !void {
    _ = verbose;
    // `std_req.head.target` is borrowed from std.http's head buffer. Zig 0.16
    // invalidates that string memory when the body reader is initialized, so
    // copy target-derived slices before any framed body is read.
    const target_meta = splitRequestTarget(std_req.head.target);
    const raw_target = try alloc.dupe(u8, target_meta.raw_target);
    const path = try alloc.dupe(u8, target_meta.path);
    const query_string = try alloc.dupe(u8, target_meta.query_string);

    // Raw handler hook (checked first) — lets apps register long-lived
    // endpoints (SSE, websockets) that must own the connection.
    if (raw_handler) |rh| {
        if (rh.callback(rh.ctx, alloc, std_req, io)) return;
    }

    // SSE hot-reload endpoint.
    if (dev and std.mem.eql(u8, path, "/_mer/events")) {
        if (watcher) |w| {
            watcher_mod.handleSse(w, alloc, std_req) catch |err| {
                log.err("SSE handler: {}", .{err});
            };
        }
        return;
    }

    // Debug endpoint — shows registered routes, config, hints.
    if (dev and std.mem.eql(u8, path, "/_mer/debug")) {
        if (requestHasFramedBody(std_req)) _ = try readRequestBody(alloc, std_req);
        const route_infos = alloc.alloc(dev_mod.RouteDebugInfo, router.routes.len) catch return error.OutOfMemory;
        for (router.routes, 0..) |route, i| route_infos[i] = .{ .path = route.path };
        const response = try dev_mod.serveDebug(alloc, route_infos, router.exact_map.count(), router.dynamic_routes.len, query_string, mer.version);
        try sendResponse(std_req, response);
        return;
    }

    // Kuri browser automation proxy (debug mode).
    if (dev and std.mem.startsWith(u8, path, "/_mer/kuri")) {
        if (kuri) |k| {
            k.proxyRequest(alloc, std_req, raw_target) catch |err| {
                log.err("kuri proxy: {}", .{err});
            };
            return;
        }
    }

    // Static files are checked before routes so real assets (e.g. /favicon.ico)
    // are not swallowed by broad dynamic routes. SPA history fallback is handled
    // later, after route lookup, so it cannot shadow API/page routes.
    if (!requestHasFramedBody(std_req)) {
        if (static_dir) |d| {
            if (std.mem.eql(u8, path, "/")) {
                if (static.tryServe(alloc, std_req, path, io, .{ .dir = d, .spa = true })) |_| return;
            } else if (static.tryServe(alloc, std_req, path, io, .{ .dir = d, .spa = false })) |_| return;
        } else if (static.tryServe(alloc, std_req, path, io, .{})) |_| return;
    }

    // Pre-rendered pages from dist/ (SSG) should win in production even when a
    // registered route exists for the path.
    if (!dev and !requestHasFramedBody(std_req)) {
        if (tryServePrerendered(alloc, std_req, path, io)) |_| return;
    }

    const has_route = router.findRoute(path) != null;
    // SPA history fallback only after proving no backend route matches.
    if (shouldTrySpaFallback(static_dir, has_route, requestHasFramedBody(std_req))) {
        if (static_dir) |d| {
            if (static.tryServe(alloc, std_req, path, io, .{ .dir = d, .spa = true })) |_| return;
        }
    }

    // ── Build Request ──────────────────────────────────────────────────────

    const cookies_raw: []const u8 = blk: {
        var it = std_req.iterateHeaders();
        while (it.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "cookie")) break :blk try alloc.dupe(u8, hdr.value);
        }
        break :blk "";
    };

    const body_bytes: []const u8 = try readRequestBody(alloc, std_req);

    var req = mer.Request.init(alloc, mer.Method.fromStd(std_req.head.method), path);
    req.query_string = query_string;
    req.body = body_bytes;
    req.cookies_raw = cookies_raw;

    mer.h.setRenderAllocator(alloc);

    // ── Check for true streaming render (renderStream) ─────────────────────
    // If the matched route exports renderStream and we have a stream_layout,
    // use the Marko-style placeholder/resolve pattern.
    if (router.stream_layout) |stream_wrap| {
        const matched_route = router.findRoute(req.path);
        if (matched_route) |route| {
            if (route.render_stream) |stream_fn| {
                const parts = stream_wrap(alloc, req.path, route.meta);

                const fixed = [1]std.http.Header{
                    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                } ++ security_headers;

                var header_buf: [4096]u8 = undefined;
                var bw = try std_req.respondStreaming(&header_buf, .{
                    .respond_options = .{
                        .status = .ok,
                        .extra_headers = &fixed,
                    },
                });

                // Flush layout head immediately — browser starts rendering shell.
                // Flush layout head immediately — browser starts rendering shell.
                try bw.writer.writeAll(parts.head);
                markTtfb();
                try bw.flush();

                // Create StreamWriter backed by the HTTP body writer.
                var stream_writer = mer.StreamWriter{
                    .allocator = alloc,
                    .ctx = @ptrCast(&bw),
                    .writeFn = &streamWriteImpl,
                    .flushFn = &streamFlushImpl,
                };

                // Call the page's streaming render — it writes placeholders,
                // fetches data, and resolves slots progressively.
                stream_fn(req, &stream_writer);

                // Flush tail + hot reload.
                if (dev) try bw.writer.writeAll(dev_mod.hot_reload_script);
                try bw.writer.writeAll(parts.tail);
                try bw.end();
                return;
            }
        }
    }

    // ── Shell-first streaming (non-Suspense) ───────────────────────────────
    const result = dispatch_mod.dispatchStreaming(router.*, req);
    var response = result.response;

    if (result.is_streaming) {
        var hot_reload_tail: []const u8 = "";
        if (dev) {
            hot_reload_tail = dev_mod.hot_reload_script;
        }

        const fixed = [1]std.http.Header{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        } ++ security_headers;

        var header_buf: [4096]u8 = undefined;
        var bw = try std_req.respondStreaming(&header_buf, .{
            .respond_options = .{
                .status = response.status,
                .extra_headers = &fixed,
            },
        });
        try bw.writer.writeAll(result.head);
        markTtfb();
        try bw.flush();
        try bw.writer.writeAll(result.body);
        try bw.flush();
        try bw.writer.writeAll(hot_reload_tail);
        try bw.writer.writeAll(result.tail);
        try bw.end();
        return;
    }

    // ── Non-streaming path ─────────────────────────────────────────────────
    var owned_body: ?[]u8 = null;
    if (dev and response.content_type == .html) {
        if (dev_mod.injectHotReload(alloc, response.body)) |injected| {
            owned_body = injected;
            response.body = injected;
        } else |_| {}
    }
    defer if (owned_body) |b| alloc.free(b);

    try sendResponse(std_req, response);
}


fn requestHasFramedBody(std_req: *const std.http.Server.Request) bool {
    return switch (std_req.head.transfer_encoding) {
        .chunked => true,
        .none => if (std_req.head.content_length) |len| len > 0 else false,
    };
}

fn readRequestBody(alloc: std.mem.Allocator, std_req: *std.http.Server.Request) ![]const u8 {
    // In Zig 0.16, receiveHead() only consumes headers. If the request is
    // framed with Content-Length or Transfer-Encoding: chunked, enter the
    // std.http body reader exactly once so payload bytes are consumed before
    // routing returns to the keep-alive receive loop. Reading the body consumes
    // the head buffer storage, so callers must copy any needed header/target
    // slices first.
    if (std_req.head.transfer_encoding == .none) {
        const len = std_req.head.content_length orelse return "";
        if (len == 0) return "";
    }

    const should_flush_continue = std_req.head.expect != null;
    try std_req.writeExpectContinue();
    if (should_flush_continue) try std_req.server.out.flush();

    var transfer_buf: [4096]u8 = undefined;
    const reader = std_req.server.reader.bodyReader(
        &transfer_buf,
        std_req.head.transfer_encoding,
        std_req.head.content_length,
    );
    return reader.allocRemaining(alloc, .limited(4 * 1024 * 1024));
}

fn streamWriteImpl(ctx: *anyopaque, data: []const u8) void {
    const bw: *std.http.BodyWriter = @ptrCast(@alignCast(ctx));
    bw.writer.writeAll(data) catch {};
}

fn streamFlushImpl(ctx: *anyopaque) void {
    const bw: *std.http.BodyWriter = @ptrCast(@alignCast(ctx));
    bw.flush() catch {};
}

/// Maximum number of Set-Cookie headers we emit per response.
const MAX_COOKIES = 8;

fn sendResponse(std_req: *std.http.Server.Request, response: mer.Response) !void {
    // Format Set-Cookie header values on the stack.
    var cookie_val_bufs: [MAX_COOKIES][512]u8 = undefined;
    var cookie_headers: [MAX_COOKIES]std.http.Header = undefined;
    const n_cookies = @min(response.cookies.len, MAX_COOKIES);
    for (response.cookies[0..n_cookies], 0..) |ck, i| {
        cookie_headers[i] = .{
            .name = "set-cookie",
            .value = ck.headerValue(&cookie_val_bufs[i]),
        };
    }

    if (response.content_type == .redirect) {
        // Redirect: Location + optional Set-Cookie, no body, no security headers.
        var extra: [1 + MAX_COOKIES]std.http.Header = undefined;
        extra[0] = .{ .name = "location", .value = response.body };
        @memcpy(extra[1 .. 1 + n_cookies], cookie_headers[0..n_cookies]);

        var header_buf: [2048]u8 = undefined;
        var bw = try std_req.respondStreaming(&header_buf, .{
            .respond_options = .{
                .status = response.status,
                .extra_headers = extra[0 .. 1 + n_cookies],
            },
        });
        markTtfb();
        try bw.end();
        return;
    }

    // Normal response: content-type + security headers + optional Set-Cookie.
    const fixed = [1]std.http.Header{
        .{ .name = "content-type", .value = response.content_type.mime() },
    } ++ security_headers;

    var extra: [fixed.len + MAX_COOKIES]std.http.Header = undefined;
    @memcpy(extra[0..fixed.len], &fixed);
    @memcpy(extra[fixed.len .. fixed.len + n_cookies], cookie_headers[0..n_cookies]);

    var header_buf: [4096]u8 = undefined;
    var bw = try std_req.respondStreaming(&header_buf, .{
        .content_length = response.body.len,
        .respond_options = .{
            .status = response.status,
            .extra_headers = extra[0 .. fixed.len + n_cookies],
        },
    });
    markTtfb();
    try bw.writer.writeAll(response.body);
    try bw.end();
}

/// Serve a pre-rendered HTML file from dist/ if it exists.
fn tryServePrerendered(
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    url_path: []const u8,
    io: std.Io,
) ?void {
    if (std.mem.indexOf(u8, url_path, "..") != null) return null;

    const fs_path = if (std.mem.eql(u8, url_path, "/"))
        std.fmt.allocPrint(alloc, "dist/index.html", .{}) catch return null
    else blk: {
        const rel = if (url_path.len > 0 and url_path[0] == '/') url_path[1..] else url_path;
        break :blk std.fmt.allocPrint(alloc, "dist/{s}.html", .{rel}) catch return null;
    };
    defer alloc.free(fs_path);

    const file_content = std.Io.Dir.cwd().readFileAlloc(io, fs_path, alloc, .limited(10 * 1024 * 1024)) catch return null;
    const body = file_content;

    const fixed = [1]std.http.Header{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    } ++ security_headers;

    var header_buf: [512]u8 = undefined;
    var bw = std_req.respondStreaming(&header_buf, .{
        .content_length = body.len,
        .respond_options = .{
            .status = .ok,
            .extra_headers = &fixed,
        },
    }) catch return null;
    bw.writer.writeAll(body) catch return null;
    bw.end() catch return null;

    return {};
}

test "splitRequestTarget preserves metadata before body reads" {
    const meta = splitRequestTarget("/api/echo?name=mer&debug=1");
    try std.testing.expectEqualStrings("/api/echo?name=mer&debug=1", meta.raw_target);
    try std.testing.expectEqualStrings("/api/echo", meta.path);
    try std.testing.expectEqualStrings("name=mer&debug=1", meta.query_string);

    const empty_query = splitRequestTarget("/submit?");
    try std.testing.expectEqualStrings("/submit", empty_query.path);
    try std.testing.expectEqualStrings("", empty_query.query_string);
}

test "SPA static fallback does not shadow real routes or request bodies" {
    try std.testing.expect(!shouldTrySpaFallback("dist", true, false));
    try std.testing.expect(!shouldTrySpaFallback("dist", false, true));
    try std.testing.expect(!shouldTrySpaFallback(null, false, false));
    try std.testing.expect(shouldTrySpaFallback("dist", false, false));
}
