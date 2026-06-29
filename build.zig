const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("build/helpers.zig");
const examples = @import("build/examples.zig");
const tools = @import("build/tools.zig");
const packages = @import("build/packages.zig");

fn plistEscapeAlloc(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    for (input) |c| {
        switch (c) {
            '&' => try out.appendSlice(alloc, "&amp;"),
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            '"' => try out.appendSlice(alloc, "&quot;"),
            '\'' => try out.appendSlice(alloc, "&apos;"),
            0...8, 11, 12, 14...31 => return error.InvalidPlistString,
            else => try out.append(alloc, c),
        }
    }

    return out.toOwnedSlice(alloc);
}

fn plistEscape(b: *std.Build, input: []const u8) []const u8 {
    return plistEscapeAlloc(b.allocator, input) catch @panic("invalid mer.app.zon string for Info.plist");
}

fn safeBundleComponentAlloc(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    for (input) |c| {
        try out.append(alloc, switch (c) {
            '/', '\\', ':', 0...31 => '-',
            else => c,
        });
    }

    const trimmed = std.mem.trim(u8, out.items, " .\t\r\n");
    if (trimmed.len == 0) {
        out.clearRetainingCapacity();
        try out.appendSlice(alloc, "MerNative");
        return out.toOwnedSlice(alloc);
    }

    if (trimmed.ptr != out.items.ptr or trimmed.len != out.items.len) {
        const owned = try alloc.dupe(u8, trimmed);
        out.deinit(alloc);
        return owned;
    }

    return out.toOwnedSlice(alloc);
}

fn safeBundleName(b: *std.Build, display_name: []const u8) []const u8 {
    const component = safeBundleComponentAlloc(b.allocator, display_name) catch @panic("invalid mer.app.zon display_name for bundle path");
    return b.fmt("{s}.app", .{component});
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

fn firstNonEmpty(a: ?[]const u8, b_: ?[]const u8) ?[]const u8 {
    return nonEmpty(a) orelse nonEmpty(b_);
}

fn zonMacosString(comptime zon: anytype, comptime field: []const u8) ?[]const u8 {
    const T = @TypeOf(zon);
    if (!@hasField(T, "macos")) return null;
    const MacT = @TypeOf(zon.macos);
    if (!@hasField(MacT, field)) return null;
    return @field(zon.macos, field);
}

fn zonUpdateString(comptime zon: anytype, comptime field: []const u8) ?[]const u8 {
    const T = @TypeOf(zon);
    if (!@hasField(T, "update")) return null;
    const UpdateT = @TypeOf(zon.update);
    if (!@hasField(UpdateT, field)) return null;
    return @field(zon.update, field);
}

fn zonServerHost(comptime zon: anytype) []const u8 {
    const T = @TypeOf(zon);
    if (!@hasField(T, "server")) return "127.0.0.1";
    const ServerT = @TypeOf(zon.server);
    if (!@hasField(ServerT, "host")) return "127.0.0.1";
    return zon.server.host;
}

fn parseIpv4ByteLiteral(comptime part: []const u8) ?u8 {
    if (part.len == 0 or part.len > 3) return null;
    for (part) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u8, part, 10) catch null;
}

fn isIpv4LoopbackLiteral(comptime host: []const u8) bool {
    var it = std.mem.splitScalar(u8, host, '.');
    var count: usize = 0;
    var first: u8 = 0;
    while (it.next()) |part| {
        const value = parseIpv4ByteLiteral(part) orelse return false;
        if (count == 0) first = value;
        count += 1;
        if (count > 4) return false;
    }
    return count == 4 and first == 127;
}

fn isLoopbackHostLiteral(comptime host: []const u8) bool {
    return isIpv4LoopbackLiteral(host) or
        std.ascii.eqlIgnoreCase(host, "::1") or
        std.ascii.eqlIgnoreCase(host, "[::1]");
}

fn isValidPortLiteral(comptime port: []const u8) bool {
    if (port.len == 0 or port.len > 5) return false;
    for (port) |c| if (!std.ascii.isDigit(c)) return false;
    const value = std.fmt.parseInt(u16, port, 10) catch return false;
    return value > 0;
}

