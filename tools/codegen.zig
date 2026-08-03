// tools/codegen.zig — scans app/ and api/, writes src/generated/routes.zig.
// Run via: zig build codegen

const std = @import("std");
const runtime = @import("runtime");
const mercss_jit = @import("mercss_jit");

const max_css_source_bytes = 4 * 1024 * 1024;

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Initialize std.Io runtime (Threaded on Zig 0.16-supported targets).
    try runtime.init(alloc);
    defer runtime.deinit();

    var args = try std.process.Args.Iterator.initAllocator(init.args, alloc);
    defer args.deinit();
    const executable = args.next() orelse "codegen";
    const app_arg = args.next();
    const api_arg = args.next();
    const output_arg = args.next();
    if ((app_arg == null) != (api_arg == null) or
        (app_arg == null) != (output_arg == null) or
        args.next() != null)
    {
        std.debug.print("usage: {s} [<app-dir> <api-dir> <output>]\n", .{executable});
        return error.InvalidArguments;
    }
    const app_dir = app_arg orelse "app";
    const api_dir = api_arg orelse "api";
    const output_path = output_arg orelse "src/generated/routes.zig";

    // Each entry stores its logical module path, independent of the scanned directory.
    // e.g. "app/about.zig", "api/hello.zig"
    var entries: std.ArrayList([]u8) = .empty;
    defer {
        for (entries.items) |e| alloc.free(e);
        entries.deinit(alloc);
    }

    scanDir(alloc, &entries, app_dir, "app") catch |err| {
        std.debug.print("codegen: cannot scan {s}: {s}\n", .{ app_dir, @errorName(err) });
        return err;
    };
    scanDir(alloc, &entries, api_dir, "api") catch |err| {
        if (!isOptionalApiDirError(err)) {
            std.debug.print("codegen: cannot scan {s}: {s}\n", .{ api_dir, @errorName(err) });
            return err;
        }
    };

    // Sort routes: static before dynamic, then alphabetically within each group.
    // This ensures /users/settings always matches before /users/:id.
    std.mem.sort([]u8, entries.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            const a_dynamic = hasDynamicSegment(a);
            const b_dynamic = hasDynamicSegment(b);
            if (a_dynamic != b_dynamic) return !a_dynamic; // static first
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    try validateUniqueRoutes(alloc, entries.items, true);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    // 0.16: ArrayList no longer has .writer() — use appendSlice/print directly.

    try buf.appendSlice(alloc,
        \\// GENERATED — do not edit by hand.
        \\// Re-run `zig build codegen` to regenerate.
        \\
        \\const Route = @import("mer").Route;
        \\
        \\
    );

    for (entries.items) |path| {
        const ident = try toIdent(alloc, path);
        defer alloc.free(ident);
        const import_name = try toImportName(alloc, path);
        defer alloc.free(import_name);
        try buf.print(alloc, "const {s} = @import(\"{s}\");\n", .{ ident, import_name });
    }

    try buf.appendSlice(alloc, "\npub const routes: []const Route = &.{\n");
    for (entries.items) |path| {
        const ident = try toIdent(alloc, path);
        defer alloc.free(ident);
        const url = try toUrl(alloc, path);
        defer alloc.free(url);
        try buf.print(alloc, "    .{{ .path = \"{s}\", .render = {s}.render, .render_stream = if (@hasDecl({s}, \"renderStream\")) {s}.renderStream else null, .meta = if (@hasDecl({s}, \"meta\")) {s}.meta else .{{}}, .prerender = if (@hasDecl({s}, \"prerender\")) {s}.prerender else false }},\n", .{ url, ident, ident, ident, ident, ident, ident, ident });
    }
    try buf.appendSlice(alloc, "};\n\n");

    // Enforce: every app/ page must export `pub const meta: mer.Meta`.
    try buf.appendSlice(alloc, "comptime {\n");
    for (entries.items) |path| {
        if (!std.mem.startsWith(u8, path, "app/")) continue;
        const ident = try toIdent(alloc, path);
        defer alloc.free(ident);
        try buf.print(alloc, "    if (!@hasDecl({s}, \"meta\")) @compileError(\"{s} must export pub const meta: mer.Meta\");\n", .{ ident, path });
    }
    try buf.appendSlice(alloc, "}\n\n");

    // --- Framework primitives (auto-detected) ---

    // Layout — if app/layout.zig exists, export its wrap function.
    // Also export streamWrap for streaming SSR if the layout provides it.
    const layout_path = try std.fs.path.join(alloc, &.{ app_dir, "layout.zig" });
    defer alloc.free(layout_path);
    if (fileExists(layout_path)) {
        try buf.appendSlice(alloc, "const app_layout = @import(\"app/layout\");\n");
        try buf.appendSlice(alloc, "pub const layout = app_layout.wrap;\n");
        try buf.appendSlice(alloc, "pub const streamLayout = if (@hasDecl(app_layout, \"streamWrap\")) app_layout.streamWrap else null;\n");
    }

    // Error handlers — if app/404.zig exists, export its render function.
    const not_found_path = try std.fs.path.join(alloc, &.{ app_dir, "404.zig" });
    defer alloc.free(not_found_path);
    if (fileExists(not_found_path)) {
        try buf.appendSlice(alloc, "const app_404 = @import(\"app/404\");\n");
        try buf.appendSlice(alloc, "pub const notFound = app_404.render;\n");
    }

    const output_dir = std.fs.path.dirname(output_path) orelse ".";
    var generated_dir = try std.Io.Dir.cwd().createDirPathOpen(runtime.io, output_dir, .{});
    defer generated_dir.close(runtime.io);
    const out = try std.Io.Dir.cwd().createFile(runtime.io, output_path, .{});
    defer out.close(runtime.io);
    try out.writePositionalAll(runtime.io, buf.items, 0);

    std.debug.print("codegen: wrote {d} route(s) to {s}\n", .{ entries.items.len, output_path });

    // ── mercss-jit: scan the selected app for class candidates ────────────────
    {
        var ds = mercss_jit.DesignSystem.init(alloc);
        defer ds.deinit();
        try ds.loadDefaults();

        // Source bytes outlive the candidate slices (which borrow into them).
        var sources: std.ArrayList([]u8) = .empty;
        defer {
            for (sources.items) |s| alloc.free(s);
            sources.deinit(alloc);
        }
        var candidates: std.ArrayList([]const u8) = .empty;
        defer candidates.deinit(alloc);

        try scanCssCandidates(alloc, app_dir, &sources, &candidates);
        sortAndDeduplicateCandidates(&candidates);

        const css = try mercss_jit.compile(alloc, &ds, candidates.items);
        defer alloc.free(css);

        const css_output_path = try std.fs.path.join(alloc, &.{ app_dir, "_mercss.css" });
        defer alloc.free(css_output_path);
        const css_out = try std.Io.Dir.cwd().createFile(runtime.io, css_output_path, .{});
        defer css_out.close(runtime.io);
        try css_out.writePositionalAll(runtime.io, css, 0);

        std.debug.print(
            "mercss: wrote {d} bytes ({d} candidates, {d} sources) to {s}\n",
            .{ css.len, candidates.items.len, sources.items.len, css_output_path },
        );
    }
}

