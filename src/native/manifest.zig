// manifest.zig — comptime parsing/validation of `mer.app.zon`.
//
// The manifest is a .zon file imported as a module (`manifest`) wired in
// build.zig to the project's `mer.app.zon`. Because it is `@import`-ed, every
// field is comptime-known and flows into the build with zero runtime parsing.
//
// This mirrors how `build.zig.zon` is consumed by `build.zig` itself.

const std = @import("std");

/// A single window declaration from the manifest.
pub const WindowConfig = struct {
    label: []const u8 = "main",
    title: []const u8 = "merjs app",
    width: u32 = 1024,
    height: u32 = 720,
};

pub const SecurityConfig = struct {
    allowed_origins: []const []const u8 = &.{ "http://127.0.0.1", "http://localhost" },
};

/// Resolved manifest. Built comptime from the imported .zon struct.
pub const Manifest = struct {
    id: []const u8,
    name: []const u8,
    display_name: []const u8,
    version: []const u8,
    web_engine: []const u8,
    server_mode: []const u8,
    host: []const u8,
    port: u16,
    dev: bool,
    window: WindowConfig,
    permissions: []const []const u8,
    security: SecurityConfig = .{},
};

/// Extract a `Manifest` from an imported .zon struct, applying defaults for
/// any optional fields. `zon` is the value of `@import("manifest")`.
pub fn fromZon(comptime zon: anytype) Manifest {
    const T = @TypeOf(zon);

    // server{} block is optional; default to embedded loopback on port 0.
    const has_server = @hasField(T, "server");
    const server_mode = if (has_server) zon.server.mode else "embedded";
    const host = if (has_server) zon.server.host else "127.0.0.1";
    const port: u16 = if (has_server) zon.server.port else 0;

    // First window drives the shell. windows[] is required.
    const win = zon.windows[0];
    const window = WindowConfig{
        .label = win.label,
        .title = win.title,
        .width = win.width,
        .height = win.height,
    };

    // permissions[] is optional.
    const perms: []const []const u8 = if (@hasField(T, "permissions")) &zon.permissions else &.{};

    const security: SecurityConfig = if (@hasField(T, "security")) blk: {
        const SecurityT = @TypeOf(zon.security);
        if (@hasField(SecurityT, "navigation")) {
            const NavigationT = @TypeOf(zon.security.navigation);
            if (@hasField(NavigationT, "allowed_origins")) {
                break :blk .{ .allowed_origins = &zon.security.navigation.allowed_origins };
            }
        }
        break :blk .{};
    } else .{};

    return .{
        .id = zon.id,
        .name = zon.name,
        .display_name = zon.display_name,
        .version = zon.version,
        .web_engine = zon.web_engine,
        .server_mode = server_mode,
        .host = host,
        .port = port,
        .dev = std.mem.eql(u8, server_mode, "dev"),
        .window = window,
        .permissions = perms,
        .security = security,
    };
}

/// True if the manifest declares a capability (e.g. "webview", "js_bridge").
pub fn hasCapability(manifest: Manifest, cap: []const u8) bool {
    _ = manifest;
    _ = cap;
    return false; // capabilities[] parsing lands with the bridge (P2).
}

test "fromZon parses allowed origins" {
    const zon = .{
        .id = "com.example.test",
        .name = "test",
        .display_name = "Test",
        .version = "0.1.0",
        .web_engine = "system",
        .security = .{
            .navigation = .{ .allowed_origins = .{ "http://127.0.0.1", "mer://app" } },
        },
        .windows = .{
            .{ .label = "main", .title = "Test", .width = 800, .height = 600 },
        },
    };
    const parsed = fromZon(zon);
    try std.testing.expectEqual(@as(usize, 2), parsed.security.allowed_origins.len);
    try std.testing.expectEqualStrings("mer://app", parsed.security.allowed_origins[1]);
}
