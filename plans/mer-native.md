# Plan: `mer native` — ship a merjs app as a native desktop/mobile app

**Target release:** `release/v0.2.6`
**Feature branch:** `feat/mer-native` (based off `release/v0.2.6`)
**Fork:** https://github.com/pranavp311/merjs
**Issue:** the zero-native model — a Zig shell hosting a system WebView over the merjs loopback server, with a `window.mer.invoke()` JS↔Zig bridge. No Electron, no Chromium, no Node.

---

## 0. What already exists (do not redo)

This is the single most important finding. The issue frames P0 ("Spike: minimal Zig + WKWebView that loads the dev server via `ServerReady`") as work to be done. **It is already done and shipping:**

| Issue claim | Reality in-tree | File |
|---|---|---|
| "P0 — Spike (macOS)" | ✅ **Already works.** Spawns server on `port=0`, reads bound port via `ServerReady`, opens `NSWindow`+`WKWebView`, loads `http://127.0.0.1:<port>/`. | `examples/desktop/main.zig` |
| ObjC bridge pattern unproven | ✅ Researched + decided in `spike.zig`: **extern `objc_getClass`/`sel_registerName`/`objc_msgSend` + per-callsite typed casts, NO `@cImport`** (AppKit.h breaks translate-c). | `examples/desktop/spike.zig` (#50) |
| `ServerReady` / `Config.ready` / `port=0` handshake | ✅ Implemented. `ServerReady{event,port}` uses `std.atomic.Value(bool)`; `listen()` sets `r.port = net_server.socket.address.getPort()` then `r.set()`. | `src/server.zig:42,59,110-113` |
| `zig build desktop` + `.app` bundle | ✅ Exists. Links AppKit/WebKit/Foundation, emits `MerApp.app/Contents/{MacOS/merapp,Info.plist}`. | `build.zig:333-375` |
| `MerApp.app` stub to "fill in" | The checked-in `MerApp.app/Contents/MacOS/merapp` is a built artifact (5.2 MB arm64 Mach-O), not source. It's a build *output*, not a template. | `MerApp.app/` |

**Implication:** P0 is verification-only. The real work is P1–P5: turn the hardcoded `examples/desktop/main.zig` spike into a manifest-driven, bridge-enabled, CLI-accessible, packageable product surface under `mer native` / `mer package`.

---

## 1. Decisions (resolves the issue's open questions)

### Q1: Vendor a WebView abstraction, or depend on zero-native?
**Decision: Vendor a thin, merjs-owned abstraction. Do NOT depend on zero-native.**

Rationale from the code:
- zero-native is large (~40 source files across `src/{bridge,platform,primitives,tooling,security,embed,...}`) and pulls in CEF/C++ host glue (`src/platform/*/cef_host.cpp`, `webview2_host.cpp`, `gtk_host.c`) that merjs doesn't want in its build graph.
- merjs already proved the ObjC interop pattern itself, in pure Zig, with zero `@cImport` — it doesn't need zero-native's `.m`/`.mm`/`.cpp` host files for the system-WebView path.
- zero-native's `build.zig.zon` has `.dependencies = .{}` — fine to consume, but its manifest schema (`app.zon` with `bridge.commands[]`, `cef`, `icons`, `platforms`) is richer than merjs needs and diverges from the issue's proposed `mer.app.zon`.
- Both target Zig 0.16, so there's no language barrier — but the coupling cost (CEF, C++ toolchain, their manifest versioning) outweighs the savings for a system-WebView-only v1.

We will **study** zero-native's `src/bridge/root.zig`, `src/primitives/app_manifest/root.zig`, and `src/tooling/{package,manifest}.zig` as design references (their command/permission/origin model is good and the issue already mirrors it), but write merjs-native code under `src/native/`.

### Q2: `system` WebView vs bundled Chromium/CEF?
**Decision: system-only for v0.2.6.** CEF is explicitly deferred. `web_engine = "chromium"` is a manifest value we *parse* but reject with a clear error for now.

### Q3: Bridge auth model — per-command permissions vs capability allowlist?
**Decision: per-command permissions in the manifest**, mirroring zero-native's `bridge.commands[]` (each command declares `permissions` + `origins`). This is more precise than a global capability allowlist and matches `dispatch.zig`'s per-route shape. A command with no matching registration is rejected (deny-by-default).

### Q4: Prod = live SSR (embedded server) vs static export?
**Decision: `server.mode` switch in the manifest, as the issue proposes.** v0.2.6 ships `embedded` (in-process loopback server, the proven path). `static` (serve a prerendered `dist/` over `mer://app` custom scheme) is a stretch goal; we stub the manifest field and implement only if P5 lands cleanly.

---

## 2. Target developer experience

```bash
mer add native           # scaffold mer.app.zon + native/ shell glue into an existing project
mer native               # DEV: launch a native window against the hot-reloading dev server
mer native build         # PROD: build SSR binary + WebView shell (release optimize)
mer package              # bundle platform artifact: .app (mac) — AppImage/.exe later
```

`mer native` (dev) reuses the `mer dev` pipeline (codegen → `zig build serve`) and attaches a WebView window once `ServerReady` fires with the bound port. The shell does **not** rebuild on UI edits — it keeps the `/_mer/events` SSE channel (`src/watcher.zig:115 handleSse`) live for hot reload.

---

## 3. Architecture (what gets built)

```
mer native (dev)                          mer package (prod)
────────────────                          ──────────────────
codegen → zig build serve                 SSR binary (ReleaseSmall) + shell, statically linked
   │  binds 127.0.0.1:0                       │  binds 127.0.0.1:0 in-process
   │  ServerReady → bound port                │  ServerReady → bound port
   ▼                                          ▼
native/shell  (WKWebView)                  same shell, statically linked
   │  loadURL("http://127.0.0.1:<port>")      │  loadURL or mer://app custom scheme
   │  window.mer.invoke ⇄ commands.zig         │  hot reload off, devtools off
   └─ SSE /_mer/events → live reload           └─ packaged .app
```

### New code under `src/native/`

| File | Responsibility | Reuses |
|---|---|---|
| `src/native/shell.zig` | Platform-agnostic window + WebView lifecycle, event loop, `loadURL`. Defines a `Shell` interface with `init/loop/loadURL/setTitle/deinit`. | `examples/desktop/main.zig` (lifted + generalized) |
| `src/native/macos.zig` | macOS backend: the extern-ObjC `send*` helpers + `WKWebView`/`NSWindow`. One `extern fn` triplet, per-callsite casts. | `examples/desktop/{main,spike}.zig` |
| `src/native/linux.zig` | WebKitGTK backend behind the same `Shell` interface (P4). | new |
| `src/native/bridge.zig` | `window.mer.invoke` dispatch: size/origin/permission checks → registered handler. Command registry shaped like `dispatch.zig` route tables. | `src/dispatch.zig` pattern |
| `src/native/manifest.zig` | Parse `mer.app.zon` via `@import` (same trick `build.zig` uses for `build.zig.zon`). Validate `web_engine`, `capabilities`, `permissions`, `windows`. | zero-native `app_manifest` as reference |
| `src/native/commands.zig` | Reference command handlers: `dialog.openFile`, `clipboard.write`, `window.setTitle`. Opt-in, permission-gated. | new |

### Build / packaging

| File | Responsibility |
|---|---|
| `build/native.zig` | `addNativeStep(b, mer_mod, ...)` — builds the shell exe, links frameworks per-OS, emits the `.app` bundle. Factored out of `build.zig:333-375`. |
| `build.zig` | Adds `native` and `package` steps; gates macOS-only code on `target.result.os.tag == .macos` (existing pattern at `build.zig:318,334`). |

### CLI

`cli.zig` gains three commands in the existing `cmd`-dispatch chain (`cli.zig:75-110`):
- `native` → `cmdNative(alloc, args)` — runs `zig build serve` in a child process (reuse `cmdDev`'s spawn pattern at `cli.zig:699`), then spawns the shell binary pointing at the dev server's `ServerReady` port.
- `native build` → `cmdNativeBuild` — `zig build -Doptimize=ReleaseSmall native`.
- `package` → `cmdPackage` — `zig build package` (macOS: fills `MerApp.app` from manifest values: `CFBundleIdentifier`←`id`, `CFBundleName`←`display_name`, `CFBundleVersion`←`version`).

`mer add native` → `cmdAddNative` in the `cmdAdd` chain (`cli.zig:772`), scaffolding `mer.app.zon` + `native/commands.zig` template via `@embedFile` (existing `cmdAdd{Css,Wasm,Worker}` pattern, `cli.zig:791+`).

---

## 4. The `mer.app.zon` manifest

```zig
.{
    .id = "ai.trilok.my-app",
    .name = "my-app",
    .display_name = "My App",
    .version = "0.1.0",
    .web_engine = "system",                 // "system" (v0.2.6) | "chromium" (rejected w/ error)
    .server = .{
        .mode = "embedded",                 // "embedded" (prod) | "dev" (attach to mer dev)
        .host = "127.0.0.1",
        .port = 0,                           // 0 = ephemeral; shell reads back via ServerReady
    },
    .capabilities = .{ "webview", "js_bridge" },
    .permissions = .{ "window", "clipboard", "dialog" },
    .security = .{
        .navigation = .{ .allowed_origins = .{ "http://127.0.0.1", "mer://app" } },
    },
    .windows = .{
        .{ .label = "main", .title = "My App", .width = 1024, .height = 720 },
    },
    .bridge = .{
        .commands = .{
            .{ .name = "dialog.openFile", .permissions = .{ "dialog" }, .origins = .{ "http://127.0.0.1" } },
            .{ .name = "clipboard.write", .permissions = .{ "clipboard" }, .origins = .{ "http://127.0.0.1" } },
            .{ .name = "window.setTitle", .permissions = .{ "window" }, .origins = .{ "http://127.0.0.1" } },
        },
    },
}
```

Parsed at comptime via `@import("mer.app.zon")` in the generated `native/main.zig`, so manifest values (window size, title, bundle id) flow into the build with zero runtime parsing.

---

## 5. The bridge: `window.mer.invoke`

Client → Zig, mirroring zero-native's `window.zero.invoke`:

```js
const path = await window.mer.invoke("dialog.openFile", { filters: ["*.md"] });
```

```zig
// native/commands.zig — registered handlers, opt-in only
pub fn openFile(ctx: *mer.native.Ctx, args: OpenFileArgs) !mer.native.Json {
    if (!ctx.hasPermission(.dialog)) return error.PermissionDenied;
    // ...call platform dialog API via the same extern-ObjC interop...
}
```

Bridge contract (`src/native/bridge.zig`):
1. **Size limit:** reject payloads > 64 KB (zero-native does the same; keeps the ObjC string bridge bounded).
2. **Origin check:** the calling frame's origin must be in the command's `.origins` allowlist. Default allow `http://127.0.0.1` (loopback) and `mer://app`.
3. **Permission check:** `ctx.hasPermission` against the command's `.permissions` and the manifest's top-level `.permissions`.
4. **Dispatch:** command name → handler via a comptime-built registry (same shape as `Router.exact_map` in `dispatch.zig`).
5. **Deny-by-default:** unknown command name → `error.UnknownCommand`.

JS injection: the shell injects a small `window.mer.invoke` shim into the WKWebView via `WKUserScript` (added to the `WKUserContentController` on the `WKWebViewConfiguration` that `examples/desktop/main.zig` already allocates). The shim posts to a registered message handler; the Zig side receives it through `WKScriptMessageHandler` (new ObjC glue — the one piece the spike doesn't have yet).

---

## 6. Phased implementation (mapped to the issue's P0–P5)

| Phase | Issue | Actual work (given §0) | Status |
|---|---|---|---|
| **P0** | Spike (macOS) | **Verify** `examples/desktop/main.zig` still builds + runs against current `release/v0.2.6`. Document the `ServerReady` handshake as the contract. No new code. | done-in-spike; verify |
| **P1** | Manifest + CLI | `src/native/manifest.zig` (parse `mer.app.zon`); `mer add native` scaffold; `mer native` wiring in `cli.zig`; lift `examples/desktop/main.zig` → `src/native/{shell,macos}.zig` driven by manifest window config. | core of this release |
| **P2** | Bridge | `src/native/bridge.zig` + `commands.zig`; `WKScriptMessageHandler` glue in `macos.zig`; size/origin/permission guards; 3 reference commands. | core of this release |
| **P3** | Packaging | `mer package` → `.app` with manifest-driven `Info.plist` (replace hardcoded plist at `build.zig:354`); code-sign opt-out flag. | core of this release |
| **P4** | Linux WebView | `src/native/linux.zig` (WebKitGTK) behind `Shell` interface. | stretch for v0.2.6 |
| **P5** | Prod server embed | In-process loopback + asset embedding + `mer://app` scheme. `server.mode = "static"`. | stretch for v0.2.6 |
| P6/P7 | Windows / mobile | Out of scope for v0.2.6. | deferred |

**v0.2.6 ships P0 (verified) + P1 + P2 + P3 on macOS.** P4/P5 are stretch and gated on time.

---

## 7. Files touched / added

```
src/native/                  (new)
  shell.zig                  ← generalized from examples/desktop/main.zig
  macos.zig                  ← ObjC interop from examples/desktop/{main,spike}.zig
  bridge.zig                 ← command dispatch (mirrors src/dispatch.zig)
  manifest.zig               ← @import("mer.app.zon") parser/validator
  commands.zig               ← reference handlers (dialog, clipboard, window)
  mer.zig                    ← re-exports: mer.native.{Ctx, Json, Shell}
build/native.zig             (new) ← addNativeStep / addPackageStep
build.zig                    (edit) ← wire `native` + `package` steps, call build/native.zig
cli.zig                      (edit) ← `native`, `native build`, `package`, `add native` commands
examples/starter/mer.app.zon (new) ← template manifest embedded for `mer add native`
examples/desktop/            (keep) ← stays as the research record; not the product path
docs/native.md               (new) ← user-facing docs for `mer native`
```

The server (`src/server.zig`), router, dispatch, and watcher are **untouched** — the issue's central thesis (merjs already owns the server half) holds. The only server-adjacent change is confirming `Config.port = 0` + `Config.ready` works headless, which the desktop spike already exercises.

---

## 8. Risks

- **`WKScriptMessageHandler` ObjC glue** is the one genuinely new interop piece (the spike only does `loadRequest`, not JS→Zig callbacks). Mitigation: same extern-`objc_msgSend` pattern proven in `spike.zig`; register a delegate class with `objc_allocateClassPair` + `class_addMethod`. Low risk, but it's the thing to spike first in P2.
- **Zig 0.16 `std.Io` API drift** between the spike (#50/#53 era) and `release/v0.2.6` — `Server.listen` already uses `std.Io.net.IpAddress` / `addr.listen(io, ...)` so the spike's `mer.Server.init` calls should still match, but P0 verification catches any drift.
- **Bundle signing** — out of scope; `mer package` produces a locally-runnable `.app`, explicitly not App Store distributable (matches the existing `examples/desktop/README.md` "Status" caveats).

---

## 9. Verification checklist (per phase)

- [ ] P0: `zig build desktop` on `release/v0.2.6` opens a window loading the site from `127.0.0.1:<ephemeral>`.
- [ ] P1: `mer add native` in a fresh `mer init` project creates `mer.app.zon` + `native/`; `mer native` opens a window sized/titled from the manifest.
- [ ] P2: a page calling `window.mer.invoke("dialog.openFile")` returns a path; an unpermitted command returns `PermissionDenied`; an oversized payload is rejected; a non-loopback origin is rejected.
- [ ] P3: `mer package` emits `<Name>.app` whose `Info.plist` reflects `id`/`display_name`/`version` from `mer.app.zon`; `open <Name>.app` boots without a terminal.