fn isComponentPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "components/") or
        std.mem.startsWith(u8, path, "components\\") or
        std.mem.indexOf(u8, path, "/components/") != null or
        std.mem.indexOf(u8, path, "\\components\\") != null;
}

fn isOptionalApiDirError(err: anyerror) bool {
    return err == error.FileNotFound;
}

/// Scan source_dir/ for *.zig files, appending "logical_dir/file.zig" to entries.
fn scanDir(alloc: std.mem.Allocator, entries: *std.ArrayList([]u8), source_dir: []const u8, logical_dir: []const u8) !void {
    var d = try std.Io.Dir.cwd().openDir(runtime.io, source_dir, .{ .iterate = true });
    defer d.close(runtime.io);
    var walker = try d.walk(alloc);
    defer walker.deinit();
    while (try walker.next(runtime.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        // Skip layout.zig — it's a shared layout module, not a route.
        if (std.mem.eql(u8, entry.path, "layout.zig")) continue;
        // Skip 404.zig — it's an error handler, not a regular route.
        if (std.mem.eql(u8, entry.path, "404.zig")) continue;
        // app/components contains reusable modules, not file-based pages.
        if (std.mem.eql(u8, logical_dir, "app") and isComponentPath(entry.path)) continue;
        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ logical_dir, entry.path });
        errdefer alloc.free(full);
        try entries.append(alloc, full);
    }
}

