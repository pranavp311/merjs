// fetch.zig — SSR HTTP client (single + parallel fetch).

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");

pub const default_max_response_size: usize = 8 * 1024 * 1024;
pub const max_response_size_limit: usize = 8 * 1024 * 1024;
pub const max_wasm_requests: usize = 64;
pub const max_wasm_request_bytes: usize = 1024 * 1024;
pub const max_wasm_response_bytes: usize = 32 * 1024 * 1024;
pub const max_fetch_concurrency: usize = 8;
pub const max_fetch_requests: usize = 64;
pub const max_fetch_response_bytes: usize = 32 * 1024 * 1024;
pub const fetch_total_timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(30), .clock = .awake };

/// Options for a single HTTP request made during server-side rendering.
pub const FetchRequest = struct {
    url: []const u8,
    method: std.http.Method = .GET,
    body: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    /// Maximum decompressed response body size.
    max_response_size: usize = default_max_response_size,
};

/// Response from an HTTP fetch. Owns the exact body slice — call `deinit()` when done.
pub const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: FetchResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

// ── Freestanding (Workers) two-phase fetch state ─────────────────────────────

const wasm_alloc = if (builtin.os.tag == .freestanding)
    std.heap.wasm_allocator
else
    @as(std.mem.Allocator, undefined);

pub const WasmFetchError = enum(u32) {
    none = 0,
    too_many_requests = 1,
    request_bytes_exceeded = 2,
    out_of_memory = 3,
    protocol_mismatch = 4,
    invalid_result = 5,
    response_too_large = 6,
    invalid_max_response_size = 7,
    response_bytes_exceeded = 8,
};

const ExpectedRequest = struct {
    hash: u64,
    max_response_size: usize,
};

const CachedResponse = struct {
    status: std.http.Status,
    body: []u8,
};

var wasm_collect_mode = false;
var wasm_replay_index: usize = 0;
var wasm_last_error: WasmFetchError = .none;
var wasm_requests_buf: std.ArrayListUnmanaged(u8) = .empty;
var wasm_expected_state_buf: std.ArrayListUnmanaged(u8) = .empty;
var wasm_expected: std.ArrayListUnmanaged(ExpectedRequest) = .empty;
var wasm_fetch_cache: std.AutoHashMapUnmanaged(u32, CachedResponse) = .{};
var wasm_cached_bytes: usize = 0;

fn hashSlice(hash: *std.hash.Wyhash, bytes: ?[]const u8) void {
    var len_buf: [8]u8 = undefined;
    const len = if (bytes) |slice| @as(u64, @intCast(slice.len)) else std.math.maxInt(u64);
    std.mem.writeInt(u64, &len_buf, len, .little);
    hash.update(&len_buf);
    if (bytes) |slice| hash.update(slice);
}

fn requestHash(opts: FetchRequest) u64 {
    var hash = std.hash.Wyhash.init(0);
    hashSlice(&hash, @tagName(opts.method));
    hashSlice(&hash, opts.url);
    hashSlice(&hash, opts.body);
    for (opts.headers) |header| {
        hashSlice(&hash, header.name);
        hashSlice(&hash, header.value);
    }
    var max_buf: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &max_buf, opts.max_response_size, .little);
    hash.update(&max_buf);
    return hash.final();
}

