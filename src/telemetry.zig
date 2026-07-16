// telemetry.zig — opt-in Sentry + Datadog integration.
// Activates when SENTRY_DSN or DD_AGENT_HOST env vars are set.
// Sentry sends are bounded and fire-and-forget; DogStatsD sends are synchronous UDP.

const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("env.zig");
const runtime = @import("runtime");

const max_sentry_field_len = 2048;
const max_sentry_envelope_len = 16 * 1024;
const max_sentry_sends = 8;
const sentry_send_timeout = std.Io.Duration.fromSeconds(5);

fn env(name: []const u8) ?[]const u8 {
    return env_mod.get(name);
}

// ── Sentry ──────────────────────────────────────────────────────────────────
// Sends error events to Sentry via the HTTP envelope endpoint.
// Set SENTRY_DSN=https://<key>@<host>/<project_id>

/// Parsed Sentry DSN components. The slices borrow from `dsn`.
const SentryConfig = struct {
    key: []const u8,
    host: []const u8,
    project_id: []const u8,
};

fn isDsnComponent(value: []const u8, allow_host_punctuation: bool) bool {
    if (value.len == 0 or value.len > max_sentry_field_len) return false;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') continue;
        if (allow_host_punctuation and (c == ':' or c == '[' or c == ']')) continue;
        return false;
    }
    return true;
}

pub fn parseSentryDsn(dsn: []const u8) ?SentryConfig {
    const prefix = "https://";
    if (!std.mem.startsWith(u8, dsn, prefix)) return null;
    const authority = dsn[prefix.len..];
    const at = std.mem.indexOfScalar(u8, authority, '@') orelse return null;
    const key = authority[0..at];
    const rest = authority[at + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..slash];
    const project_id = rest[slash + 1 ..];
    if (!isDsnComponent(key, false) or
        !isDsnComponent(host, true) or
        !isDsnComponent(project_id, false)) return null;
    return .{ .key = key, .host = host, .project_id = project_id };
}

fn appendBounded(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    if (bytes.len > max_sentry_envelope_len -| out.items.len) return error.EventTooLarge;
    try out.appendSlice(allocator, bytes);
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    if (value.len > max_sentry_field_len or !std.unicode.utf8ValidateSlice(value)) return error.InvalidEventField;
    try appendBounded(out, allocator, "\"");
    const hex = "0123456789abcdef";
    for (value) |c| switch (c) {
        '"' => try appendBounded(out, allocator, "\\\""),
        '\\' => try appendBounded(out, allocator, "\\\\"),
        '\n' => try appendBounded(out, allocator, "\\n"),
        '\r' => try appendBounded(out, allocator, "\\r"),
        '\t' => try appendBounded(out, allocator, "\\t"),
        0...7, 11, 12, 14...31 => {
            const escaped = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf] };
            try appendBounded(out, allocator, &escaped);
        },
        else => try appendBounded(out, allocator, &.{c}),
    };
    try appendBounded(out, allocator, "\"");
}

fn buildSentryEnvelope(
    allocator: std.mem.Allocator,
    cfg: SentryConfig,
    error_name: []const u8,
    path: []const u8,
    framework_version: []const u8,
) ![]u8 {
    if (error_name.len > max_sentry_field_len or
        path.len > max_sentry_field_len or
        framework_version.len > max_sentry_field_len) return error.InvalidEventField;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, @min(max_sentry_envelope_len, 1024 + path.len * 2));

    try appendBounded(&out, allocator, "{\"dsn\":");
    var dsn: [max_sentry_field_len * 3 + 10]u8 = undefined;
    const dsn_value = try std.fmt.bufPrint(&dsn, "https://{s}@{s}/{s}", .{ cfg.key, cfg.host, cfg.project_id });
    try appendJsonString(&out, allocator, dsn_value);
    try appendBounded(&out, allocator, "}\n{\"type\":\"event\"}\n{\"level\":\"error\",\"platform\":\"other\",\"sdk\":{\"name\":\"merjs\",\"version\":");
    try appendJsonString(&out, allocator, framework_version);
    try appendBounded(&out, allocator, "},\"exception\":{\"values\":[{\"type\":");
    try appendJsonString(&out, allocator, error_name);
    try appendBounded(&out, allocator, ",\"value\":");

    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(allocator);
    try message.appendSlice(allocator, "Route handler error on ");
    try message.appendSlice(allocator, path);
    try appendJsonString(&out, allocator, message.items);
    try appendBounded(&out, allocator, "}]},\"request\":{\"url\":");
    try appendJsonString(&out, allocator, path);
    try appendBounded(&out, allocator, "},\"tags\":{\"framework\":\"merjs\",\"zig\":");
    try appendJsonString(&out, allocator, builtin.zig_version_string);
    try appendBounded(&out, allocator, "}}\n");
    return out.toOwnedSlice(allocator);
}

