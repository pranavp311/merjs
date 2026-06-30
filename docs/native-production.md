# `mer native` macOS production checklist

This checklist is for shipping a **macOS** `mer native` app. Linux, Windows, mobile, and a mature plugin/updater runtime remain tracked separately.

Linux/WebKitGTK and Windows/WebView2 production packaging/signing/runtime checks will be added with those native backends. See [`docs/native-platforms.md`](native-platforms.md) for the staged platform plan.

## 1. Harden the manifest

Production manifests should use explicit least privilege:

```zig
.permissions = .{ "window", "clipboard", "dialog", "open" },
.security = .{
    .navigation = .{ .allowed_origins = .{ "mer://app" } }, // shell injects exact http://127.0.0.1:<port>
    .bridge = .{
        .allowed_commands = .{
            "mer.ping",
            "dialog.openFile",
            "open.external",
            "window.close",
        },
        .command_origins = .{
            "mer.ping|http://127.0.0.1",
            "dialog.openFile|http://127.0.0.1",
            "open.external|http://127.0.0.1",
            "window.close|http://127.0.0.1",
        },
    },
    .open = .{
        .external_schemes = .{ "https", "mailto" },
        .path_roots = .{ "public", "~/Documents/MyApp" },
    },
},
```

`mer native` enforces these in two places:

- the WKWebView navigation delegate cancels navigation to non-allowed origins;
- the native shell injects a fresh per-process bridge token into the private JS shim;
- the `window.mer.invoke()` bridge checks the session token, origin, command allowlist, command origin bindings, permission class, and command-specific URL/path restrictions.

## 2. Configure signing and notarization

```zig
.macos = .{
    .signing_identity = "Developer ID Application: Example, Inc. (TEAMID)",
    .team_id = "TEAMID",
    .entitlements = "native/entitlements.plist", // optional
    .notarization_profile = "merjs-notary",
},
```

Create the notarytool keychain profile once:

```bash
xcrun notarytool store-credentials merjs-notary \
  --apple-id you@example.com \
  --team-id TEAMID \
  --password app-specific-password
```

## 3. Configure update metadata

The production gate requires update metadata so releases do not ship without an update trust root:

```zig
.update = .{
    .provider = "github-releases", // or "custom-http"
    .feed_url = "https://example.com/my-app/update.json",
    .public_key = "ed25519:base64-raw-32-byte-public-key",
},
```

`src/native/update.zig` now implements signed update checks and artifact verification helpers. It requires strict HTTPS feed/artifact URLs, a base64 raw 32-byte Ed25519 public key, Ed25519 signatures over canonical metadata, lowercase SHA-256 artifact hashes, positive artifact sizes, unique `(os, arch)` platform entries, signed monotonic `metadata_version`, and numeric `N[.N[.N]]` version metadata.

Current status: this is not an automatic installer yet. merjs can verify signed update metadata and artifact bytes, including stale-feed rejection when the caller persists and supplies the highest accepted `metadata_version` returned by `no_update` or `update_available` results (equal or lower feed metadata is rejected as stale), but it does **not** replace the running app or perform platform-specific install/rollback in this PR. Do not claim automatic updates until installer/rollback behavior and updater UX are implemented and audited.

Example feed contract:

```json
{
  "schema_version": 1,
  "metadata_version": 42,
  "app_id": "com.example.my-app",
  "version": "1.2.3",
  "min_supported_version": "1.0.0",
  "notes_url": "https://example.com/my-app/releases/1.2.3",
  "platforms": [{
    "os": "macos",
    "arch": "aarch64",
    "url": "https://example.com/my-app/MyApp-1.2.3-aarch64.zip",
    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "size": 12345678,
    "signature": "ed25519:base64-raw-64-byte-signature"
  }]
}
```

## 4. Run the production gate

```bash
mer native doctor
# or
zig build native-prod-check
```

This fails if the manifest is missing or misconfigures:

- native `.server.host` loopback IP-literal binding (`127.0.0.1` recommended; `localhost` is intentionally rejected)
- `.macos.signing_identity`
- `.macos.notarization_profile`
- explicit non-empty `.security.navigation.allowed_origins` without loopback/localhost (`localhost`, `127.*`, `[::1]`)
- non-empty `.security.bridge.allowed_commands`
- non-empty `.security.bridge.command_origins`
- non-empty `.security.open.external_schemes`
- non-empty `.security.open.path_roots`
- `.update.provider` (`github-releases` or `custom-http`)
- `.update.feed_url` (strict `https://` URL)
- `.update.public_key` (`ed25519:<base64 raw 32-byte public key>`)

## 5. Build, sign, notarize, staple

```bash
mer package --release
# or
zig build native-prod-release -Doptimize=ReleaseSmall
```

Equivalent manual flow:

```bash
zig build package -Doptimize=ReleaseSmall
zig build package-sign -Doptimize=ReleaseSmall
codesign --verify --deep --strict zig-out/<Display>.app

zig build package-notarize -Doptimize=ReleaseSmall
spctl --assess --type execute --verbose zig-out/<Display>.app
```

## 6. Manual smoke test

```bash
open zig-out/<Display>.app
```

Verify:

- app window opens;
- root route returns HTTP 200;
- `window.mer.invoke("mer.ping", {})` returns `{ "pong": true }`;
- an ad-hoc `window.webkit.messageHandlers.merInvoke.postMessage(JSON.stringify({cmd:"mer.ping",id:1,args:null}))` does not execute a handler or resolve/reject an existing `window.mer.invoke` promise;
- navigation to an unlisted origin is cancelled;
- unknown command returns `UnknownCommand`;
- missing permission returns `PermissionDenied`;
- unlisted command returns `CommandDenied`;
- bad origin returns `OriginNotAllowed`;
- `open.external` rejects `javascript:`;
- `open.path` rejects paths outside configured roots;
- closing the final window exits the app.