fn appendInt(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn serializedRequestSize(opts: FetchRequest) ?usize {
    var size: usize = 24;
    size = std.math.add(usize, size, @tagName(opts.method).len) catch return null;
    size = std.math.add(usize, size, opts.url.len) catch return null;
    if (opts.body) |body| size = std.math.add(usize, size, body.len) catch return null;
    for (opts.headers) |header| {
        size = std.math.add(usize, size, 8) catch return null;
        size = std.math.add(usize, size, header.name.len) catch return null;
        size = std.math.add(usize, size, header.value.len) catch return null;
    }
    return size;
}

fn requestValidationError(opts: FetchRequest, request_count: usize, serialized_bytes: usize) ?WasmFetchError {
    if (opts.max_response_size > max_response_size_limit) return .invalid_max_response_size;
    if (request_count >= max_wasm_requests) return .too_many_requests;
    const record_size = serializedRequestSize(opts) orelse return .request_bytes_exceeded;
    if (record_size > max_wasm_request_bytes -| serialized_bytes or
        opts.url.len > std.math.maxInt(u32) or
        (opts.body != null and opts.body.?.len > std.math.maxInt(u32)) or
        opts.headers.len > std.math.maxInt(u32) or
        opts.max_response_size > std.math.maxInt(u32)) return .request_bytes_exceeded;
    for (opts.headers) |header| {
        if (header.name.len > std.math.maxInt(u32) or header.value.len > std.math.maxInt(u32))
            return .request_bytes_exceeded;
    }
    return null;
}

fn collectRequest(opts: FetchRequest) void {
    if (requestValidationError(opts, wasm_expected.items.len, wasm_requests_buf.items.len)) |validation_error| {
        wasm_last_error = validation_error;
        return;
    }

    const old_len = wasm_requests_buf.items.len;
    const id: u32 = @intCast(wasm_expected.items.len);
    const method = @tagName(opts.method);
    appendInt(&wasm_requests_buf, wasm_alloc, id) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    appendInt(&wasm_requests_buf, wasm_alloc, @intCast(opts.max_response_size)) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    appendInt(&wasm_requests_buf, wasm_alloc, @intCast(method.len)) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    appendInt(&wasm_requests_buf, wasm_alloc, @intCast(opts.url.len)) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    appendInt(&wasm_requests_buf, wasm_alloc, if (opts.body) |body| @intCast(body.len) else std.math.maxInt(u32)) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    appendInt(&wasm_requests_buf, wasm_alloc, @intCast(opts.headers.len)) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    wasm_requests_buf.appendSlice(wasm_alloc, method) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    wasm_requests_buf.appendSlice(wasm_alloc, opts.url) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    if (opts.body) |body| wasm_requests_buf.appendSlice(wasm_alloc, body) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    for (opts.headers) |header| {
        appendInt(&wasm_requests_buf, wasm_alloc, @intCast(header.name.len)) catch {
            wasm_requests_buf.shrinkRetainingCapacity(old_len);
            wasm_last_error = .out_of_memory;
            return;
        };
        appendInt(&wasm_requests_buf, wasm_alloc, @intCast(header.value.len)) catch {
            wasm_requests_buf.shrinkRetainingCapacity(old_len);
            wasm_last_error = .out_of_memory;
            return;
        };
        wasm_requests_buf.appendSlice(wasm_alloc, header.name) catch {
            wasm_requests_buf.shrinkRetainingCapacity(old_len);
            wasm_last_error = .out_of_memory;
            return;
        };
        wasm_requests_buf.appendSlice(wasm_alloc, header.value) catch {
            wasm_requests_buf.shrinkRetainingCapacity(old_len);
            wasm_last_error = .out_of_memory;
            return;
        };
    }
    wasm_expected.append(wasm_alloc, .{
        .hash = requestHash(opts),
        .max_response_size = opts.max_response_size,
    }) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
    };
}

pub const WasmCollection = struct {
    bytes: []const u8,
    error_code: u32,
};

/// Begin request collection. The serialized request list is returned by wasmEndCollect.
pub fn wasmBeginCollect() void {
    _ = wasmClearCache();
    wasm_collect_mode = true;
    wasm_replay_index = 0;
    wasm_last_error = .none;
    wasm_requests_buf.clearRetainingCapacity();
    wasm_expected.clearRetainingCapacity();
}

