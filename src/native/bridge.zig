// bridge.zig — `window.mer.invoke` JS↔Zig bridge dispatch.
//
// Client side (injected JS shim, see macos.zig):
//   const path = await window.mer.invoke("dialog.openFile", { filters: ["*.md"] });
//
// The shim postMessages a JSON envelope to a WKScriptMessageHandler named
// "merInvoke". The ObjC IMP (macos.zig) pulls the body string and calls
// dispatch() here, which:
//   1. size limit  — reject payloads > max_payload_bytes
//   2. parse       — { cmd, args, id }
//   3. permission  — command.permission ∈ manifest.permissions (deny-default)
//   4. dispatch    — command name → handler via comptime registry
//                    (same shape as Router.exact_map in src/dispatch.zig)
//   5. resolve     — returns a `window.mer._resolve(<id>, ok, <json>)` JS
//                    string the IMP evaluates on the webview
//
// Origin note: the native shell only ever loads http://127.0.0.1:<port>, so the
// origin is trusted loopback by construction. Dynamic origin extraction from
// the WKScriptMessage frame is checked by the macOS backend before dispatch.

const std = @import("std");
const builtin = @import("builtin");
const macos_commands = if (builtin.os.tag == .macos) @import("macos_commands.zig") else struct {};

/// Maximum inbound bridge payload size (keeps the ObjC string bridge bounded).
pub const max_payload_bytes: usize = 64 * 1024;

/// Bridge call context handed to registered handlers.
pub const Ctx = struct {
    allocator: std.mem.Allocator,
    permissions: []const []const u8,
    allowed_origins: []const []const u8 = &.{},
};

/// A JSON value returned by a bridge handler (an owned string of JSON).
pub const Json = []const u8;

/// Error set for bridge dispatch.
pub const BridgeError = error{
    UnknownCommand,
    PermissionDenied,
    OriginNotAllowed,
    PayloadTooLarge,
    ParseError,
    HandlerError,
    OutOfMemory,
};

/// Result of a handler invocation.
pub const HandlerResult = union(enum) {
    ok: Json,
    err: BridgeError,
};

/// A handler takes the parsed `args` value and returns a JSON result or error.
pub const HandlerFn = *const fn (ctx: *Ctx, args: std.json.Value) HandlerResult;

/// A registered command: name, required permission, handler.
pub const Command = struct {
    name: []const u8,
    permission: []const u8,
    handler: HandlerFn,
};

/// The comptime command registry. Add commands here; matched by name in
/// dispatch(). Mirrors the static route table in src/dispatch.zig.
pub const registry = [_]Command{
    .{ .name = "mer.ping", .permission = "", .handler = ping },
    .{ .name = "mer.echo", .permission = "", .handler = echo },
    .{ .name = "dialog.openFile", .permission = "dialog", .handler = dialogOpenFile },
    .{ .name = "dialog.pickDirectory", .permission = "dialog", .handler = dialogPickDirectory },
    .{ .name = "dialog.openDirectory", .permission = "dialog", .handler = dialogPickDirectory },
    .{ .name = "clipboard.read", .permission = "clipboard", .handler = clipboardRead },
    .{ .name = "clipboard.write", .permission = "clipboard", .handler = clipboardWrite },
    .{ .name = "open.external", .permission = "open", .handler = openExternal },
    .{ .name = "open.path", .permission = "open", .handler = openPath },
    .{ .name = "window.setTitle", .permission = "window", .handler = windowSetTitle },
};

fn ping(_: *Ctx, _: std.json.Value) HandlerResult {
    return .{ .ok = "{\"pong\":true}" };
}

fn echo(_: *Ctx, _: std.json.Value) HandlerResult {
    // This release: static ack. Dynamic arg reflection (re-stringify args) needs a
    // JSON writer; the round-trip itself is proven by mer.ping.
    return .{ .ok = "{\"echo\":true}" };
}

fn dialogOpenFile(ctx: *Ctx, args: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const title = argString(args, "title") orelse "Choose a file";
    const result = macos_commands.openPanel(ctx.allocator, .{
        .title = title,
        .can_choose_files = true,
        .can_choose_directories = false,
    }) catch return .{ .err = error.HandlerError };
    const json = if (result) |path| jsonString(ctx.allocator, path) catch return .{ .err = error.OutOfMemory } else "null";
    return .{ .ok = json };
}