/// "app/about.zig" → "app_about"
/// "api/hello.zig" → "api_hello"
fn toIdent(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const without_ext = if (std.mem.endsWith(u8, path, ".zig")) path[0 .. path.len - 4] else path;
    const buf = try alloc.dupe(u8, without_ext);
    for (buf) |*c| {
        if (c.* != '_' and (c.* < 'a' or c.* > 'z') and (c.* < 'A' or c.* > 'Z') and (c.* < '0' or c.* > '9')) {
            c.* = '_';
        }
    }
    return buf;
}

/// "app/about.zig" → "app/about"   (module import name)
/// "api/hello.zig" → "api/hello"
/// "app/about.zig" → "../../app/about.zig"  (file-path import from src/generated/)
/// "api/hello.zig" → "../../api/hello.zig"
/// "app/about.zig" → "app/about"   (module import name)
/// "api/hello.zig" → "api/hello"
fn toImportName(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return alloc.dupe(u8, if (std.mem.endsWith(u8, path, ".zig")) path[0 .. path.len - 4] else path);
}

/// URL mapping:
///   app/index.zig      → "/"
///   app/about.zig      → "/about"
///   app/blog/post.zig  → "/blog/post"
///   api/hello.zig        → "/api/hello"
///   api/v1/users.zig     → "/api/v1/users"
/// URL mapping:
///   app/index.zig          → "/"
///   app/about.zig          → "/about"
///   app/blog/post.zig      → "/blog/post"
///   app/users/[id].zig     → "/users/:id"   (dynamic segment)
///   api/hello.zig          → "/api/hello"
///   api/v1/users.zig       → "/api/v1/users"
fn toUrl(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const without_ext = if (std.mem.endsWith(u8, path, ".zig")) path[0 .. path.len - 4] else path;

    // Strip "app/" prefix, keep "api/" as part of the URL.
    const rel = if (std.mem.startsWith(u8, without_ext, "app/"))
        without_ext["app/".len..]
    else
        without_ext; // "api/hello" — stays as-is

    // "index" at app root → "/"
    if (std.mem.eql(u8, rel, "index")) return alloc.dupe(u8, "/");

    // Build URL: "/" + rel, replacing OS separators with '/' and [name] → :name.
    const result_buffer = try alloc.alloc(u8, rel.len + 1);
    errdefer alloc.free(result_buffer);
    result_buffer[0] = '/';
    var i: usize = 0;
    var out: usize = 1;
    while (i < rel.len) : (i += 1) {
        const c = rel[i];
        if (c == '[') {
            // Replace '[name]' with ':name'.
            result_buffer[out] = ':';
            out += 1;
            i += 1; // skip '['
            while (i < rel.len and rel[i] != ']') : (i += 1) {
                result_buffer[out] = rel[i];
                out += 1;
            }
            // i now points at ']' — loop increment skips it.
        } else {
            result_buffer[out] = if (c == std.fs.path.sep) '/' else c;
            out += 1;
        }
    }
    const result = result_buffer[0..out];

    // Strip trailing "/index" → parent path.
    const index_suffix = "/index";
    const final = if (std.mem.endsWith(u8, result, index_suffix)) blk: {
        const trimmed = result[0 .. result.len - index_suffix.len];
        break :blk if (trimmed.len == 0) "/" else trimmed;
    } else result;
    const owned = try alloc.dupe(u8, final);
    alloc.free(result_buffer);
    return owned;
}