/// End collection and return the bounded binary request list in WASM memory.
pub fn wasmEndCollect() WasmCollection {
    wasm_collect_mode = false;
    wasm_replay_index = 0;
    wasm_expected_state_buf.clearRetainingCapacity();
    for (wasm_expected.items) |expected| {
        var hash_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &hash_bytes, expected.hash, .little);
        wasm_expected_state_buf.appendSlice(wasm_alloc, &hash_bytes) catch {
            wasm_last_error = .out_of_memory;
            break;
        };
        appendInt(&wasm_expected_state_buf, wasm_alloc, @intCast(expected.max_response_size)) catch {
            wasm_last_error = .out_of_memory;
            break;
        };
    }
    return .{ .bytes = wasm_requests_buf.items, .error_code = @intFromEnum(wasm_last_error) };
}

/// Opaque expected-request state copied by the host before restoring a dry-run
/// linear-memory snapshot.
pub fn wasmExpectedState() []const u8 {
    return wasm_expected_state_buf.items;
}

/// Restore expected request hashes after the host has rolled back the dry run.
pub fn wasmRestoreExpectedState(bytes: []const u8) u32 {
    if (bytes.len % 12 != 0 or bytes.len / 12 > max_wasm_requests) {
        wasm_last_error = .protocol_mismatch;
        return @intFromEnum(wasm_last_error);
    }
    wasm_expected.clearRetainingCapacity();
    wasm_replay_index = 0;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 12) {
        const hash = std.mem.readInt(u64, bytes[offset..][0..8], .little);
        const max_response_size = std.mem.readInt(u32, bytes[offset + 8 ..][0..4], .little);
        if (max_response_size > max_response_size_limit) {
            wasm_last_error = .protocol_mismatch;
            return @intFromEnum(wasm_last_error);
        }
        wasm_expected.append(wasm_alloc, .{ .hash = hash, .max_response_size = max_response_size }) catch {
            wasm_last_error = .out_of_memory;
            return @intFromEnum(wasm_last_error);
        };
    }
    wasm_last_error = .none;
    return 0;
}

fn statusFromInt(value: u16) ?std.http.Status {
    if (value < 100 or value > 599) return null;
    return @enumFromInt(value);
}

fn responseFitsCache(current: usize, replaced: usize, new_len: usize) bool {
    return new_len <= max_wasm_response_bytes -| (current -| replaced);
}

/// Store one JS-fetched response by collection request ID. Returns a WasmFetchError code.
pub fn wasmProvideResult(id: u32, status_code: u32, body: []const u8) u32 {
    if (id >= wasm_expected.items.len or status_code > std.math.maxInt(u16)) {
        wasm_last_error = .invalid_result;
        return @intFromEnum(wasm_last_error);
    }
    const expected = wasm_expected.items[id];
    if (body.len > expected.max_response_size) {
        wasm_last_error = .response_too_large;
        return @intFromEnum(wasm_last_error);
    }
    const replaced_len = if (wasm_fetch_cache.get(id)) |cached| cached.body.len else 0;
    if (!responseFitsCache(wasm_cached_bytes, replaced_len, body.len)) {
        wasm_last_error = .response_bytes_exceeded;
        return @intFromEnum(wasm_last_error);
    }
    const status = statusFromInt(@intCast(status_code)) orelse {
        wasm_last_error = .invalid_result;
        return @intFromEnum(wasm_last_error);
    };
    const owned = wasm_alloc.dupe(u8, body) catch {
        wasm_last_error = .out_of_memory;
        return @intFromEnum(wasm_last_error);
    };
    if (wasm_fetch_cache.getPtr(id)) |cached| {
        wasm_cached_bytes -= cached.body.len;
        wasm_alloc.free(cached.body);
        cached.* = .{ .status = status, .body = owned };
        wasm_cached_bytes += owned.len;
        return 0;
    }
    wasm_fetch_cache.put(wasm_alloc, id, .{ .status = status, .body = owned }) catch {
        wasm_alloc.free(owned);
        wasm_last_error = .out_of_memory;
        return @intFromEnum(wasm_last_error);
    };
    wasm_cached_bytes += owned.len;
    return 0;
}