fn dialogPickDirectory(ctx: *Ctx, args: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const title = argString(args, "title") orelse "Choose a folder";
    const result = macos_commands.openPanel(ctx.allocator, .{
        .title = title,
        .can_choose_files = false,
        .can_choose_directories = true,
    }) catch return .{ .err = error.HandlerError };
    const json = if (result) |path| jsonString(ctx.allocator, path) catch return .{ .err = error.OutOfMemory } else "null";
    return .{ .ok = json };
}

fn clipboardRead(ctx: *Ctx, _: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const text = macos_commands.clipboardRead() catch return .{ .err = error.HandlerError };
    const json = jsonString(ctx.allocator, text) catch return .{ .err = error.OutOfMemory };
    return .{ .ok = json };
}

fn clipboardWrite(_: *Ctx, args: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const text = switch (args) {
        .string => |value| value,
        .object => |object| blk: {
            const value = object.get("text") orelse return .{ .err = error.HandlerError };
            break :blk if (value == .string) value.string else return .{ .err = error.HandlerError };
        },
        else => return .{ .err = error.HandlerError },
    };
    macos_commands.clipboardWrite(text) catch return .{ .err = error.HandlerError };
    return .{ .ok = "null" };
}

fn openExternal(_: *Ctx, args: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const url = argString(args, "url") orelse if (args == .string) args.string else return .{ .err = error.HandlerError };
    macos_commands.openUrl(url) catch return .{ .err = error.HandlerError };
    return .{ .ok = "null" };
}

fn openPath(_: *Ctx, args: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const path = argString(args, "path") orelse if (args == .string) args.string else return .{ .err = error.HandlerError };
    macos_commands.openPath(path) catch return .{ .err = error.HandlerError };
    return .{ .ok = "null" };
}

fn windowSetTitle(_: *Ctx, args: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const title = argString(args, "title") orelse if (args == .string) args.string else return .{ .err = error.HandlerError };
    macos_commands.setWindowTitle(title) catch return .{ .err = error.HandlerError };
    return .{ .ok = "null" };
}

fn argString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn jsonString(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(value);
    return out.written();
}

/// True if `perm` is granted by the manifest's permissions list. Empty perm
/// means the command is always allowed (e.g. mer.ping).
pub fn hasPermission(ctx: *Ctx, perm: []const u8) bool {
    if (perm.len == 0) return true;
    for (ctx.permissions) |p| {
        if (std.mem.eql(u8, p, perm)) return true;
    }
    return false;
}

pub fn isOriginAllowed(ctx: *Ctx, url: []const u8) bool {
    for (ctx.allowed_origins) |origin| {
        if (std.mem.startsWith(u8, url, origin)) return true;
    }
    return false;
}

const Envelope = struct {
    cmd: []const u8,
    args: std.json.Value = .null,
    id: i64 = 0,
};

/// Dispatch an inbound payload. Returns an owned JS string of the form
/// `window.mer._resolve(<id>,<ok>,<json>);` for the IMP to evaluate.
pub fn dispatch(ctx: *Ctx, payload: []const u8) BridgeError![]u8 {
    const alloc = ctx.allocator;

    if (payload.len > max_payload_bytes) {
        return resolveStr(alloc, 0, false, "\"PayloadTooLarge\"");
    }

    var parsed = std.json.parseFromSlice(Envelope, alloc, payload, .{}) catch {
        return resolveStr(alloc, 0, false, "\"ParseError\"");
    };
    defer parsed.deinit();
    const env = parsed.value;

    for (registry) |cmd| {
        if (std.mem.eql(u8, cmd.name, env.cmd)) {
            if (!hasPermission(ctx, cmd.permission)) {
                return resolveStr(alloc, env.id, false, "\"PermissionDenied\"");
            }
            const res = cmd.handler(ctx, env.args);
            switch (res) {
                .ok => |json| return resolveStr(alloc, env.id, true, json),
                .err => |e| return resolveError(alloc, env.id, @errorName(e)),
            }
        }
    }
    return resolveError(alloc, env.id, "UnknownCommand");
}

pub fn rejectFromPayload(ctx: *Ctx, payload: []const u8, name: []const u8) BridgeError![]u8 {
    var parsed = std.json.parseFromSlice(Envelope, ctx.allocator, payload, .{}) catch {
        return resolveError(ctx.allocator, 0, name);
    };
    defer parsed.deinit();
    return resolveError(ctx.allocator, parsed.value.id, name);
}

