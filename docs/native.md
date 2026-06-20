# `mer native` — ship a merjs app as a native desktop app

A merjs project can be packaged and run as a small native desktop app: a Zig
shell hosting the system **WebView** (WKWebView on macOS) that loads the merjs
UI over a loopback HTTP server, with a `window.mer.invoke()` JS↔Zig bridge for
native calls. **No Electron, no Chromium, no Node.**

This implements the [zero-native](https://github.com/vercel-labs/zero-native)
model — an unusually clean fit for merjs because the framework *already owns*
the HTTP server, routing, SSR, and hot-reload transport. The shell only adds
the WebView + window + bridge + packaging layer.

> v0.2.53 ships macOS. Linux (WebKitGTK) and Windows (WebView2) are planned.

---

## Quick start

From an existing merjs project:

```bash
mer add native     # scaffold mer.app.zon + native/main.zig, print build.zig snippet
```

Paste the printed snippet into `build.zig` (inside `pub fn build`), then:

```bash
mer native         # dev: launch a native window against the hot-reloading server
mer native build   # prod: build the native shell binary (ReleaseSmall)
mer package        # bundle as a .app (macOS): zig-out/<Display>.app
```

`mer native` reuses the `mer dev` pipeline (codegen → serve) and attaches a
WebView window once the server reports its bound port. UI edits hot-reload
inside the window via the existing `/_mer/events` SSE channel — the shell does
not rebuild on UI edits.

---

## How it works

```
codegen → zig build serve (in-process)
   │  binds 127.0.0.1:0  (OS assigns a free port)
   │  ServerReady → bound port
   ▼
native shell (WKWebView)
   │  loadURL("http://127.0.0.1:<port>/")
   │  window.mer.invoke ⇄ native/commands.zig
   └─ SSE /_mer/events → live reload (dev mode)
```

The server, router, dispatch, SSR, and watcher are reused **unchanged** from the
web framework. The native layer lives under `src/native/`:

| File | Responsibility |
|---|---|
| `shell.zig` | Server-on-port-0 + `ServerReady` handshake + platform `openWindow`. |
| `macos.zig` | WKWebView + NSWindow via extern ObjC primitives (no `@cImport`); `WKScriptMessageHandler` glue for the bridge. |
| `bridge.zig` | `window.mer.invoke` dispatch: size/permission guards + comptime command registry. |
| `manifest.zig` | Comptime parse of `mer.app.zon`. |
| `commands.zig` | Reference bridge command handlers. |
| `main.zig` | The native binary entry point. |

The ObjC interop pattern (extern `objc_getClass`/`sel_registerName`/`objc_msgSend`
+ per-callsite typed casts, no `@cImport`) was proven in `examples/desktop/spike.zig`.

---

## The `mer.app.zon` manifest

```zig
.{
    .id = "com.example.my-app",       // → CFBundleIdentifier
    .name = "my-app",
    .display_name = "My App",         // → CFBundleName + .app bundle name
    .version = "0.1.0",               // → CFBundleVersion
    .web_engine = "system",           // "system" (v0.2.53) | "chromium" (unsupported)
    .server = .{
        .mode = "dev",                // "dev" (hot reload) | "embedded" (prod)
        .host = "127.0.0.1",
        .port = 0,                    // 0 = ephemeral; shell reads back via ServerReady
    },
    .capabilities = .{ "webview", "js_bridge" },
    .permissions = .{ "window", "clipboard", "dialog" },
    .security = .{
        .navigation = .{ .allowed_origins = .{ "http://127.0.0.1", "mer://app" } },
    },
    .windows = .{
        .{ .label = "main", .title = "My App", .width = 1024, .height = 720 },
    },
}
```

The manifest is `@import`-ed comptime (like `build.zig.zon`), so every field
flows into the binary and the `.app` bundle with zero runtime parsing.

---

## The bridge: `window.mer.invoke`

Client code (in a page or WASM glue) calls a named command and awaits a result:

```js
const result = await window.mer.invoke("mer.ping", {});
console.log(result); // { pong: true }
```

Each call is:
1. **size-limited** — payloads > 64 KB are rejected;
2. **permission-checked** — the command's declared permission must appear in the
   manifest's `permissions` list (deny-by-default);
3. **dispatched** — command name → handler via a comptime registry (same shape
   as merjs route tables in `src/dispatch.zig`);
4. **resolved** — the handler's JSON result is delivered back to the awaiting
   Promise via `window.mer._resolve(id, ok, value)`.

### Built-in commands

| Command | Permission | Behavior |
|---|---|---|
| `mer.ping` | _(none)_ | Returns `{ "pong": true }`. Round-trip smoke test. |
| `mer.echo` | _(none)_ | Returns `{ "echo": true }`. |
| `dialog.openFile` | `dialog` | Stub (returns `HandlerError`); NSOpenPanel wiring lands after v0.2.53. |
| `clipboard.write` | `clipboard` | Stub; NSPasteboard wiring lands after v0.2.53. |

### Adding a command

Add a handler and register it in the `registry` array in `src/native/bridge.zig`:

```zig
fn myCommand(ctx: *Ctx, args: std.json.Value) HandlerResult {
    if (!ctx.hasPermission(...)) return .{ .err = error.PermissionDenied };
    return .{ .ok = "{\"ok\":true}" };
}

pub const registry = [_]Command{
    // ...
    .{ .name = "app.myCommand", .permission = "window", .handler = myCommand },
};
```

### Security model

The native shell only ever loads `http://127.0.0.1:<port>`, so the origin is
trusted loopback by construction. The bridge also checks the WebView's current
URL against `security.navigation.allowed_origins` before dispatching commands.

---

## Dev vs production

- **Dev (`mer native`):** the shell runs the server with the file watcher on;
  `/_mer/events` SSE hot-reloads the WebView on `app/` changes. Fast inner loop.
- **Prod (`mer package`):** the SSR binary + WebView shell are built with
  `-Doptimize=ReleaseSmall`; hot reload is off; the result is a `.app` bundle
  whose `Info.plist` reflects `id` / `display_name` / `version` from the
  manifest. Not code-signed — runs locally, not App Store distributable (yet).

---

## Limitations (v0.2.53)

- macOS only (WKWebView). Linux (WebKitGTK) and Windows (WebView2) are planned.
- `dialog` / `clipboard` commands are stubs (return `HandlerError`).
- No code signing / notarization.
- `web_engine = "chromium"` (CEF) is parsed but unsupported.
- `server.mode = "static"` (fully static export over `mer://app`) is a stretch
  goal; v0.2.53 runs the embedded loopback server in both dev and prod.

See `plans/mer-native.md` for the full design and phased roadmap.