/// Free all bridge-owned request and response storage and return the final error code.
pub fn wasmClearCache() u32 {
    const error_code = @intFromEnum(wasm_last_error);
    var it = wasm_fetch_cache.iterator();
    while (it.next()) |entry| wasm_alloc.free(entry.value_ptr.body);
    wasm_fetch_cache.deinit(wasm_alloc);
    wasm_fetch_cache = .{};
    wasm_cached_bytes = 0;
    wasm_requests_buf.deinit(wasm_alloc);
    wasm_requests_buf = .empty;
    wasm_expected_state_buf.deinit(wasm_alloc);
    wasm_expected_state_buf = .empty;
    wasm_expected.deinit(wasm_alloc);
    wasm_expected = .empty;
    wasm_replay_index = 0;
    return error_code;
}

const NativeFetchFn = *const fn (std.Io, std.mem.Allocator, FetchRequest) anyerror!FetchResponse;

fn fetchUnpooled(io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest) !FetchResponse {
    // A client local to the request cannot safely share its allocator or pool across callers.
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response_buf = try allocator.alloc(u8, opts.max_response_size);
    errdefer allocator.free(response_buf);
    var response_writer: std.Io.Writer = .fixed(response_buf);

    const result = try client.fetch(.{
        .location = .{ .url = opts.url },
        .method = opts.method,
        .payload = opts.body,
        .extra_headers = opts.headers,
        .response_writer = &response_writer,
        .keep_alive = false,
    });

    response_buf = try allocator.realloc(response_buf, response_writer.end);
    return .{ .status = result.status, .body = response_buf };
}

fn invokeFetch(fetch_fn: NativeFetchFn, io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest) anyerror!FetchResponse {
    return fetch_fn(io, allocator, opts);
}

fn fetchWithTimeout(io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest, timeout: std.Io.Clock.Duration, fetch_fn: NativeFetchFn) !FetchResponse {
    const Completion = union(enum) {
        response: anyerror!FetchResponse,
        timeout: std.Io.Cancelable!void,
    };
    var completion_buf: [2]Completion = undefined;
    var select = std.Io.Select(Completion).init(io, &completion_buf);
    select.async(.response, invokeFetch, .{ fetch_fn, io, allocator, opts });
    select.async(.timeout, std.Io.Clock.Duration.sleep, .{ timeout, io });

    switch (try select.await()) {
        .response => |result| {
            select.cancelDiscard();
            return result;
        },
        .timeout => |result| try result,
    }

    while (select.cancel()) |completion| switch (completion) {
        .response => |result| if (result) |response| response.deinit(allocator) else |_| {},
        .timeout => {},
    };
    return error.FetchTimeout;
}

var native_fetch_slots = std.atomic.Value(usize).init(max_fetch_concurrency);

fn tryAcquireFetchSlot() bool {
    var available = native_fetch_slots.load(.acquire);
    while (available != 0) {
        if (native_fetch_slots.cmpxchgWeak(available, available - 1, .acq_rel, .acquire)) |updated| {
            available = updated;
        } else return true;
    }
    return false;
}

fn releaseFetchSlot() void {
    const previous = native_fetch_slots.fetchAdd(1, .release);
    std.debug.assert(previous < max_fetch_concurrency);
}

fn fetchNative(io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest, timeout: std.Io.Clock.Duration, fetch_fn: NativeFetchFn) !FetchResponse {
    if (!tryAcquireFetchSlot()) return error.FetchConcurrencyLimitExceeded;
    defer releaseFetchSlot();
    return fetchWithTimeout(io, allocator, opts, timeout, fetch_fn);
}

/// Make an HTTP request from a server-side page handler.
pub fn fetch(allocator: std.mem.Allocator, opts: FetchRequest) !FetchResponse {
    if (opts.max_response_size > max_response_size_limit) return error.ResponseSizeLimitExceeded;
    if (comptime builtin.os.tag == .freestanding) {
        if (wasm_collect_mode) {
            collectRequest(opts);
            return error.WasmCollecting;
        }
        return replayRequest(allocator, opts) orelse error.WasmProtocolMismatch;
    }
    return fetchNative(runtime.io, allocator, opts, fetch_total_timeout, fetchUnpooled);
}

