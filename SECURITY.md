# Security Policy

## Supported versions

merjs is pre-1.0 and experimental. Only the latest commit on `main` receives security fixes.

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Email **rach@merlionjs.com** with:

- A description of the vulnerability and its impact
- Steps to reproduce (minimal PoC if possible)
- Affected component (`src/server.zig`, `src/native/bridge.zig`, `worker/worker.js`, etc.)
- Your suggested fix if you have one

You will receive an acknowledgement within 48 hours and a resolution timeline within 7 days.

## Scope

In scope:

- HTTP server request handling (`src/server.zig`)
- Session signing/verification (`src/mer.zig` `signSession`/`verifySession`)
- Cloudflare Workers WASM handler (`worker/worker.js`)
- `merjs-auth` package (`packages/merjs-auth/`)
- Native shell bridge, manifest, and packaging code (`src/native/`, `mer.app.zon`, native `build.zig` steps)

Out of scope:

- Vulnerabilities in Zig toolchain itself (report to https://github.com/ziglang/zig)
- Issues in third-party dependencies (dhi, Tailwind, system WebView runtimes)
- Demo/example apps that are not the framework runtime

## Native security model (`mer native`)

`mer native` is a small native shell around the system WebView. It does **not** bundle Node, npm, Electron, or Chromium. The app UI is served by the embedded merjs loopback server and the native bridge is exposed as `window.mer.invoke()`.

### Implemented hardening

- **Loopback binding:** the shell binds the embedded server to `127.0.0.1` by default and uses an ephemeral port (`port = 0`).
- **Runtime origin pinning:** after the server binds, `shell.zig` prepends the exact `http://host:port` origin to the allowed origin list.
- **Bridge origin validation:** the macOS backend reads the `WKScriptMessage` frame origin and rejects calls before dispatch when the origin is not allowed.
- **Payload limits:** bridge payloads over 64 KB are rejected.
- **Embedded-NUL guard:** NSString payload byte length is compared against `UTF8String` length so NUL truncation cannot hide data from dispatch.
- **Deny-by-default command registry:** unknown command names return `UnknownCommand`.
- **Permission classes:** built-in commands require manifest permissions such as `clipboard`, `dialog`, `open`, and `window`.
- **Explicit command allowlist:** `security.bridge.allowed_commands` can restrict the manifest to exact command names, similar to Tauri capabilities.
- **Per-command origins:** `security.bridge.command_origins` can bind commands to origins with `"command|origin"` entries.
- **Safer open commands:** `open.external` rejects disallowed schemes (default: `http`, `https`, `mailto`); `open.path` can be restricted to configured roots.
- **macOS signing hooks:** `zig build package-sign` / `mer package --sign` run hardened-runtime `codesign`; `package-notarize` / `mer package --notarize` run `notarytool` and `stapler`.

### Not yet done / do not claim production-complete

- **Auto-updater:** manifest fields may describe an update feed/public key, but no updater downloads or installs artifacts yet.
- **Signed update manifests/artifacts:** planned; not implemented.
- **Rollback prevention:** planned with the updater; not implemented.
- **Full Linux support:** WebKitGTK backend and package integration are not implemented.
- **Full Windows support:** WebView2 backend and package integration are not implemented.
- **Mature plugin system:** app-provided/plugin command registries and plugin capability manifests are not implemented.
- **Navigation policy delegate:** bridge calls are origin-checked, but full WebView navigation interception is still a hardening item.
- **Universal user prompts:** OS dialogs prompt where applicable, but merjs does not yet prompt for every sensitive bridge command.
- **Independent production audit:** a full third-party audit / pen-test has not been completed.

## Native release checklist

Before presenting a native app as production-ready, run or document:

```bash
zig build test
zig build cli
zig build native-build -Doptimize=ReleaseSmall
zig build package -Doptimize=ReleaseSmall
```

For signed macOS distribution:

```bash
zig build package-sign -Doptimize=ReleaseSmall \
  -Dmacos-signing-identity="Developer ID Application: Example, Inc. (TEAMID)"
codesign --verify --deep --strict zig-out/<Display>.app

zig build package-notarize -Doptimize=ReleaseSmall -Dmacos-notarization-profile=<keychain-profile>
spctl --assess --type execute --verbose zig-out/<Display>.app
```

Security smoke tests to keep in CI/manual review:

- unknown command returns `UnknownCommand`
- missing permission returns `PermissionDenied`
- unlisted command returns `CommandDenied` when `allowed_commands` is configured
- wrong command origin returns `OriginNotAllowed`
- oversized payload returns `PayloadTooLarge`
- malformed JSON returns `ParseError`
- `open.external` rejects `javascript:` / unexpected schemes
- `open.path` rejects paths outside configured roots
