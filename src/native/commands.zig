// commands.zig — reference bridge command handlers.
//
// Handlers live in bridge.zig's `registry` and are invoked via
// bridge.dispatch(). Each is permission-gated by the manifest's
// `permissions` list. Add new commands by extending the registry.

const std = @import("std");
const bridge = @import("bridge.zig");

// Re-export the handler signatures so consumer code can register its own.
pub const Ctx = bridge.Ctx;
pub const HandlerFn = bridge.HandlerFn;
pub const HandlerResult = bridge.HandlerResult;

// This release ships: mer.ping, mer.echo (always allowed), and dialog.openFile /
// clipboard.write stubs (permission-gated, return HandlerError until the
// platform NSOpenPanel / NSPasteboard wiring lands after this release).
//
// To add a command in app code:
//   1. write a HandlerFn
//   2. add it to bridge.registry (or a consumer-side registry, later)
