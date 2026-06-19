// commands.zig — reference bridge command handlers (P2).
//
// Planned handlers: dialog.openFile, clipboard.write, window.setTitle.
// Each is opt-in via the manifest's bridge.commands[] and permission-gated.

const std = @import("std");
const bridge = @import("bridge.zig");

// P2: pub fn openFile(ctx: *bridge.Ctx, args: OpenFileArgs) !bridge.Json { ... }
