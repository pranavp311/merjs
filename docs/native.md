# `mer native` — ship a merjs app as a native desktop app

A merjs project can be packaged and run as a small native desktop app: a Zig
shell hosting the system **WebView** (WKWebView on macOS) that loads the merjs
UI over a loopback HTTP server, with a `window.mer.invoke()` JS↔Zig bridge for
native calls. **No Electron, no Chromium, no Node.**

This implements the [zero-native](https://github.com/vercel-labs/zero-native)
model — an unusually clean fit for merjs because the framework *already owns*
the HTTP server, routing, SSR, and hot-reload transport. The shell only adds
the WebView + window + bridge + packaging layer.

> v0.2.5 ships macOS. Linux (WebKitGTK) and Windows (WebView2) are planned.

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
    .web_engine = "system",           // "system" (v0.2.5) | "chromium" (unsupported)
    .server = .{
        .mode = "dev",                // "dev" (hot reload) | "embedded" (prod)
        .host = "127.0.0.1",
        .port = 0,                    // 0 = ephemeral; shell reads back via ServerReady
    },
    .capabilities = .{ "webview", "js_bridge" },
    .permissions = .{ "window", "clipboard", "dialog", "open" },
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
| `mer.echo` | _(none)_ | Returns `{ "echo": true }` as a smoke ack (not an args echo). |
| `clipboard.read` | `clipboard` | Reads plain UTF-8 text from `NSPasteboard`; returns a string, or `""` when no text exists. |
| `clipboard.write` | `clipboard` | Writes plain UTF-8 text to `NSPasteboard`; accepts `{ text }` or a raw string; returns `null`. |
| `dialog.openFile` | `dialog` | Opens `NSOpenPanel` for one file; accepts optional `{ title }`; returns an absolute path string or `null` on cancel. |
| `dialog.pickDirectory` | `dialog` | Opens `NSOpenPanel` for one directory; accepts optional `{ title }`; returns an absolute path string or `null` on cancel. |
| `dialog.openDirectory` | `dialog` | Alias for `dialog.pickDirectory`. |
| `open.external` | `open` | Opens `{ url }` (or raw string) with `NSWorkspace.openURL`; returns `null`. |
| `open.path` | `open` | Opens `{ path }` (or raw string) with the default handler/Finder; returns `null`. |
| `window.setTitle` | `window` | Sets the current key window title from `{ title }` (or raw string); returns `null`. |
| `window.close` | `window` | Closes the current key window (`performClose:`); returns `null`. |

### Custom commands

PR #100 ships the built-in registry above. App-level custom native command
registries are a follow-up API; for now, consumers should rely on the built-ins
rather than editing merjs internals as an extension mechanism.

### Security model

The native shell currently loads the app over an embedded loopback URL such as
`http://127.0.0.1:<port>/`. Before dispatching bridge commands, the macOS
backend checks the `WKScriptMessage` frame origin against
`security.navigation.allowed_origins`. `shell.zig` prepends the exact runtime
origin after the server binds its ephemeral port, so portless manifest entries
(for example `http://127.0.0.1`) do **not** wildcard every local server port.
Per-command origin policy is still a hardening follow-up; PR #100 uses top-level
permissions plus global origins.

---

## Dev vs production

- **Dev (`mer native`):** the shell runs the server with the file watcher on;
  `/_mer/events` SSE hot-reloads the WebView on `app/` changes. Fast inner loop.
- **Prod (`mer package`):** the SSR binary + WebView shell are built with
  `-Doptimize=ReleaseSmall`; hot reload is off; the result is a `.app` bundle
  whose `Info.plist` reflects `id` / `display_name` / `version` from the
  manifest. Not code-signed — runs locally, not App Store distributable (yet).

---

## Limitations (v0.2.5)

- macOS only (WKWebView). Linux (WebKitGTK) and Windows (WebView2) are planned.
- App-level custom bridge command registries and per-command manifest allowlists are deferred; PR #100 uses built-in commands, top-level `permissions`, and global allowed origins.
- No code signing / notarization.
- `web_engine = "chromium"` (CEF) is parsed but unsupported.
- `server.mode = "static"` (fully static export over `mer://app`) is a stretch
  goal; v0.2.5 runs the embedded loopback server in both dev and prod.

See `plans/mer-native.md` for the full design and phased roadmap.
