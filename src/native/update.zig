// update.zig — structural validation for native update feed metadata.
//
// This module intentionally does not download, install, or cryptographically
// verify updates yet. It defines a strict feed/artifact contract and fail-closed
// validators so the future updater runtime has a narrow, test-covered input
// surface.

const std = @import("std");
const manifest_mod = @import("manifest.zig");

pub const max_manifest_bytes: usize = 256 * 1024;

pub const Error = error{
    ManifestTooLarge,
    InvalidSchemaVersion,
    MissingAppId,
    MissingVersion,
    MissingPlatform,
    MissingPlatformField,
    InvalidUrl,
    InvalidHash,
    InvalidSignature,
    InvalidSize,
    DuplicatePlatform,
    InvalidVersion,
    RollbackWindowInvalid,
    PartialUpdateConfig,
    InvalidProvider,
    InvalidPublicKey,
    InvalidJson,
};

pub const Feed = struct {
    schema_version: u32,
    app_id: []const u8,
    version: []const u8,
    min_supported_version: ?[]const u8 = null,
    published_at: ?[]const u8 = null,
    notes_url: ?[]const u8 = null,
    platforms: []const Platform,
};

pub const Platform = struct {
    os: []const u8,
    arch: []const u8,
    url: []const u8,
    sha256: []const u8,
    size: u64,
    signature: []const u8,
};