const SentrySendContext = struct {
    url: []u8,
    payload: []u8,
};

var sentry_mutex: std.atomic.Mutex = .unlocked;
var sentry_accepting = true;
var sentry_in_flight: usize = 0;

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn acquireSentrySlot() bool {
    lock(&sentry_mutex);
    defer sentry_mutex.unlock();
    if (!sentry_accepting or sentry_in_flight == max_sentry_sends) return false;
    sentry_in_flight += 1;
    return true;
}

fn releaseSentrySlot() void {
    lock(&sentry_mutex);
    defer sentry_mutex.unlock();
    std.debug.assert(sentry_in_flight > 0);
    sentry_in_flight -= 1;
}

fn destroySentryContext(ctx: *SentrySendContext) void {
    const allocator = std.heap.page_allocator;
    allocator.free(ctx.url);
    allocator.free(ctx.payload);
    allocator.destroy(ctx);
}

fn createSentryContext(
    cfg: SentryConfig,
    error_name: []const u8,
    path: []const u8,
    framework_version: []const u8,
) !*SentrySendContext {
    const allocator = std.heap.page_allocator;
    const payload = try buildSentryEnvelope(allocator, cfg, error_name, path, framework_version);
    errdefer allocator.free(payload);
    const url = try std.fmt.allocPrint(allocator, "https://{s}/api/{s}/envelope/", .{ cfg.host, cfg.project_id });
    errdefer allocator.free(url);
    const ctx = try allocator.create(SentrySendContext);
    ctx.* = .{ .url = url, .payload = payload };
    return ctx;
}

/// Report an error to Sentry. At most eight sends may be in flight; excess
/// reports are dropped rather than creating unbounded detached threads.
pub fn sentryCapture(error_name: []const u8, path: []const u8, framework_version: []const u8) void {
    if (comptime builtin.os.tag == .freestanding) return;
    const dsn_str = env("SENTRY_DSN") orelse return;
    const cfg = parseSentryDsn(dsn_str) orelse return;
    if (!acquireSentrySlot()) return;
    const ctx = createSentryContext(cfg, error_name, path, framework_version) catch {
        releaseSentrySlot();
        return;
    };

    const thread = std.Thread.spawn(.{}, sentrySendThread, .{ctx}) catch {
        releaseSentrySlot();
        destroySentryContext(ctx);
        return;
    };
    thread.detach();
}

fn sentryFetch(client: *std.http.Client, ctx: *const SentrySendContext) bool {
    const result = client.fetch(.{
        .location = .{ .url = ctx.url },
        .method = .POST,
        .payload = ctx.payload,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/x-sentry-envelope" },
        },
    }) catch return false;
    return result.status.class() == .success;
}

fn sentryTimeout(io: std.Io) void {
    std.Io.sleep(io, sentry_send_timeout, .awake) catch {};
}

fn sentrySend(ctx: *const SentrySendContext) bool {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var client = std.http.Client{ .allocator = std.heap.page_allocator, .io = io };
    defer client.deinit();

    const Result = union(enum) { send: bool, timeout: void };
    var results: [2]Result = undefined;
    var select: std.Io.Select(Result) = .init(io, &results);
    defer _ = select.cancel();
    select.concurrent(.send, sentryFetch, .{ &client, ctx }) catch return false;
    select.async(.timeout, sentryTimeout, .{io});
    return switch (select.await() catch return false) {
        .send => |success| success,
        .timeout => false,
    };
}

fn sentrySendThread(ctx: *SentrySendContext) void {
    defer releaseSentrySlot();
    defer destroySentryContext(ctx);
    _ = sentrySend(ctx);
}

// ── Datadog (DogStatsD) ─────────────────────────────────────────────────────
// Sends metrics via UDP to the local Datadog agent.
// Set DD_AGENT_HOST and optionally DD_DOGSTATSD_PORT (default: 8125).