/// Format `window.mer._resolve(<id>,<ok>,<json>);` into an owned string.
fn resolveStr(alloc: std.mem.Allocator, id: i64, ok: bool, json: []const u8) BridgeError![]u8 {
    return std.fmt.allocPrint(alloc, "window.mer._resolve({d},{s},{s});", .{ id, if (ok) "true" else "false", json }) catch error.OutOfMemory;
}

fn resolveError(alloc: std.mem.Allocator, id: i64, name: []const u8) BridgeError![]u8 {
    return std.fmt.allocPrint(alloc, "window.mer._resolve({d},false,\"{s}\");", .{ id, name }) catch error.OutOfMemory;
}

// ── tests (standalone: bridge.zig only imports std) ─────────────────────────
const testing = std.testing;

fn newCtx(alloc: std.mem.Allocator, perms: []const []const u8) Ctx {
    return .{ .allocator = alloc, .permissions = perms };
}

test "dispatch: mer.ping resolves ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const js = try dispatch(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":7}");
    try testing.expectEqualStrings("window.mer._resolve(7,true,{\"pong\":true});", js);
}

test "dispatch: unknown command denies by default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const js = try dispatch(&ctx, "{\"cmd\":\"nope\",\"args\":null,\"id\":1}");
    try testing.expectEqualStrings("window.mer._resolve(1,false,\"UnknownCommand\");", js);
}

test "dispatch: permission gate blocks unpermitted command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // manifest grants only "window"; dialog.openFile needs "dialog"
    var ctx = newCtx(alloc, &.{"window"});
    const js = try dispatch(&ctx, "{\"cmd\":\"dialog.openFile\",\"args\":{},\"id\":3}");
    try testing.expectEqualStrings("window.mer._resolve(3,false,\"PermissionDenied\");", js);
}

test "dispatch: permission gate blocks clipboard/open/window commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{"dialog"});
    try testing.expectEqualStrings(
        "window.mer._resolve(4,false,\"PermissionDenied\");",
        try dispatch(&ctx, "{\"cmd\":\"clipboard.read\",\"args\":null,\"id\":4}"),
    );
    try testing.expectEqualStrings(
        "window.mer._resolve(5,false,\"PermissionDenied\");",
        try dispatch(&ctx, "{\"cmd\":\"open.path\",\"args\":{\"path\":\"/tmp\"},\"id\":5}"),
    );
    try testing.expectEqualStrings(
        "window.mer._resolve(6,false,\"PermissionDenied\");",
        try dispatch(&ctx, "{\"cmd\":\"window.setTitle\",\"args\":{\"title\":\"X\"},\"id\":6}"),
    );
}

test "dispatch: oversized payload rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const big = try alloc.alloc(u8, max_payload_bytes + 1);
    @memset(big, 'x');
    const js = try dispatch(&ctx, big);
    try testing.expectEqualStrings("window.mer._resolve(0,false,\"PayloadTooLarge\");", js);
}

test "dispatch: malformed json yields ParseError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const js = try dispatch(&ctx, "not json");
    try testing.expectEqualStrings("window.mer._resolve(0,false,\"ParseError\");", js);
}

test "hasPermission: empty perm always allowed" {
    var ctx = newCtx(testing.allocator, &.{});
    try testing.expect(hasPermission(&ctx, ""));
}

test "isOriginAllowed: allows configured URL prefixes only" {
    var ctx = Ctx{
        .allocator = testing.allocator,
        .permissions = &.{},
        .allowed_origins = &.{ "http://127.0.0.1", "mer://app" },
    };
    try testing.expect(isOriginAllowed(&ctx, "http://127.0.0.1:3000/"));
    try testing.expect(isOriginAllowed(&ctx, "mer://app/index.html"));
    try testing.expect(!isOriginAllowed(&ctx, "https://example.com/"));
}

test "rejectFromPayload preserves caller id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const js = try rejectFromPayload(&ctx, "{\"cmd\":\"mer.ping\",\"id\":42}", "OriginNotAllowed");
    try testing.expectEqualStrings("window.mer._resolve(42,false,\"OriginNotAllowed\");", js);
}
