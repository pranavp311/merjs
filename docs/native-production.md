# `mer native` macOS production checklist

This checklist is for shipping a **macOS** `mer native` app. Linux, Windows, mobile, and a mature plugin/updater runtime remain tracked separately.

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
- the `window.mer.invoke()` bridge checks origin, command allowlist, command origin bindings, permission class, and command-specific URL/path restrictions.

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
    .provider = "github-releases",
    .feed_url = "https://example.com/my-app/update.json",
    .public_key = "ed25519:base64-public-key",
},
```

Current status: merjs stores and validates that this metadata exists for production releases, but a full signed auto-updater installer is still deferred. Do not claim automatic updates until the signed updater runtime is implemented and audited.

## 4. Run the production gate

```bash
mer native doctor
# or
zig build native-prod-check
```

This fails if the manifest is missing:

- `.macos.signing_identity`
- `.macos.notarization_profile`
- explicit non-empty `.security.navigation.allowed_origins` without loopback/localhost (`localhost`, `127.*`, `[::1]`)
- non-empty `.security.bridge.allowed_commands`
- non-empty `.security.bridge.command_origins`
- non-empty `.security.open.external_schemes`
- non-empty `.security.open.path_roots`
- `.update.provider`
- `.update.feed_url`
- `.update.public_key`

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
- navigation to an unlisted origin is cancelled;
- unknown command returns `UnknownCommand`;
- missing permission returns `PermissionDenied`;
- unlisted command returns `CommandDenied`;
- bad origin returns `OriginNotAllowed`;
- `open.external` rejects `javascript:`;
- `open.path` rejects paths outside configured roots;
- closing the final window exits the app.
