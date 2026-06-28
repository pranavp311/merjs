// platform_commands.zig — facade for platform-specific native command backends.
//
// bridge.zig owns the command registry, permission/origin checks, URL scheme
// checks, and path-root checks. This facade keeps the platform command calls in
// one place so Linux (WebKitGTK) and Windows (WebView2) backends can be added
// without threading OS-specific imports through the security-sensitive bridge.

const std = @import("std");
const builtin = @import("builtin");

pub const has_platform_commands = builtin.os.tag == .macos;

pub const commands = switch (builtin.os.tag) {
    .macos => @import("macos_commands.zig"),
    else => UnsupportedCommands,
};

const UnsupportedCommands = struct {
    pub const OpenPanelOptions = struct {
        title: []const u8,
        can_choose_files: bool = false,
        can_choose_directories: bool = false,
        can_create_directories: bool = false,
    };

    pub fn clipboardRead() ![]const u8 {
        return error.UnsupportedPlatform;
    }

    pub fn clipboardWrite(text: []const u8) !void {
        _ = text;
        return error.UnsupportedPlatform;
    }

    pub fn openPanel(alloc: std.mem.Allocator, options: OpenPanelOptions) !?[]const u8 {
        _ = alloc;
        _ = options;
        return error.UnsupportedPlatform;
    }

    pub fn openUrl(url: []const u8) !void {
        _ = url;
        return error.UnsupportedPlatform;
    }

    pub fn openPath(path: []const u8) !void {
        _ = path;
        return error.UnsupportedPlatform;
    }

    pub fn setWindowTitle(title: []const u8) !void {
        _ = title;
        return error.UnsupportedPlatform;
    }

    pub fn closeWindow() !void {
        return error.UnsupportedPlatform;
    }
};

test "platform command facade selects only implemented backends" {
    try std.testing.expectEqual(builtin.os.tag == .macos, has_platform_commands);
}