var statsd_mutex: std.atomic.Mutex = .unlocked;
var statsd_accepting = true;
var statsd_addr: ?std.Io.net.IpAddress = null;
var statsd_sock: ?std.Io.net.Socket = null;

fn closeStatsdLocked() void {
    if (statsd_sock) |*socket| socket.close(runtime.io);
    statsd_sock = null;
    statsd_addr = null;
}

/// Allow telemetry submissions after a previous `deinit` (primarily for tests
/// and runtimes that are initialized more than once in one process).
pub fn init() void {
    if (comptime builtin.os.tag == .freestanding) return;
    lock(&sentry_mutex);
    defer sentry_mutex.unlock();
    std.debug.assert(sentry_in_flight == 0);
    sentry_accepting = true;

    lock(&statsd_mutex);
    defer statsd_mutex.unlock();
    statsd_accepting = true;
}

/// Stop accepting Sentry submissions, wait for the bounded set of active sends,
/// and close DogStatsD. Call before `runtime.deinit()`. Safe to call repeatedly.
pub fn deinit() void {
    if (comptime builtin.os.tag == .freestanding) return;

    lock(&sentry_mutex);
    sentry_accepting = false;
    while (sentry_in_flight != 0) {
        sentry_mutex.unlock();
        std.Thread.yield() catch {};
        lock(&sentry_mutex);
    }
    sentry_mutex.unlock();

    lock(&statsd_mutex);
    defer statsd_mutex.unlock();
    statsd_accepting = false;
    closeStatsdLocked();
}

fn getStatsdSocketLocked() ?*const std.Io.net.Socket {
    if (statsd_sock != null) return &statsd_sock.?;
    const host = env("DD_AGENT_HOST") orelse return null;
    const port_str = env("DD_DOGSTATSD_PORT") orelse "8125";
    const port = std.fmt.parseInt(u16, port_str, 10) catch return null;
    statsd_addr = std.Io.net.IpAddress.parse(host, port) catch return null;
    const local: std.Io.net.IpAddress = switch (statsd_addr.?) {
        .ip4 => .{ .ip4 = std.Io.net.Ip4Address.unspecified(0) },
        .ip6 => .{ .ip6 = std.Io.net.Ip6Address.unspecified(0) },
    };
    statsd_sock = local.bind(runtime.io, .{ .mode = .dgram }) catch {
        statsd_addr = null;
        return null;
    };
    return &statsd_sock.?;
}

fn statsdSend(message: []const u8) bool {
    if (comptime builtin.os.tag == .freestanding) return false;
    lock(&statsd_mutex);
    defer statsd_mutex.unlock();
    if (!statsd_accepting) return false;
    const socket = getStatsdSocketLocked() orelse return false;
    socket.send(runtime.io, &statsd_addr.?, message) catch {
        closeStatsdLocked();
        return false;
    };
    return true;
}

fn statsdTag(out: []u8, value: []const u8) ?[]const u8 {
    if (value.len > out.len) return null;
    for (value, 0..) |c, i| {
        out[i] = switch (c) {
            ',', '|', ':', '#', '\n', '\r' => '_',
            else => c,
        };
    }
    return out[0..value.len];
}

/// Send a timing metric to Datadog and report whether UDP accepted it.
pub fn ddTimingStatus(path: []const u8, method: []const u8, status: u16, duration_us: u64) bool {
    var path_buf: [256]u8 = undefined;
    var method_buf: [32]u8 = undefined;
    const safe_path = statsdTag(&path_buf, path) orelse return false;
    const safe_method = statsdTag(&method_buf, method) orelse return false;
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "merjs.request.duration:{d}|ms|#path:{s},method:{s},status:{d}\n" ++
            "merjs.request.count:1|c|#path:{s},method:{s},status:{d}",
        .{ duration_us / 1000, safe_path, safe_method, status, safe_path, safe_method, status },
    ) catch return false;
    return statsdSend(msg);
}

pub fn ddTiming(path: []const u8, method: []const u8, status: u16, duration_us: u64) void {
    _ = ddTimingStatus(path, method, status, duration_us);
}

