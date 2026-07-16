// static.zig — serve files from public/ with in-memory cache (Zig 0.16).

const std = @import("std");
const builtin = @import("builtin");
const mer = @import("mer");

const server = @import("server.zig");

// --- Zig 0.16 shim: Thread.Mutex was removed ---
const PthreadMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    pub fn lock(m: *PthreadMutex) void {
        _ = std.c.pthread_mutex_lock(&m.inner);
    }
    pub fn unlock(m: *PthreadMutex) void {
        _ = std.c.pthread_mutex_unlock(&m.inner);
    }
};

const mime_table = [_]struct { ext: []const u8, ct: mer.ContentType }{
    .{ .ext = ".html", .ct = .html },
    .{ .ext = ".htm", .ct = .html },
    .{ .ext = ".css", .ct = .css },
    .{ .ext = ".js", .ct = .js },
    .{ .ext = ".wasm", .ct = .wasm },
    .{ .ext = ".json", .ct = .json },
    .{ .ext = ".txt", .ct = .text },
    .{ .ext = ".png", .ct = .png },
    .{ .ext = ".jpg", .ct = .jpeg },
    .{ .ext = ".jpeg", .ct = .jpeg },
    .{ .ext = ".gif", .ct = .gif },
    .{ .ext = ".svg", .ct = .svg },
    .{ .ext = ".ico", .ct = .ico },
    .{ .ext = ".webp", .ct = .webp },
};

fn mimeForPath(path: []const u8) mer.ContentType {
    for (mime_table) |entry| {
        if (std.mem.endsWith(u8, path, entry.ext)) return entry.ct;
    }
    return .octet_stream;
}

/// Cached static file entry.
const CacheEntry = struct {
    body: []const u8,
    ct: mer.ContentType,
};

/// Global static file cache — populated on first access, never evicted.
/// Safe for concurrent reads after initial population (no mutation after insert).
var cache: std.StringHashMapUnmanaged(CacheEntry) = .{};
var cache_alloc: std.mem.Allocator = undefined;
var cache_mu: PthreadMutex = .{};
var cache_init_done: bool = false;

pub fn initCache(alloc: std.mem.Allocator) void {
    cache_alloc = alloc;
    cache_init_done = true;
}

fn getCached(key: []const u8) ?CacheEntry {
    if (!cache_init_done) return null;
    cache_mu.lock();
    defer cache_mu.unlock();
    return cache.get(key);
}

fn putCache(key_src: []const u8, body: []const u8, ct: mer.ContentType) void {
    if (!cache_init_done) return;
    cache_mu.lock();
    defer cache_mu.unlock();
    const key = cache_alloc.dupe(u8, key_src) catch return;
    const owned_body = cache_alloc.dupe(u8, body) catch {
        cache_alloc.free(key);
        return;
    };
    cache.put(cache_alloc, key, .{ .body = owned_body, .ct = ct }) catch {
        cache_alloc.free(key);
        cache_alloc.free(owned_body);
    };
}

/// Attempt to serve `url_path` from the public/ directory.
/// Returns `{}` if served, `null` if the file was not found.
/// Options for static serving.
pub const ServeOpts = struct {
    /// Directory to serve from (default "public"). Set to "dist" for a built SPA.
    dir: []const u8 = "public",
    /// When true, "/" serves index.html and unknown paths fall back to it
    /// (SPA history-fallback mode). Use for Vite/React builds with client routing.
    spa: bool = false,
};