fn isStrictHttpsUrlLiteral(comptime url: []const u8) bool {
    if (url.len == 0) return false;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f or c == '\\') return false;
    }
    const scheme_end = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    if (!std.ascii.eqlIgnoreCase(url[0..scheme_end], "https")) return false;
    if (url.len < scheme_end + 3 or !std.mem.eql(u8, url[scheme_end + 1 .. scheme_end + 3], "//")) return false;
    const authority_start = scheme_end + 3;
    const authority_end = blk: {
        var i: usize = authority_start;
        while (i < url.len) : (i += 1) {
            switch (url[i]) {
                '/', '?', '#' => break :blk i,
                else => {},
            }
        }
        break :blk url.len;
    };
    const authority = url[authority_start..authority_end];
    if (authority.len == 0) return false;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        if (close == 1) return false;
        const rest = authority[close + 1 ..];
        return rest.len == 0 or (rest[0] == ':' and isValidPortLiteral(rest[1..]));
    }
    const colon = std.mem.indexOfScalar(u8, authority, ':');
    const host = if (colon) |c| authority[0..c] else authority;
    if (host.len == 0) return false;
    if (std.mem.indexOfScalar(u8, host, '.') == null and !std.ascii.eqlIgnoreCase(host, "localhost")) return false;
    if (colon) |c| {
        if (!isValidPortLiteral(authority[c + 1 ..])) return false;
    }
    return true;
}

fn isEd25519TokenLiteral(comptime value: []const u8) bool {
    const prefix = "ed25519:";
    if (!std.mem.startsWith(u8, value, prefix) or value.len == prefix.len) return false;
    for (value[prefix.len..]) |c| {
        if (c <= 0x20 or c == 0x7f or c == '\\') return false;
    }
    return true;
}

fn zonUpdateProviderValid(comptime zon: anytype) bool {
    const provider = nonEmpty(zonUpdateString(zon, "provider")) orelse return false;
    return std.mem.eql(u8, provider, "github-releases") or std.mem.eql(u8, provider, "custom-http");
}

fn zonUpdateFeedUrlValid(comptime zon: anytype) bool {
    const feed_url = nonEmpty(zonUpdateString(zon, "feed_url")) orelse return false;
    return isStrictHttpsUrlLiteral(feed_url);
}

fn zonUpdatePublicKeyValid(comptime zon: anytype) bool {
    const public_key = nonEmpty(zonUpdateString(zon, "public_key")) orelse return false;
    return isEd25519TokenLiteral(public_key);
}

fn zonHasNavigationOrigins(comptime zon: anytype) bool {
    const T = @TypeOf(zon);
    if (!@hasField(T, "security")) return false;
    const SecurityT = @TypeOf(zon.security);
    if (!@hasField(SecurityT, "navigation")) return false;
    const NavigationT = @TypeOf(zon.security.navigation);
    if (!@hasField(NavigationT, "allowed_origins")) return false;
    return zon.security.navigation.allowed_origins.len > 0;
}

fn originHost(comptime origin: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return null;
    const authority_start = scheme_end + 3;
    const authority_end = blk: {
        var i: usize = authority_start;
        while (i < origin.len) : (i += 1) {
            switch (origin[i]) {
                '/', '?', '#' => break :blk i,
                else => {},
            }
        }
        break :blk origin.len;
    };
    var authority = origin[authority_start..authority_end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (authority.len == 0) return null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        return authority[0 .. close + 1];
    }
    const colon = std.mem.indexOfScalar(u8, authority, ':');
    return if (colon) |c| authority[0..c] else authority;
}

fn isForbiddenProductionLoopbackHost(comptime host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.eqlIgnoreCase(host, "[::1]") or
        std.mem.startsWith(u8, host, "127.");
}

fn zonNavigationHasForbiddenLoopback(comptime zon: anytype) bool {
    if (!zonHasNavigationOrigins(zon)) return false;
    for (zon.security.navigation.allowed_origins) |origin| {
        const host = originHost(origin) orelse continue;
        if (isForbiddenProductionLoopbackHost(host)) return true;
    }
    return false;
}

fn zonHasBridgeArray(comptime zon: anytype, comptime field: []const u8) bool {
    const T = @TypeOf(zon);
    if (!@hasField(T, "security")) return false;
    const SecurityT = @TypeOf(zon.security);
    if (!@hasField(SecurityT, "bridge")) return false;
    const BridgeT = @TypeOf(zon.security.bridge);
    if (!@hasField(BridgeT, field)) return false;
    return @field(zon.security.bridge, field).len > 0;
}

fn zonHasOpenArray(comptime zon: anytype, comptime field: []const u8) bool {
    const T = @TypeOf(zon);
    if (!@hasField(T, "security")) return false;
    const SecurityT = @TypeOf(zon.security);
    if (!@hasField(SecurityT, "open")) return false;
    const OpenT = @TypeOf(zon.security.open);
    if (!@hasField(OpenT, field)) return false;
    return @field(zon.security.open, field).len > 0;
}