/// Send an error event to Datadog and report whether UDP accepted it.
pub fn ddErrorStatus(path: []const u8, method: []const u8, error_name: []const u8) bool {
    var path_buf: [256]u8 = undefined;
    var method_buf: [32]u8 = undefined;
    var error_buf: [128]u8 = undefined;
    const safe_path = statsdTag(&path_buf, path) orelse return false;
    const safe_method = statsdTag(&method_buf, method) orelse return false;
    const safe_error = statsdTag(&error_buf, error_name) orelse return false;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "merjs.request.error:1|c|#path:{s},method:{s},error:{s}",
        .{ safe_path, safe_method, safe_error },
    ) catch return false;
    return statsdSend(msg);
}

pub fn ddError(path: []const u8, method: []const u8, error_name: []const u8) void {
    _ = ddErrorStatus(path, method, error_name);
}

test "production telemetry declarations compile" {
    std.testing.refAllDecls(@This());
}

test "parseSentryDsn validates a strict HTTPS DSN" {
    const cfg = parseSentryDsn("https://abc123@o1234.ingest.sentry.io/456789").?;
    try std.testing.expectEqualStrings("abc123", cfg.key);
    try std.testing.expectEqualStrings("o1234.ingest.sentry.io", cfg.host);
    try std.testing.expectEqualStrings("456789", cfg.project_id);
    try std.testing.expect(parseSentryDsn("http://abc@host/1") == null);
    try std.testing.expect(parseSentryDsn("https://abc@host/1?bad") == null);
    try std.testing.expect(parseSentryDsn("https://abc@host\n.invalid/1") == null);
}

test "Sentry envelope escapes JSON and owns its input" {
    const allocator = std.testing.allocator;
    var error_name = [_]u8{ 'B', 'a', 'd', '"', '\n' };
    var path = [_]u8{ '/', 'a', '\\', 'b', '\t' };
    const cfg = parseSentryDsn("https://key@host.test/42").?;
    const payload = try buildSentryEnvelope(allocator, cfg, &error_name, &path, "1\"2");
    defer allocator.free(payload);
    @memset(&error_name, 'x');
    @memset(&path, 'x');
    try std.testing.expect(std.mem.indexOf(u8, payload, "Bad\\\"\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "/a\\\\b\\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "1\\\"2") != null);
    try std.testing.expect(payload[payload.len - 1] == '\n');
}

test "Sentry envelope rejects invalid and oversized fields" {
    const allocator = std.testing.allocator;
    const cfg = parseSentryDsn("https://key@host.test/42").?;
    var invalid = [_]u8{0xff};
    try std.testing.expectError(error.InvalidEventField, buildSentryEnvelope(allocator, cfg, &invalid, "/", "1"));
    const oversized = try allocator.alloc(u8, max_sentry_field_len + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'a');
    try std.testing.expectError(error.InvalidEventField, buildSentryEnvelope(allocator, cfg, "Error", oversized, "1"));
}

test "Sentry envelope reports allocation failure without leaking" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const cfg = parseSentryDsn("https://key@host.test/42").?;
    try std.testing.expectError(
        error.OutOfMemory,
        buildSentryEnvelope(failing.allocator(), cfg, "Error", "/", "1"),
    );
}

test "Sentry shutdown rejects new work and waits for active sends" {
    init();
    try std.testing.expect(acquireSentrySlot());

    const TestState = struct {
        var release = std.atomic.Value(bool).init(false);

        fn finishSend() void {
            while (!release.load(.acquire)) std.atomic.spinLoopHint();
            releaseSentrySlot();
        }

        fn shutDown() void {
            deinit();
        }
    };
    TestState.release.store(false, .release);
    const sender = try std.Thread.spawn(.{}, TestState.finishSend, .{});
    const shutdown = try std.Thread.spawn(.{}, TestState.shutDown, .{});

    while (true) {
        lock(&sentry_mutex);
        const accepting = sentry_accepting;
        sentry_mutex.unlock();
        if (!accepting) break;
        std.atomic.spinLoopHint();
    }
    try std.testing.expect(!acquireSentrySlot());

    TestState.release.store(true, .release);
    sender.join();
    shutdown.join();
    lock(&statsd_mutex);
    const statsd_stopped = !statsd_accepting;
    statsd_mutex.unlock();
    try std.testing.expect(statsd_stopped);

    init();
    try std.testing.expect(acquireSentrySlot());
    releaseSentrySlot();
    deinit();
}

test "DogStatsD tags cannot inject metrics and enforce bounds" {
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a_b_c_d_e_f", statsdTag(&out, "a,b|c:d#e\nf").?);
    try std.testing.expect(statsdTag(out[0..2], "long") == null);
}