fn routePatternsCollide(a: []const u8, b: []const u8) bool {
    var a_segments = std.mem.splitScalar(u8, a, '/');
    var b_segments = std.mem.splitScalar(u8, b, '/');
    var a_has_dynamic = false;
    var b_has_dynamic = false;
    while (true) {
        const a_segment = a_segments.next();
        const b_segment = b_segments.next();
        if (a_segment == null or b_segment == null) {
            if (a_segment != null or b_segment != null) return false;
            // A fully static route has deterministic exact-map precedence over
            // a dynamic route. Two dynamic patterns must not intersect.
            return a_has_dynamic == b_has_dynamic;
        }
        const a_dynamic = a_segment.?.len > 0 and a_segment.?[0] == ':';
        const b_dynamic = b_segment.?.len > 0 and b_segment.?[0] == ':';
        a_has_dynamic = a_has_dynamic or a_dynamic;
        b_has_dynamic = b_has_dynamic or b_dynamic;
        if (!a_dynamic and !b_dynamic and !std.mem.eql(u8, a_segment.?, b_segment.?)) return false;
    }
}

fn validateUniqueRoutes(alloc: std.mem.Allocator, entries: []const []const u8, report_collision: bool) !void {
    for (entries, 0..) |path, i| {
        const url = try toUrl(alloc, path);
        defer alloc.free(url);
        const ident = try toIdent(alloc, path);
        defer alloc.free(ident);
        for (entries[0..i]) |previous_path| {
            const previous_ident = try toIdent(alloc, previous_path);
            if (std.mem.eql(u8, ident, previous_ident)) {
                if (report_collision) std.debug.print("codegen: identifier collision: {s} and {s} both emit {s}\n", .{ path, previous_path, ident });
                alloc.free(previous_ident);
                return error.DuplicateIdentifier;
            }
            alloc.free(previous_ident);

            const previous_url = try toUrl(alloc, previous_path);
            if (routePatternsCollide(url, previous_url)) {
                if (report_collision) std.debug.print("codegen: route collision: {s} ({s}) conflicts with {s} ({s})\n", .{ path, url, previous_path, previous_url });
                alloc.free(previous_url);
                return error.DuplicateRoute;
            }
            alloc.free(previous_url);
        }
    }
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(runtime.io, path, .{}) catch return false;
    return true;
}

/// Returns true if the path contains a `[name]` dynamic segment.
fn hasDynamicSegment(path: []const u8) bool {
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '[') {
            while (i < path.len and path[i] != ']') : (i += 1) {}
            return true;
        }
    }
    return false;
}

fn cssSourcePath(alloc: std.mem.Allocator, dir_path: []const u8, entry_path: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ dir_path, entry_path });
}

fn cssSourceTooLarge(path: []const u8) !void {
    std.debug.print(
        "mercss: cannot scan {s}: source exceeds the 4 MiB limit; split it into smaller source files\n",
        .{path},
    );
    return error.SourceTooLarge;
}

fn sortAndDeduplicateCandidates(candidates: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, candidates.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var len: usize = 0;
    for (candidates.items) |candidate| {
        if (len == 0 or !std.mem.eql(u8, candidate, candidates.items[len - 1])) {
            candidates.items[len] = candidate;
            len += 1;
        }
    }
    candidates.shrinkRetainingCapacity(len);
}