fn fetchWorker(allocator: std.mem.Allocator, opts: FetchRequest, out: *?FetchResponse) void {
    defer releaseFetchSlot();
    out.* = fetchWithTimeout(runtime.io, allocator, opts, fetch_total_timeout, fetchUnpooled) catch null;
}

fn replayRequest(allocator: std.mem.Allocator, opts: FetchRequest) ?FetchResponse {
    const id = wasm_replay_index;
    wasm_replay_index += 1;
    if (id >= wasm_expected.items.len or wasm_expected.items[id].hash != requestHash(opts)) {
        wasm_last_error = .protocol_mismatch;
        return null;
    }
    const cached = wasm_fetch_cache.get(@intCast(id)) orelse return null;
    if (cached.body.len > opts.max_response_size) {
        wasm_last_error = .response_too_large;
        return null;
    }
    const owned = allocator.dupe(u8, cached.body) catch {
        wasm_last_error = .out_of_memory;
        return null;
    };
    return .{ .status = cached.status, .body = owned };
}

/// Fetch multiple URLs in parallel. Returns caller-owned results in input order.
pub fn fetchAll(allocator: std.mem.Allocator, requests: []const FetchRequest) []?FetchResponse {
    if (requests.len > max_fetch_requests) return allocator.alloc(?FetchResponse, 0) catch &.{};
    const results = allocator.alloc(?FetchResponse, requests.len) catch return &.{};
    @memset(results, null);
    if (requests.len == 0) return results;

    if (comptime builtin.os.tag == .freestanding) {
        for (requests, 0..) |opts, i| {
            if (wasm_collect_mode) collectRequest(opts) else results[i] = replayRequest(allocator, opts);
        }
        return results;
    }

    if (comptime builtin.single_threaded) {
        var response_bytes: usize = 0;
        for (requests, 0..) |opts, i| {
            const response = fetch(allocator, opts) catch continue;
            if (response.body.len > max_fetch_response_bytes -| response_bytes) {
                response.deinit(allocator);
                continue;
            }
            response_bytes += response.body.len;
            results[i] = response;
        }
        return results;
    }

    var threads: [max_fetch_requests]?std.Thread = @splat(null);
    for (requests, 0..) |opts, i| {
        if (opts.max_response_size > max_response_size_limit or !tryAcquireFetchSlot()) continue;
        threads[i] = std.Thread.spawn(.{}, fetchWorker, .{ std.heap.smp_allocator, opts, &results[i] }) catch blk: {
            fetchWorker(std.heap.smp_allocator, opts, &results[i]);
            break :blk null;
        };
    }
    for (threads[0..requests.len]) |thread| if (thread) |started| started.join();

    var response_bytes: usize = 0;
    for (results) |*response| {
        if (response.*) |temporary| {
            if (temporary.body.len > max_fetch_response_bytes -| response_bytes) {
                temporary.deinit(std.heap.smp_allocator);
                response.* = null;
                continue;
            }
            const owned = allocator.dupe(u8, temporary.body) catch {
                temporary.deinit(std.heap.smp_allocator);
                response.* = null;
                continue;
            };
            response_bytes += owned.len;
            const status = temporary.status;
            temporary.deinit(std.heap.smp_allocator);
            response.* = .{ .status = status, .body = owned };
        }
    }
    return results;
}

test "native fetch admission fails fast at the process-wide limit" {
    if (builtin.os.tag == .freestanding) return error.SkipZigTest;
    for (0..max_fetch_concurrency) |_| try std.testing.expect(tryAcquireFetchSlot());
    defer for (0..max_fetch_concurrency) |_| releaseFetchSlot();
    try std.testing.expect(!tryAcquireFetchSlot());
    try std.testing.expectError(error.FetchConcurrencyLimitExceeded, fetch(std.testing.allocator, .{ .url = "http://unused.invalid" }));
    const results = fetchAll(std.testing.allocator, &.{.{ .url = "http://unused.invalid" }});
    defer std.testing.allocator.free(results);
    try std.testing.expect(results[0] == null);
}