fn macProdCheckMessage(comptime zon: anytype) []const u8 {
    comptime var msg: []const u8 = "";
    if (nonEmpty(zonMacosString(zon, "signing_identity")) == null) msg = msg ++ "missing .macos.signing_identity\\n";
    if (nonEmpty(zonMacosString(zon, "notarization_profile")) == null) msg = msg ++ "missing .macos.notarization_profile\\n";
    if (!isLoopbackHostLiteral(zonServerHost(zon))) msg = msg ++ "native production server.host must be loopback (use 127.0.0.1)\\n";
    if (!zonHasNavigationOrigins(zon)) msg = msg ++ "missing explicit non-empty .security.navigation.allowed_origins\\n";
    if (zonNavigationHasForbiddenLoopback(zon)) msg = msg ++ "production navigation origins must not include loopback/localhost; rely on the exact runtime origin injected by the shell\\n";
    if (!zonHasBridgeArray(zon, "allowed_commands")) msg = msg ++ "missing non-empty .security.bridge.allowed_commands\\n";
    if (!zonHasBridgeArray(zon, "command_origins")) msg = msg ++ "missing non-empty .security.bridge.command_origins\\n";
    if (!zonHasOpenArray(zon, "external_schemes")) msg = msg ++ "missing non-empty .security.open.external_schemes\\n";
    if (!zonHasOpenArray(zon, "path_roots")) msg = msg ++ "missing non-empty .security.open.path_roots\\n";
    if (nonEmpty(zonUpdateString(zon, "provider")) == null) msg = msg ++ "missing .update.provider\\n" else if (!zonUpdateProviderValid(zon)) msg = msg ++ "invalid .update.provider (expected github-releases or custom-http)\\n";
    if (nonEmpty(zonUpdateString(zon, "feed_url")) == null) msg = msg ++ "missing .update.feed_url\\n" else if (!zonUpdateFeedUrlValid(zon)) msg = msg ++ "invalid .update.feed_url (expected strict https URL)\\n";
    if (nonEmpty(zonUpdateString(zon, "public_key")) == null) msg = msg ++ "missing .update.public_key\\n" else if (!zonUpdatePublicKeyValid(zon)) msg = msg ++ "invalid .update.public_key (expected ed25519:<key>)\\n";
    return msg;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── dhi dependency ──────────────────────────────────────────────────────
    const dhi_dep = b.dependency("dhi", .{});
    const dhi_model_mod = dhi_dep.module("model");
    const dhi_validator_mod = dhi_dep.module("validator");

    // ── kuri dependency (browser automation for debug mode) ─────────────────
    // TODO: re-enable once kuri is updated for Zig 0.16
    // const kuri_dep = b.dependency("kuri", .{
    //     .target = target,
    //     .optimize = if (optimize != .Debug) optimize else .ReleaseFast,
    // });

    // ── Runtime module (std.Io instance management) ───────────────────────────
    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = b.path("src/runtime.zig"),
    });

    // ── "mer" module (framework public API) ──────────────────────────────────
    const mer_mod = b.addModule("mer", .{
        .root_source_file = b.path("src/mer.zig"),
        .link_libc = true,
    });
    mer_mod.addImport("dhi_model", dhi_model_mod);
    mer_mod.addImport("dhi_validator", dhi_validator_mod);
    mer_mod.addImport("runtime", runtime_mod);

    // ── turboapi-core (shared router + HTTP utilities) ──
    const core_dep = b.dependency("turboapi_core", .{});
    const core_mod = core_dep.module("turboapi-core");
    mer_mod.addImport("turboapi-core", core_mod);

    // Self-referential import: internal files (server.zig, router.zig, …)
    // file-imported from mer.zig still resolve their `@import("mer")` calls.
    mer_mod.addImport("mer", mer_mod);

    // ── Expose framework internals as named modules for consumer projects ────
    // Consumers do: `merjs_dep.module("server")` in their build.zig.
    // Each module has "mer" wired so transitive file-imports just work.
    const server_mod = b.addModule("server", .{ .root_source_file = b.path("src/server.zig") });
    server_mod.addImport("mer", mer_mod);
    const watcher_named = b.addModule("watcher", .{ .root_source_file = b.path("src/watcher.zig") });
    _ = watcher_named;
    const prerender_mod = b.addModule("prerender", .{ .root_source_file = b.path("src/prerender.zig") });
    prerender_mod.addImport("mer", mer_mod);

    // Worker-safe API surface — strips native-only pieces (server, session, env,
    // watcher) so the wasm32-freestanding target doesn't pull in libc deps.
    const mer_worker_mod = b.addModule("mer_worker", .{
        .root_source_file = b.path("src/mer-worker.zig"),
    });
    mer_worker_mod.addImport("mer_worker", mer_worker_mod);
    mer_worker_mod.addImport("dhi_model", dhi_model_mod);
    mer_worker_mod.addImport("dhi_validator", dhi_validator_mod);
    mer_worker_mod.addImport("turboapi-core", core_mod);

    // ── Demo site (examples/site) ───────────────────────────────────────────
    const counter_config_mod = b.addModule("counter_config", .{
        .root_source_file = b.path("examples/site/wasm/counter_config.zig"),
    });
    const site_extras: []const struct { []const u8, *std.Build.Module } = &.{.{ "counter_config", counter_config_mod }};

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize != .Debug) true else null,
        .link_libc = true, // 0.16: std.c.* (pthread, clock_gettime, etc.) needs explicit libc
    });
    main_mod.addImport("mer", mer_mod);
    main_mod.addImport("runtime", runtime_mod);
    main_mod.addImport("counter_config", counter_config_mod);
    helpers.addDirModules(b, main_mod, mer_mod, "examples/site/app", "app", site_extras);
    helpers.addDirModules(b, main_mod, mer_mod, "examples/site/api", "api", &.{});
    helpers.addRoutesModule(b, main_mod, mer_mod, "src/generated/routes.zig", "examples/site/app", "examples/site/api", site_extras);

    const exe = b.addExecutable(.{ .name = "merjs", .root_module = main_mod });
    b.installArtifact(exe);

    // Install kuri binary alongside merjs.
    // TODO: re-enable once kuri is updated for Zig 0.16
    // const install_kuri = b.addInstallArtifact(kuri_dep.artifact("kuri"), .{});
    // b.getInstallStep().dependOn(&install_kuri.step);

    // ── Codegen ──────────────────────────────────────────────────────────────
    const codegen_mod = b.createModule(.{
        .root_source_file = b.path("tools/codegen.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    // Wire up runtime for tools/codegen.zig
    codegen_mod.addImport("runtime", runtime_mod);

    // mercss JIT compiler — codegen scans app/ for class candidates,
    // compiles them, and writes app/_mercss.css before the exe builds.
    const mercss_jit_mod = b.createModule(.{
        .root_source_file = b.path("src/mercss-jit.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    codegen_mod.addImport("mercss_jit", mercss_jit_mod);
    const codegen_exe = b.addExecutable(.{ .name = "codegen", .root_module = codegen_mod });
    const run_codegen = b.addRunArtifact(codegen_exe);
    run_codegen.setCwd(b.path("."));
    b.step("codegen", "Regenerate src/generated/routes.zig").dependOn(&run_codegen.step);

    // ── Auto-run codegen before compiling (fresh clones just work) ───────────
    exe.step.dependOn(&run_codegen.step);

    // ── `zig build serve` ────────────────────────────────────────────────────
    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_exe.addArgs(args);
    b.step("serve", "Start the merjs dev server").dependOn(&run_exe.step);

    // ── Prerender (SSG) ─────────────────────────────────────────────────────
    const run_prerender = b.addRunArtifact(exe);
    run_prerender.addArg("--prerender");
    run_prerender.step.dependOn(b.getInstallStep());
    b.step("prerender", "Pre-render pages to dist/").dependOn(&run_prerender.step);

    // ── `zig build prod` ────────────────────────────────────────────────────
    const prod_step = b.step("prod", "Full production build: codegen + compile + prerender to dist/");
    prod_step.dependOn(&run_codegen.step);
    prod_step.dependOn(b.getInstallStep());
    prod_step.dependOn(&run_prerender.step);

    // ── WASM targets ────────────────────────────────────────────────────────
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const counter_wasm = helpers.addWasmExe(b, "counter", "examples/site/wasm/counter.zig", wasm_target);
    const install_counter = b.addInstallFile(counter_wasm.getEmittedBin(), "../examples/site/public/counter.wasm");
    const wasm_step = b.step("wasm", "Compile WASM modules → public/*.wasm");
    wasm_step.dependOn(&install_counter.step);

    const synth_wasm = helpers.addWasmExe(b, "synth", "examples/site/wasm/synth.zig", wasm_target);
    const install_synth = b.addInstallFile(synth_wasm.getEmittedBin(), "../examples/site/public/synth.wasm");
    wasm_step.dependOn(&install_synth.step);

    const grep_wasm = helpers.addWasmExe(b, "grep", "examples/site/wasm/grep.zig", wasm_target);
    const install_grep = b.addInstallFile(grep_wasm.getEmittedBin(), "../examples/site/worker/grep.wasm");
    b.step("grep", "Compile grep WASM").dependOn(&install_grep.step);

    // ── Worker WASM ─────────────────────────────────────────────────────────
    const worker_named = b.addModule("worker", .{
        .root_source_file = b.path("src/worker.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    worker_named.addImport("mer", mer_mod);
    const worker_mod = b.createModule(.{
        .root_source_file = b.path("src/worker.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    worker_mod.addImport("mer", mer_worker_mod);
    worker_mod.addImport("counter_config", counter_config_mod);
    helpers.addDirModules(b, worker_mod, mer_worker_mod, "examples/site/app", "app", site_extras);
    helpers.addDirModules(b, worker_mod, mer_worker_mod, "examples/site/api", "api", &.{});
    helpers.addRoutesModule(b, worker_mod, mer_worker_mod, "src/generated/routes.zig", "examples/site/app", "examples/site/api", site_extras);
    const worker_wasm = b.addExecutable(.{ .name = "merjs", .root_module = worker_mod });
    worker_wasm.rdynamic = true;
    worker_wasm.entry = .disabled;
    // Auto-run codegen before worker compilation too.
    worker_wasm.step.dependOn(&run_codegen.step);
    const install_worker = b.addInstallFile(worker_wasm.getEmittedBin(), "../examples/site/worker/merjs.wasm");
    const worker_step = b.step("worker", "Compile worker WASM for Cloudflare Workers");
    worker_step.dependOn(&install_worker.step);
    worker_step.dependOn(&install_grep.step);

    // ── Examples (sgdata, kanban) ────────────────────────────────────────────
    examples.addExamples(b, mer_mod, wasm_target);

    // ── Tools (CSS, setup) ──────────────────────────────────────────────────
    tools.addTools(b);

    // ── CLI ─────────────────────────────────────────────────────────────────
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cli.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize != .Debug) true else null,
        .link_libc = true,
    });
    cli_mod.addImport("runtime", runtime_mod);
    const cli_exe = b.addExecutable(.{ .name = "mer", .root_module = cli_mod });
    b.step("cli", "Build the `mer` CLI binary").dependOn(&b.addInstallArtifact(cli_exe, .{}).step);

    // ── Tests ───────────────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("mer", mer_mod);
    helpers.addDirModules(b, test_mod, mer_mod, "examples/site/app", "app", site_extras);
    helpers.addDirModules(b, test_mod, mer_mod, "examples/site/api", "api", &.{});
    helpers.addRoutesModule(b, test_mod, mer_mod, "src/generated/routes.zig", "examples/site/app", "examples/site/api", site_extras);
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));
    // Auto-run codegen before tests too.
    run_tests.step.dependOn(&run_codegen.step);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    // Run inline tests in individual framework source files.
    for ([_][]const u8{ "src/css.zig", "src/session.zig", "src/telemetry.zig", "src/native/bridge.zig", "src/native/manifest.zig", "src/native/platform_commands.zig", "src/native/update.zig" }) |src_path| {
        const file_test_mod = b.createModule(.{
            .root_source_file = b.path(src_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        if (std.mem.eql(u8, src_path, "src/native/bridge.zig") and target.result.os.tag == .macos) {
            file_test_mod.linkFramework("AppKit", .{});
            file_test_mod.linkFramework("Foundation", .{});
        }
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = file_test_mod })).step);
    }
    {
        const cli_test_mod = b.createModule(.{
            .root_source_file = b.path("cli.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        cli_test_mod.addImport("runtime", runtime_mod);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli_test_mod })).step);
    }
    // Run router + runtime inline tests (through mer.zig as root to avoid
    // file-ownership conflict: mer.zig file-imports router.zig/server.zig/etc.,
    // so those files belong to the mer module and can't also be test roots).
    {
        const mer_test_mod = b.createModule(.{
            .root_source_file = b.path("src/mer.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mer_test_mod.addImport("dhi_model", dhi_model_mod);
        mer_test_mod.addImport("dhi_validator", dhi_validator_mod);
        mer_test_mod.addImport("turboapi-core", core_mod);
        mer_test_mod.addImport("mer", mer_test_mod);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mer_test_mod })).step);
    }

    // ── Consumer integration test (issue #62, #69) ────────────────────────
    // Simulates a consumer project with its own routes — proves that
    // `mer.Router.fromGenerated` works and framework example routes don't leak in.
    // With the self-referential mer import, no manual wiring of ssr.zig/router.zig
    // transitive deps is needed — consumers just use `@import("mer")`.
    {
        const consumer_test_mod = b.createModule(.{
            .root_source_file = b.path("tests/consumer/src/test_consumer_routes.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        consumer_test_mod.addImport("mer", mer_mod);
        // The key: wire "routes" to the CONSUMER's routes, not the framework's.
        const consumer_routes_mod = b.createModule(.{
            .root_source_file = b.path("tests/consumer/src/routes.zig"),
        });
        consumer_routes_mod.addImport("mer", mer_mod);
        // Add consumer page modules to both routes and test modules.
        const consumer_pages = [_]struct { []const u8, []const u8 }{
            .{ "app/index", "tests/consumer/app/index.zig" },
            .{ "app/dashboard", "tests/consumer/app/dashboard.zig" },
        };
        for (consumer_pages) |page| {
            const page_mod = b.createModule(.{ .root_source_file = b.path(page[1]) });
            page_mod.addImport("mer", mer_mod);
            consumer_routes_mod.addImport(page[0], page_mod);
            consumer_test_mod.addImport(page[0], page_mod);
        }
        consumer_test_mod.addImport("routes", consumer_routes_mod);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = consumer_test_mod })).step);
    }

    // ── Starter scaffold smoke test ──────────────────────────────────────────
    // Compiles the embedded starter templates that `mer init` writes so
    // scaffold regressions fail in CI before they ship.
    {
        const starter_test_mod = b.createModule(.{
            .root_source_file = b.path("tests/starter/src/test_starter_scaffold.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        starter_test_mod.addImport("mer", mer_mod);

        const starter_layout_mod = b.createModule(.{
            .root_source_file = b.path("examples/starter/app/layout.zig"),
        });
        starter_layout_mod.addImport("mer", mer_mod);

        const starter_page_specs = [_]struct { []const u8, []const u8 }{
            .{ "app/index", "examples/starter/app/index.zig" },
            .{ "app/about", "examples/starter/app/about.zig" },
            .{ "app/404", "examples/starter/app/404.zig" },
        };
        const starter_routes_mod = b.createModule(.{
            .root_source_file = b.path("tests/starter/src/routes.zig"),
        });
        starter_routes_mod.addImport("mer", mer_mod);
        starter_routes_mod.addImport("app/layout", starter_layout_mod);

        for (starter_page_specs) |page| {
            const page_mod = b.createModule(.{ .root_source_file = b.path(page[1]) });
            page_mod.addImport("mer", mer_mod);
            page_mod.addImport("app/layout", starter_layout_mod);
            starter_routes_mod.addImport(page[0], page_mod);
            starter_test_mod.addImport(page[0], page_mod);
        }

        const starter_api_mod = b.createModule(.{
            .root_source_file = b.path("examples/starter/api/hello.zig"),
        });
        starter_api_mod.addImport("mer", mer_mod);
        starter_routes_mod.addImport("api/hello", starter_api_mod);
        starter_test_mod.addImport("api/hello", starter_api_mod);
        starter_test_mod.addImport("app/layout", starter_layout_mod);
        starter_test_mod.addImport("routes", starter_routes_mod);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = starter_test_mod })).step);
    }

    // ── Packages ────────────────────────────────────────────────────────────
    packages.addPackages(b, target, optimize, mer_mod);

    // ── `zig build desktop-spike` — macOS native app research (#50) ─────────
    if (target.result.os.tag == .macos) {
        const spike_mod = b.createModule(.{
            .root_source_file = b.path("examples/desktop/spike.zig"),
            .target = target,
            .optimize = optimize,
        });
        const spike_exe = b.addExecutable(.{ .name = "desktop-spike", .root_module = spike_mod });
        spike_mod.linkFramework("AppKit", .{});
        spike_mod.linkFramework("WebKit", .{});
        spike_mod.linkFramework("Foundation", .{});
        spike_mod.link_libc = true;
        const spike_step = b.step("desktop-spike", "Research spike: Zig ObjC bridge for AppKit/WebKit (#50)");
        spike_step.dependOn(&b.addInstallArtifact(spike_exe, .{}).step);
    }

    // ── `zig build desktop` — native macOS desktop app ──────────────────────
    if (target.result.os.tag == .macos) {
        const desktop_mod = b.createModule(.{
            .root_source_file = b.path("examples/desktop/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        desktop_mod.addImport("mer", mer_mod);
        helpers.addDirModules(b, desktop_mod, mer_mod, "examples/site/app", "app", site_extras);
        helpers.addDirModules(b, desktop_mod, mer_mod, "examples/site/api", "api", &.{});
        helpers.addRoutesModule(b, desktop_mod, mer_mod, "src/generated/routes.zig", "examples/site/app", "examples/site/api", site_extras);
        const desktop_exe = b.addExecutable(.{ .name = "merapp", .root_module = desktop_mod });
        desktop_mod.linkFramework("AppKit", .{});
        desktop_mod.linkFramework("WebKit", .{});
        desktop_mod.linkFramework("Foundation", .{});
        desktop_mod.link_libc = true;
        const desktop_install = b.addInstallArtifact(desktop_exe, .{});
        const desktop_step = b.step("desktop", "Build native macOS desktop app (also produces MerApp.app bundle)");
        desktop_step.dependOn(&desktop_install.step);

        // ── .app bundle — MerApp.app/Contents/MacOS/merapp + Info.plist ──────
        const plist = b.addWriteFile("MerApp.app/Contents/Info.plist",
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\  <key>CFBundleExecutable</key>    <string>merapp</string>
            \\  <key>CFBundleIdentifier</key>    <string>com.merjs.desktop</string>
            \\  <key>CFBundleName</key>          <string>MerApp</string>
            \\  <key>CFBundleVersion</key>       <string>0.2.5</string>
            \\  <key>NSHighResolutionCapable</key><true/>
            \\  <key>NSPrincipalClass</key>      <string>NSApplication</string>
            \\</dict>
            \\</plist>
        );
        const bundle_bin = b.addInstallFile(
            desktop_exe.getEmittedBin(),
            "MerApp.app/Contents/MacOS/merapp",
        );
        bundle_bin.step.dependOn(&desktop_install.step);
        const bundle_plist = b.addInstallDirectory(.{
            .source_dir = plist.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "",
        });
        desktop_step.dependOn(&bundle_bin.step);
        desktop_step.dependOn(&bundle_plist.step);
    }

    // ── `zig build native` — native shell (dev: builds + runs) ─────────────
    //     `zig build native-build` — install only (prod)
    //     `zig build package` — install + .app bundle with manifest Info.plist
    // Native runtime steps are macOS-only today. Linux WebKitGTK and Windows
    // WebView2 backends will split shared native executable setup from
    // platform-specific linking once those SDKs are implemented and validated.
    if (target.result.os.tag == .macos) {
        const native_mod = b.createModule(.{
            .root_source_file = b.path("src/native/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        native_mod.addImport("mer", mer_mod);
        native_mod.addImport("runtime", runtime_mod);
        const manifest_mod = b.createModule(.{
            .root_source_file = b.path("mer.app.zon"),
        });
        native_mod.addImport("manifest", manifest_mod);
        helpers.addDirModules(b, native_mod, mer_mod, "examples/site/app", "app", site_extras);
        helpers.addDirModules(b, native_mod, mer_mod, "examples/site/api", "api", &.{});
        helpers.addRoutesModule(b, native_mod, mer_mod, "src/generated/routes.zig", "examples/site/app", "examples/site/api", site_extras);
        native_mod.linkFramework("AppKit", .{});
        native_mod.linkFramework("WebKit", .{});
        native_mod.linkFramework("Foundation", .{});
        native_mod.link_libc = true;

        const native_exe = b.addExecutable(.{ .name = "mernative", .root_module = native_mod });
        native_exe.step.dependOn(&run_codegen.step);
        const native_install = b.addInstallArtifact(native_exe, .{});

        // `native` — run step (dev). `zig build native -- --dev`
        const run_native = b.addRunArtifact(native_exe);
        run_native.step.dependOn(&native_install.step);
        if (b.args) |args| run_native.addArgs(args);
        const native_step = b.step("native", "Run the native shell (dev: hot reload + WebView)");
        native_step.dependOn(&run_native.step);

        // `native-build` — install only (prod).
        const native_build_step = b.step("native-build", "Build the native shell binary (prod, no run)");
        native_build_step.dependOn(&native_install.step);

        // `package` — install + .app bundle with manifest-driven Info.plist.
        // Read identity/version from mer.app.zon at build time.
        const app_zon = @import("mer.app.zon");
        const pkg_name = safeBundleName(b, app_zon.display_name);
        const bundle_id_xml = plistEscape(b, app_zon.id);
        const display_name_xml = plistEscape(b, app_zon.display_name);
        const version_xml = plistEscape(b, app_zon.version);
        const plist_xml = b.fmt(
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\  <key>CFBundleExecutable</key>    <string>mernative</string>
            \\  <key>CFBundleIdentifier</key>    <string>{s}</string>
            \\  <key>CFBundleName</key>          <string>{s}</string>
            \\  <key>CFBundleVersion</key>       <string>{s}</string>
            \\  <key>NSHighResolutionCapable</key><true/>
            \\  <key>NSPrincipalClass</key>      <string>NSApplication</string>
            \\</dict>
            \\</plist>
        , .{ bundle_id_xml, display_name_xml, version_xml });
        const plist = b.addWriteFile(b.fmt("{s}/Contents/Info.plist", .{pkg_name}), plist_xml);
        const pkg_bin = b.addInstallFile(
            native_exe.getEmittedBin(),
            b.fmt("{s}/Contents/MacOS/mernative", .{pkg_name}),
        );
        pkg_bin.step.dependOn(&native_install.step);
        const pkg_plist = b.addInstallDirectory(.{
            .source_dir = plist.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "",
        });
        const package_step = b.step("package", "Package the native app as a .app bundle (macOS)");
        package_step.dependOn(&pkg_bin.step);
        package_step.dependOn(&pkg_plist.step);

        const prod_check_message = comptime macProdCheckMessage(app_zon);
        const native_prod_check_step = b.step("native-prod-check", "Validate macOS native production-release manifest hardening");
        if (prod_check_message.len == 0) {
            const ok = b.addSystemCommand(&.{ "sh", "-c", "echo 'mer native: macOS production manifest checks passed'" });
            native_prod_check_step.dependOn(&ok.step);
        } else {
            const fail = b.addSystemCommand(&.{
                "sh",
                "-c",
                b.fmt("printf 'mer native: macOS production manifest is incomplete:\n{s}' >&2; exit 1", .{prod_check_message}),
            });
            native_prod_check_step.dependOn(&fail.step);
        }

        // `package-sign` — optional Developer ID signing. Unsigned local
        // packages remain the default; this step is explicit like Tauri's
        // macOS bundle signing path.
        const app_path = b.getInstallPath(.prefix, pkg_name);
        const signing_identity = firstNonEmpty(
            b.option([]const u8, "macos-signing-identity", "macOS codesign identity for package-sign"),
            zonMacosString(app_zon, "signing_identity"),
        );
        const entitlements = firstNonEmpty(
            b.option([]const u8, "macos-entitlements", "macOS entitlements plist for package-sign"),
            zonMacosString(app_zon, "entitlements"),
        );
        const package_sign_step = b.step("package-sign", "Package and codesign the native .app bundle (macOS)");
        if (signing_identity) |identity| {
            const codesign = b.addSystemCommand(&.{
                "codesign",
                "--deep",
                "--force",
                "--options",
                "runtime",
                "--timestamp",
                "--sign",
                identity,
            });
            if (entitlements) |path| codesign.addArgs(&.{ "--entitlements", path });
            codesign.addArg(app_path);
            codesign.step.dependOn(native_prod_check_step);
            codesign.step.dependOn(package_step);
            package_sign_step.dependOn(&codesign.step);
        } else {
            const fail = b.addSystemCommand(&.{
                "sh",
                "-c",
                "echo 'mer native: package-sign needs -Dmacos-signing-identity or .macos.signing_identity in mer.app.zon' >&2; exit 1",
            });
            fail.step.dependOn(native_prod_check_step);
            fail.step.dependOn(package_step);
            package_sign_step.dependOn(&fail.step);
        }

        // `package-notarize` — sign, zip, submit, and staple. Credentials stay
        // in the developer's keychain profile; merjs never stores passwords.
        // The production manifest gate is a hard precondition for every
        // notarization side-effect command.
        const notarization_profile = firstNonEmpty(
            b.option([]const u8, "macos-notarization-profile", "xcrun notarytool keychain profile for package-notarize"),
            zonMacosString(app_zon, "notarization_profile"),
        );
        const package_notarize_step = b.step("package-notarize", "Codesign, notarize, and staple the native .app bundle (macOS)");
        if (notarization_profile) |profile| {
            const zip_path = b.fmt("zig-out/{s}.zip", .{pkg_name});
            const zip = b.addSystemCommand(&.{ "ditto", "-c", "-k", "--keepParent", app_path, zip_path });
            zip.step.dependOn(native_prod_check_step);
            zip.step.dependOn(package_sign_step);
            const submit = b.addSystemCommand(&.{ "xcrun", "notarytool", "submit", zip_path, "--keychain-profile", profile, "--wait" });
            submit.step.dependOn(&zip.step);
            const staple = b.addSystemCommand(&.{ "xcrun", "stapler", "staple", app_path });
            staple.step.dependOn(&submit.step);
            package_notarize_step.dependOn(&staple.step);
        } else {
            const fail = b.addSystemCommand(&.{
                "sh",
                "-c",
                "echo 'mer native: package-notarize needs -Dmacos-notarization-profile or .macos.notarization_profile in mer.app.zon' >&2; exit 1",
            });
            fail.step.dependOn(native_prod_check_step);
            package_notarize_step.dependOn(&fail.step);
        }

        const native_prod_release_step = b.step("native-prod-release", "Validate, sign, notarize, and staple the macOS native app");
        native_prod_release_step.dependOn(package_notarize_step);
    }
}