pub fn validateFeedJson(alloc: std.mem.Allocator, json: []const u8) !void {
    if (json.len > max_manifest_bytes) return error.ManifestTooLarge;
    var parsed = std.json.parseFromSlice(Feed, alloc, json, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    try validateFeed(parsed.value);
}

pub fn validateFeed(feed: Feed) Error!void {
    if (feed.schema_version != 1) return error.InvalidSchemaVersion;
    if (!nonEmpty(feed.app_id)) return error.MissingAppId;
    if (!nonEmpty(feed.version)) return error.MissingVersion;
    const version = try parseVersion(feed.version);
    if (feed.min_supported_version) |min| {
        const min_version = try parseVersion(min);
        if (compareVersion(min_version, version) == .gt) return error.RollbackWindowInvalid;
    }
    if (feed.notes_url) |url| {
        if (!isStrictHttpsUrl(url)) return error.InvalidUrl;
    }
    if (feed.platforms.len == 0) return error.MissingPlatform;

    for (feed.platforms, 0..) |platform, i| {
        try validatePlatform(platform);
        for (feed.platforms[i + 1 ..]) |other| {
            if (std.mem.eql(u8, platform.os, other.os) and std.mem.eql(u8, platform.arch, other.arch)) {
                return error.DuplicatePlatform;
            }
        }
    }
}

pub fn validatePlatform(platform: Platform) Error!void {
    if (!nonEmpty(platform.os) or !nonEmpty(platform.arch) or !nonEmpty(platform.url)) return error.MissingPlatformField;
    if (!isStrictHttpsUrl(platform.url)) return error.InvalidUrl;
    if (platform.size == 0) return error.InvalidSize;
    if (!isLowerHexSha256(platform.sha256)) return error.InvalidHash;
    if (!isEd25519Token(platform.signature)) return error.InvalidSignature;
}

/// Validate the update block from mer.app.zon. All fields omitted means updates
/// are disabled; any partial configuration fails closed. This is structural
/// validation only, not cryptographic verification.
pub fn validateFeedConfig(config: manifest_mod.UpdateConfig) Error!void {
    const has_provider = nonEmpty(config.provider orelse "");
    const has_feed_url = nonEmpty(config.feed_url orelse "");
    const has_public_key = nonEmpty(config.public_key orelse "");
    if (!has_provider and !has_feed_url and !has_public_key) return;
    if (!has_provider or !has_feed_url or !has_public_key) return error.PartialUpdateConfig;

    const provider = config.provider.?;
    if (!(std.mem.eql(u8, provider, "github-releases") or std.mem.eql(u8, provider, "custom-http"))) {
        return error.InvalidProvider;
    }
    if (!isStrictHttpsUrl(config.feed_url.?)) return error.InvalidUrl;
    if (!isEd25519Token(config.public_key.?)) return error.InvalidPublicKey;
}

fn nonEmpty(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

fn isForbiddenUrlByte(c: u8) bool {
    return c <= 0x20 or c == 0x7f or c == '\\';
}

fn isValidPort(port: []const u8) bool {
    if (port.len == 0 or port.len > 5) return false;
    for (port) |c| if (!std.ascii.isDigit(c)) return false;
    const value = std.fmt.parseInt(u16, port, 10) catch return false;
    return value > 0;
}

pub fn isStrictHttpsUrl(url: []const u8) bool {
    if (url.len == 0) return false;
    for (url) |c| if (isForbiddenUrlByte(c)) return false;

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
        return rest.len == 0 or (rest[0] == ':' and isValidPort(rest[1..]));
    }

    const colon = std.mem.indexOfScalar(u8, authority, ':');
    const host = if (colon) |c| authority[0..c] else authority;
    if (host.len == 0) return false;
    if (std.mem.indexOfScalar(u8, host, '.') == null and !std.ascii.eqlIgnoreCase(host, "localhost")) return false;
    if (colon) |c| {
        if (!isValidPort(authority[c + 1 ..])) return false;
    }
    return true;
}

fn isLowerHexSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

fn isEd25519Token(value: []const u8) bool {
    const prefix = "ed25519:";
    if (!std.mem.startsWith(u8, value, prefix) or value.len == prefix.len) return false;
    for (value[prefix.len..]) |c| {
        if (isForbiddenUrlByte(c)) return false;
    }
    return true;
}

const Version = [3]u32;
const VersionOrder = enum { lt, eq, gt };

pub fn parseVersion(value: []const u8) Error!Version {
    if (value.len == 0) return error.InvalidVersion;
    var out: Version = .{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, value, '.');
    var count: usize = 0;
    while (it.next()) |part| {
        if (count == out.len or part.len == 0) return error.InvalidVersion;
        if (part.len > 1 and part[0] == '0') return error.InvalidVersion;
        for (part) |c| if (!std.ascii.isDigit(c)) return error.InvalidVersion;
        out[count] = std.fmt.parseInt(u32, part, 10) catch return error.InvalidVersion;
        count += 1;
    }
    if (count == 0) return error.InvalidVersion;
    return out;
}

fn compareVersion(a: Version, b: Version) VersionOrder {
    for (a, b) |av, bv| {
        if (av < bv) return .lt;
        if (av > bv) return .gt;
    }
    return .eq;
}

const good_json =
    \\{
    \\  "schema_version": 1,
    \\  "app_id": "com.example.app",
    \\  "version": "1.2.3",
    \\  "min_supported_version": "1.0.0",
    \\  "notes_url": "https://example.com/notes",
    \\  "platforms": [{
    \\    "os": "macos",
    \\    "arch": "aarch64",
    \\    "url": "https://example.com/app.zip",
    \\    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    \\    "size": 12345,
    \\    "signature": "ed25519:abcdef"
    \\  }]
    \\}
;

test "validateFeedJson accepts structurally valid update feed" {
    try validateFeedJson(std.testing.allocator, good_json);
}

test "validateFeedJson rejects http artifact URLs" {
    const bad =
        \\{
        \\  "schema_version": 1,
        \\  "app_id": "com.example.app",
        \\  "version": "1.2.3",
        \\  "platforms": [{
        \\    "os": "macos",
        \\    "arch": "aarch64",
        \\    "url": "http://example.com/app.zip",
        \\    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\    "size": 12345,
        \\    "signature": "ed25519:abcdef"
        \\  }]
        \\}
    ;
    try std.testing.expectError(error.InvalidUrl, validateFeedJson(std.testing.allocator, bad));
}

test "validateFeed rejects invalid hash signature duplicate platform and rollback window" {
    const platform: Platform = .{
        .os = "macos",
        .arch = "aarch64",
        .url = "https://example.com/app.zip",
        .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .size = 1,
        .signature = "ed25519:sig",
    };
    var bad_hash = platform;
    bad_hash.sha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    try std.testing.expectError(error.InvalidHash, validatePlatform(bad_hash));

    var bad_sig = platform;
    bad_sig.signature = "not-ed25519:sig";
    try std.testing.expectError(error.InvalidSignature, validatePlatform(bad_sig));

    var bad_size = platform;
    bad_size.size = 0;
    try std.testing.expectError(error.InvalidSize, validatePlatform(bad_size));

    const dupes = [_]Platform{ platform, platform };
    try std.testing.expectError(error.DuplicatePlatform, validateFeed(.{
        .schema_version = 1,
        .app_id = "com.example.app",
        .version = "1.2.3",
        .platforms = &dupes,
    }));

    const one = [_]Platform{platform};
    try std.testing.expectError(error.RollbackWindowInvalid, validateFeed(.{
        .schema_version = 1,
        .app_id = "com.example.app",
        .version = "1.2.3",
        .min_supported_version = "2.0.0",
        .platforms = &one,
    }));
}

test "validateFeedConfig accepts disabled and complete update config" {
    try validateFeedConfig(.{});
    try validateFeedConfig(.{
        .provider = "github-releases",
        .feed_url = "https://example.com/update.json",
        .public_key = "ed25519:pubkey",
    });
    try validateFeedConfig(.{
        .provider = "custom-http",
        .feed_url = "https://updates.example.com/feed.json",
        .public_key = "ed25519:pubkey",
    });
}

test "validateFeedConfig rejects partial invalid provider url and public key" {
    try std.testing.expectError(error.PartialUpdateConfig, validateFeedConfig(.{ .provider = "github-releases" }));
    try std.testing.expectError(error.PartialUpdateConfig, validateFeedConfig(.{ .feed_url = "https://example.com/update.json" }));
    try std.testing.expectError(error.PartialUpdateConfig, validateFeedConfig(.{ .public_key = "ed25519:pubkey" }));
    try std.testing.expectError(error.PartialUpdateConfig, validateFeedConfig(.{
        .provider = "github-releases",
        .feed_url = "https://example.com/update.json",
    }));
    try std.testing.expectError(error.InvalidProvider, validateFeedConfig(.{
        .provider = "s3",
        .feed_url = "https://example.com/update.json",
        .public_key = "ed25519:pubkey",
    }));
    try std.testing.expectError(error.InvalidUrl, validateFeedConfig(.{
        .provider = "github-releases",
        .feed_url = "http://example.com/update.json",
        .public_key = "ed25519:pubkey",
    }));
    try std.testing.expectError(error.InvalidPublicKey, validateFeedConfig(.{
        .provider = "github-releases",
        .feed_url = "https://example.com/update.json",
        .public_key = "ed25519:",
    }));
}

test "parseVersion accepts numeric versions and rejects ambiguous strings" {
    try std.testing.expectEqual(@as(Version, .{ 1, 0, 0 }), try parseVersion("1"));
    try std.testing.expectEqual(@as(Version, .{ 1, 2, 0 }), try parseVersion("1.2"));
    try std.testing.expectEqual(@as(Version, .{ 1, 2, 3 }), try parseVersion("1.2.3"));
    try std.testing.expectError(error.InvalidVersion, parseVersion("1.2.3.4"));
    try std.testing.expectError(error.InvalidVersion, parseVersion("1.02.3"));
    try std.testing.expectError(error.InvalidVersion, parseVersion("1.2.3-beta"));
}

test "isStrictHttpsUrl rejects malformed URLs" {
    try std.testing.expect(isStrictHttpsUrl("https://example.com/a.zip"));
    try std.testing.expect(!isStrictHttpsUrl("https:///a.zip"));
    try std.testing.expect(!isStrictHttpsUrl("https://example.com\\evil"));
    try std.testing.expect(!isStrictHttpsUrl("https://example.com/evil path"));
    try std.testing.expect(!isStrictHttpsUrl("https://user@example.com/a.zip"));
    try std.testing.expect(!isStrictHttpsUrl("https://example.com:notaport/a.zip"));
    try std.testing.expect(!isStrictHttpsUrl("https://example.com:0/a.zip"));
    try std.testing.expect(isStrictHttpsUrl("https://example.com:443/a.zip"));
}