fn isSafeRelativePath(rel: []const u8) bool {
    if (rel.len == 0 or std.mem.indexOfScalar(u8, rel, 0) != null or std.mem.indexOfScalar(u8, rel, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn pathWithinProject(path: []const u8, project: []const u8) bool {
    const equal = if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(path, project)
    else
        std.mem.eql(u8, path, project);
    if (equal) return true;
    const starts = if (builtin.os.tag == .windows)
        std.ascii.startsWithIgnoreCase(path, project)
    else
        std.mem.startsWith(u8, path, project);
    if (!starts or project.len == 0 or path.len <= project.len) return false;
    return if (builtin.os.tag == .windows)
        project[project.len - 1] == '/' or project[project.len - 1] == '\\' or path[project.len] == '/' or path[project.len] == '\\'
    else
        project[project.len - 1] == '/' or path[project.len] == '/';
}

fn openedDirIsInsideProject(dir: std.Io.Dir, io: std.Io) bool {
    var project_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const project_len = std.Io.Dir.cwd().realPath(io, &project_buf) catch return false;
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = dir.realPath(io, &dir_buf) catch return false;
    return pathWithinProject(dir_buf[0..dir_len], project_buf[0..project_len]);
}

/// Read a static file by walking one component at a time below an already-open
/// root directory. No component may be a symlink, so path validation and file
/// opening are tied to directory handles rather than a race-prone path check.
pub fn readContainedFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    rel: []const u8,
) ?[]u8 {
    if (!isSafeRelativePath(rel)) return null;

    var current = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return null;
    defer current.close(io);
    // A top-level symlink is allowed only when it resolves within the project
    // (the merjs repo intentionally maps public -> examples/site/public).
    if (!openedDirIsInsideProject(current, io)) return null;

    var parts = std.mem.splitScalar(u8, rel, '/');
    var component = parts.next() orelse return null;
    while (parts.next()) |next| {
        const child = current.openDir(io, component, .{ .follow_symlinks = false }) catch return null;
        current.close(io);
        current = child;
        component = next;
    }

    const file = current.openFile(io, component, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch return null;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    return reader.interface.allocRemaining(alloc, .limited(10 * 1024 * 1024)) catch null;
}

pub fn tryServe(
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    url_path: []const u8,
    io: std.Io,
    opts: ServeOpts,
) ?void {
    const rel = if (url_path.len > 0 and url_path[0] == '/') url_path[1..] else url_path;

    // "/" or empty → index.html.
    if (rel.len == 0) {
        if (opts.spa) return serveIndex(alloc, std_req, opts.dir, io);
        return null;
    }
    if (!isSafeRelativePath(rel)) return null;

    const cache_key = std.fmt.allocPrint(alloc, "{s}/{s}", .{ opts.dir, rel }) catch return null;
    defer alloc.free(cache_key);
    if (getCached(cache_key)) |entry| {
        return sendStatic(std_req, entry.body, entry.ct);
    }

    const body = readContainedFile(alloc, io, opts.dir, rel) orelse {
        if (opts.spa) return serveIndex(alloc, std_req, opts.dir, io);
        return null;
    };
    defer alloc.free(body);

    const ct = mimeForPath(rel);

    // Cache for future requests.
    putCache(cache_key, body, ct);

    return sendStatic(std_req, body, ct);
}

/// Serve <dir>/index.html (SPA shell). Cached under the key "<dir>/index.html".
fn serveIndex(
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    dir: []const u8,
    io: std.Io,
) ?void {
    const cache_key = std.fmt.allocPrint(alloc, "{s}/index.html", .{dir}) catch return null;
    defer alloc.free(cache_key);
    if (getCached(cache_key)) |entry| {
        return sendStatic(std_req, entry.body, entry.ct);
    }
    const body = readContainedFile(alloc, io, dir, "index.html") orelse return null;
    defer alloc.free(body);
    putCache(cache_key, body, .html);
    return sendStatic(std_req, body, .html);
}

fn sendStatic(std_req: *std.http.Server.Request, body: []const u8, ct: mer.ContentType) ?void {
    const ct_header = [_]std.http.Header{
        .{ .name = "content-type", .value = ct.mime() },
        .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" },
    };
    var header_buf: [2048]u8 = undefined;
    var bw = std_req.respondStreaming(&header_buf, .{
        .content_length = body.len,
        .respond_options = .{
            .status = .ok,
            .extra_headers = &(ct_header ++ server.security_headers),
        },
    }) catch return null;
    if (std_req.head.method != .HEAD) bw.writer.writeAll(body) catch return null;
    bw.end() catch return null;
    return {};
}

test "static relative paths reject traversal and ambiguous separators" {
    try std.testing.expect(pathWithinProject("/app/public/index.html", "/app"));
    try std.testing.expect(!pathWithinProject("/application/secret", "/app"));
    if (builtin.os.tag != .windows) try std.testing.expect(!pathWithinProject("/app\\private/secret", "/app\\"));
    try std.testing.expect(isSafeRelativePath("index.html"));
    try std.testing.expect(isSafeRelativePath("assets/app.js"));
    try std.testing.expect(!isSafeRelativePath("../secret"));
    try std.testing.expect(!isSafeRelativePath("assets/../secret"));
    try std.testing.expect(!isSafeRelativePath("assets//app.js"));
    try std.testing.expect(!isSafeRelativePath("assets\\app.js"));
}

test "static file reads reject contained and escaping symlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "root", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "root/inside.txt", .data = "inside" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside.txt", .data = "outside" });
    try tmp.dir.createDir(std.testing.io, "outside-dir", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside-dir/nested.txt", .data = "nested outside" });
    try tmp.dir.symLink(std.testing.io, "inside.txt", "root/inside-link", .{});
    try tmp.dir.symLink(std.testing.io, "../outside.txt", "root/outside-link", .{});
    try tmp.dir.symLink(std.testing.io, "../outside-dir", "root/outside-dir-link", .{ .is_directory = true });
    try tmp.dir.symLink(std.testing.io, "/etc", "outside-project-root", .{ .is_directory = true });

    const root_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/root", .{tmp.sub_path});
    defer alloc.free(root_path);

    const inside = readContainedFile(alloc, std.testing.io, root_path, "inside.txt") orelse return error.TestUnexpectedResult;
    defer alloc.free(inside);
    try std.testing.expectEqualStrings("inside", inside);
    try std.testing.expect(readContainedFile(alloc, std.testing.io, root_path, "inside-link") == null);
    try std.testing.expect(readContainedFile(alloc, std.testing.io, root_path, "outside-link") == null);
    try std.testing.expect(readContainedFile(alloc, std.testing.io, root_path, "outside-dir-link/nested.txt") == null);

    const outside_root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/outside-project-root", .{tmp.sub_path});
    defer alloc.free(outside_root);
    try std.testing.expect(readContainedFile(alloc, std.testing.io, outside_root, "passwd") == null);
}