/// Recursively walk `dir` looking for .zig and .html files. For each one,
/// load its bytes (stored in `sources` so they outlive borrowed slices) and
/// run mercss_jit.scan to append candidate strings to `candidates`.
fn scanCssCandidates(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    sources: *std.ArrayList([]u8),
    candidates: *std.ArrayList([]const u8),
) !void {
    var d = std.Io.Dir.cwd().openDir(runtime.io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("mercss: cannot scan {s}: {s}\n", .{ dir_path, @errorName(err) });
        return err;
    };
    defer d.close(runtime.io);
    var walker = try d.walk(alloc);
    defer walker.deinit();
    while (try walker.next(runtime.io)) |entry| {
        if (entry.kind != .file) continue;
        const is_zig = std.mem.endsWith(u8, entry.path, ".zig");
        const is_html = std.mem.endsWith(u8, entry.path, ".html");
        if (!is_zig and !is_html) continue;
        // Skip our own generated output.
        if (std.mem.eql(u8, entry.basename, "_mercss.css")) continue;

        const path = try cssSourcePath(alloc, dir_path, entry.path);
        defer alloc.free(path);
        const f = entry.dir.openFile(runtime.io, entry.basename, .{}) catch |err| {
            std.debug.print("mercss: cannot scan {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        defer f.close(runtime.io);
        var reader_buf: [4096]u8 = undefined;
        var fr = f.reader(runtime.io, &reader_buf);
        {
            const content = fr.interface.allocRemaining(alloc, .limited(max_css_source_bytes)) catch |err| switch (err) {
                error.StreamTooLong => return cssSourceTooLarge(path),
                else => {
                    std.debug.print("mercss: cannot scan {s}: {s}\n", .{ path, @errorName(err) });
                    return err;
                },
            };
            errdefer alloc.free(content);
            try sources.append(alloc, content);
        }
        try mercss_jit.scan(sources.items[sources.items.len - 1], alloc, candidates);
    }
}

test "scan CSS candidates: >4 MiB source reports its full path" {
    const path = try cssSourcePath(std.testing.allocator, "test-app", "nested/oversized.zig");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("test-app/nested/oversized.zig", path);
    try std.testing.expectError(error.SourceTooLarge, cssSourceTooLarge(path));
}

test "only a missing API directory is optional" {
    try std.testing.expect(isOptionalApiDirError(error.FileNotFound));
    try std.testing.expect(!isOptionalApiDirError(error.AccessDenied));
}

test "CSS candidates are sorted and deduplicated at the codegen boundary" {
    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(std.testing.allocator);
    try candidates.appendSlice(std.testing.allocator, &.{ "p-4", "flex", "p-4", "bg-red-500" });

    sortAndDeduplicateCandidates(&candidates);
    try std.testing.expectEqualStrings("bg-red-500", candidates.items[0]);
    try std.testing.expectEqualStrings("flex", candidates.items[1]);
    try std.testing.expectEqualStrings("p-4", candidates.items[2]);
    try std.testing.expectEqual(@as(usize, 3), candidates.items.len);
}

test "component directories are excluded from app routes" {
    try std.testing.expect(isComponentPath("components/button.zig"));
    try std.testing.expect(isComponentPath("admin/components/card.zig"));
    try std.testing.expect(isComponentPath("components\\button.zig"));
    try std.testing.expect(!isComponentPath("component-library.zig"));
}

test "route collision detection rejects index aliases and renamed parameters" {
    try std.testing.expect(routePatternsCollide("/foo", "/foo"));
    try std.testing.expect(routePatternsCollide("/users/:id", "/users/:slug"));
    try std.testing.expect(!routePatternsCollide("/users/settings", "/users/:id"));
    try std.testing.expect(routePatternsCollide("/users/:id/edit", "/users/new/:tab"));
    try std.testing.expect(!routePatternsCollide("/users/:id/edit", "/accounts/new/:tab"));
    try std.testing.expect(!routePatternsCollide("/users/:id/profile", "/users/:id"));

    try std.testing.expectError(error.DuplicateRoute, validateUniqueRoutes(std.testing.allocator, &.{
        "app/foo.zig",
        "app/foo/index.zig",
    }, false));
    try std.testing.expectError(error.DuplicateRoute, validateUniqueRoutes(std.testing.allocator, &.{
        "app/users/[id].zig",
        "app/users/[slug].zig",
    }, false));
    try std.testing.expectError(error.DuplicateIdentifier, validateUniqueRoutes(std.testing.allocator, &.{
        "app/foo-bar.zig",
        "app/foo_bar.zig",
    }, false));
    try std.testing.expectError(error.DuplicateRoute, validateUniqueRoutes(std.testing.allocator, &.{
        "app/users/[id]/edit.zig",
        "app/users/new/[tab].zig",
    }, false));
    try validateUniqueRoutes(std.testing.allocator, &.{
        "app/users/settings.zig",
        "app/users/[id].zig",
    }, false);
}