test "stalled native fetch is canceled and releases admission" {
    if (builtin.os.tag == .freestanding) return error.SkipZigTest;
    const Stall = struct {
        var event: std.Io.Event = .unset;

        fn fetch(io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest) !FetchResponse {
            _ = allocator;
            _ = opts;
            try event.wait(io);
            return error.UnexpectedStallRelease;
        }
    };
    try std.testing.expectError(error.FetchTimeout, fetchNative(
        std.testing.io,
        std.testing.allocator,
        .{ .url = "http://stalled.invalid" },
        .{ .raw = .zero, .clock = .awake },
        Stall.fetch,
    ));
    for (0..max_fetch_concurrency) |_| try std.testing.expect(tryAcquireFetchSlot());
    defer for (0..max_fetch_concurrency) |_| releaseFetchSlot();
    try std.testing.expect(!tryAcquireFetchSlot());
}

test "FetchRequest defaults to a bounded response" {
    const request: FetchRequest = .{ .url = "https://example.com" };
    try std.testing.expectEqual(default_max_response_size, request.max_response_size);
}

test "fetch rejects an unsafe response limit before allocating or opening a client" {
    try std.testing.expectError(error.ResponseSizeLimitExceeded, fetch(std.testing.allocator, .{
        .url = "https://example.com",
        .max_response_size = max_response_size_limit + 1,
    }));
}

test "serialized request sizing includes method body and duplicate headers" {
    const request: FetchRequest = .{
        .url = "https://example.com/data",
        .method = .POST,
        .body = "payload",
        .headers = &.{
            .{ .name = "x-test", .value = "one" },
            .{ .name = "x-test", .value = "two" },
        },
        .max_response_size = 1234,
    };
    try std.testing.expectEqual(@as(?usize, 24 + 4 + 24 + 7 + 8 + 6 + 3 + 8 + 6 + 3), serializedRequestSize(request));
    try std.testing.expect(requestHash(request) != requestHash(.{ .url = request.url }));
}

test "WASM response status validation preserves actual status" {
    try std.testing.expectEqual(std.http.Status.created, statusFromInt(201).?);
    try std.testing.expectEqual(@as(u10, 299), @intFromEnum(statusFromInt(299).?));
    try std.testing.expect(statusFromInt(99) == null);
    try std.testing.expect(statusFromInt(600) == null);
}

test "WASM aggregate response admission accounts for replacements" {
    try std.testing.expect(responseFitsCache(max_wasm_response_bytes, 4, 4));
    try std.testing.expect(!responseFitsCache(max_wasm_response_bytes, 4, 5));
}

test "WASM request admission enforces count bytes and response bounds" {
    const request: FetchRequest = .{ .url = "https://example.com" };
    try std.testing.expectEqual(WasmFetchError.too_many_requests, requestValidationError(request, max_wasm_requests, 0).?);
    try std.testing.expectEqual(WasmFetchError.request_bytes_exceeded, requestValidationError(request, 0, max_wasm_request_bytes).?);
    try std.testing.expectEqual(WasmFetchError.invalid_max_response_size, requestValidationError(.{
        .url = request.url,
        .max_response_size = max_response_size_limit + 1,
    }, 0, 0).?);
}

test "zero and over-limit request lists return allocator-owned empty slices" {
    const empty = fetchAll(std.testing.allocator, &.{});
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    var too_many: [max_fetch_requests + 1]FetchRequest = undefined;
    for (&too_many) |*request| request.* = .{ .url = "https://example.com" };
    const rejected = fetchAll(std.testing.allocator, &too_many);
    defer std.testing.allocator.free(rejected);
    try std.testing.expectEqual(@as(usize, 0), rejected.len);
}
