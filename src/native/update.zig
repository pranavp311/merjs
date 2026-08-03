// update.zig — signed update feed checks for native apps.
//
// This module implements the production-safe updater core for PR #100:
// signed update metadata verification, update availability decisions, and
// artifact byte/hash verification. It intentionally does not install or replace
// a running app; platform-specific self-install/rollback is separate work.

const std = @import("std");
const manifest_mod = @import("manifest.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_manifest_bytes: usize = 256 * 1024;
pub const max_artifact_bytes: usize = 512 * 1024 * 1024;

pub const Error = error{
    ManifestTooLarge,
    ArtifactTooLarge,
    ArtifactHashMismatch,
    InvalidSchemaVersion,
    InvalidMetadataVersion,
    StaleUpdateMetadata,
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
    CurrentVersionUnsupported,
    PartialUpdateConfig,
    InvalidProvider,
    InvalidPublicKey,
    InvalidJson,
    AppIdMismatch,
    PlatformNotFound,
    OutOfMemory,
};

pub const Feed = struct {
    schema_version: u32,
    /// Monotonic signed feed metadata sequence. Callers must persist the highest
    /// accepted value and pass it to checkForUpdate* to reject lower values.
    metadata_version: u64,
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
    /// Ed25519 signature over `signedPayload(feed, platform)` encoded as
    /// `ed25519:<base64-raw-64-byte-signature>`.
    signature: []const u8,
};

pub const VerifiedUpdate = struct {
    app_id: []u8,
    version: []u8,
    os: []u8,
    arch: []u8,
    url: []u8,
    sha256: []u8,
    size: u64,
    metadata_version: u64,
    notes_url: ?[]u8 = null,

    pub fn deinit(self: *VerifiedUpdate, alloc: std.mem.Allocator) void {
        alloc.free(self.app_id);
        alloc.free(self.version);
        alloc.free(self.os);
        alloc.free(self.arch);
        alloc.free(self.url);
        alloc.free(self.sha256);
        if (self.notes_url) |notes| alloc.free(notes);
        self.* = undefined;
    }
};

pub const CheckResult = union(enum) {
    /// Validated metadata version accepted by this check. Persist it and pass it
    /// as highest_seen_metadata_version on the next check to reject lower values.
    no_update: u64,
    update_available: VerifiedUpdate,

    pub fn deinit(self: *CheckResult, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .no_update => {},
            .update_available => |*info| info.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const FetchFn = *const fn (alloc: std.mem.Allocator, url: []const u8, max_bytes: usize) anyerror![]u8;

fn updatesDisabled(config: manifest_mod.UpdateConfig) bool {
    return !nonEmpty(config.provider orelse "") and
        !nonEmpty(config.feed_url orelse "") and
        !nonEmpty(config.public_key orelse "");
}

pub fn validateFeedJson(alloc: std.mem.Allocator, json: []const u8) !void {
    if (json.len > max_manifest_bytes) return error.ManifestTooLarge;
    var parsed = std.json.parseFromSlice(Feed, alloc, json, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    try validateFeed(parsed.value);
}

pub fn validateFeed(feed: Feed) Error!void {
    if (feed.schema_version != 1) return error.InvalidSchemaVersion;
    if (feed.metadata_version == 0) return error.InvalidMetadataVersion;
    if (!isSafeSignedString(feed.app_id)) return error.MissingAppId;
    if (!nonEmpty(feed.version)) return error.MissingVersion;
    const version = try parseVersion(feed.version);
    if (feed.min_supported_version) |min| {
        if (!isSafeSignedString(min)) return error.InvalidVersion;
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
    if (!isSafeSignedString(platform.os) or !isSafeSignedString(platform.arch) or !nonEmpty(platform.url)) return error.MissingPlatformField;
    if (!isStrictHttpsUrl(platform.url)) return error.InvalidUrl;
    if (platform.size == 0 or platform.size > max_artifact_bytes) return error.InvalidSize;
    if (!isLowerHexSha256(platform.sha256)) return error.InvalidHash;
    if (!isEd25519Token(platform.signature)) return error.InvalidSignature;
}

/// Validate the update block from mer.app.zon. All fields omitted means updates
/// are disabled; any partial configuration fails closed.
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
    _ = decodeEd25519PublicKey(config.public_key.?) catch return error.InvalidPublicKey;
}

pub fn checkForUpdate(
    alloc: std.mem.Allocator,
    config: manifest_mod.UpdateConfig,
    app_id: []const u8,
    current_version: []const u8,
    target_os: []const u8,
    target_arch: []const u8,
    highest_seen_metadata_version: u64,
    fetch: FetchFn,
) !CheckResult {
    try validateFeedConfig(config);
    if (updatesDisabled(config)) return .{ .no_update = 0 };
    const feed_url = config.feed_url orelse return error.PartialUpdateConfig;
    const body = try fetch(alloc, feed_url, max_manifest_bytes);
    defer alloc.free(body);
    return try checkForUpdateJson(alloc, config, app_id, current_version, target_os, target_arch, highest_seen_metadata_version, body);
}

pub fn checkForUpdateJson(
    alloc: std.mem.Allocator,
    config: manifest_mod.UpdateConfig,
    app_id: []const u8,
    current_version: []const u8,
    target_os: []const u8,
    target_arch: []const u8,
    highest_seen_metadata_version: u64,
    json: []const u8,
) !CheckResult {
    if (json.len > max_manifest_bytes) return error.ManifestTooLarge;
    try validateFeedConfig(config);
    if (updatesDisabled(config)) return .{ .no_update = 0 };
    const public_key = config.public_key orelse return error.PartialUpdateConfig;

    var parsed = std.json.parseFromSlice(Feed, alloc, json, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const feed = parsed.value;
    try validateFeed(feed);
    if (feed.metadata_version < highest_seen_metadata_version) return error.StaleUpdateMetadata;
    if (!std.mem.eql(u8, feed.app_id, app_id)) return error.AppIdMismatch;

    const platform = findPlatform(feed, target_os, target_arch) orelse return error.PlatformNotFound;
    try verifyPlatformSignature(alloc, public_key, feed, platform);

    const current = try parseVersion(current_version);
    const next = try parseVersion(feed.version);
    if (feed.min_supported_version) |min| {
        const min_version = try parseVersion(min);
        if (compareVersion(current, min_version) == .lt) return error.CurrentVersionUnsupported;
    }
    if (compareVersion(next, current) != .gt) return .{ .no_update = feed.metadata_version };
    return .{ .update_available = try copyVerifiedUpdate(alloc, feed, platform) };
}

pub fn verifyArtifactBytes(platform: Platform, artifact: []const u8) Error!void {
    if (artifact.len > max_artifact_bytes) return error.ArtifactTooLarge;
    if (artifact.len != platform.size) return error.ArtifactHashMismatch;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(artifact, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, platform.sha256)) return error.ArtifactHashMismatch;
}

pub fn verifyPlatformSignature(alloc: std.mem.Allocator, public_key_token: []const u8, feed: Feed, platform: Platform) !void {
    const pk = decodeEd25519PublicKey(public_key_token) catch return error.InvalidPublicKey;
    const sig = decodeEd25519Signature(platform.signature) catch return error.InvalidSignature;
    const payload = try signedPayload(alloc, feed, platform);
    defer alloc.free(payload);
    sig.verifyStrict(payload, pk) catch return error.InvalidSignature;
}

pub fn signedPayload(alloc: std.mem.Allocator, feed: Feed, platform: Platform) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "merjs-update-v1\n");
    try appendSignedField(alloc, &out, "schema_version", "1");
    var metadata_buf: [32]u8 = undefined;
    const metadata_version = try std.fmt.bufPrint(&metadata_buf, "{d}", .{feed.metadata_version});
    try appendSignedField(alloc, &out, "metadata_version", metadata_version);
    try appendSignedField(alloc, &out, "app_id", feed.app_id);
    try appendSignedField(alloc, &out, "version", feed.version);
    try appendSignedField(alloc, &out, "min_supported_version", feed.min_supported_version orelse "-");
    try appendSignedField(alloc, &out, "notes_url", feed.notes_url orelse "-");
    try appendSignedField(alloc, &out, "published_at", feed.published_at orelse "-");
    try appendSignedField(alloc, &out, "os", platform.os);
    try appendSignedField(alloc, &out, "arch", platform.arch);
    try appendSignedField(alloc, &out, "url", platform.url);
    try appendSignedField(alloc, &out, "sha256", platform.sha256);
    var size_buf: [32]u8 = undefined;
    const size = try std.fmt.bufPrint(&size_buf, "{d}", .{platform.size});
    try appendSignedField(alloc, &out, "size", size);
    return out.toOwnedSlice(alloc);
}

fn appendSignedField(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    if (!isSafeSignedString(name) or !isSafeSignedString(value)) return error.InvalidSignature;
    try out.appendSlice(alloc, name);
    try out.append(alloc, ':');
    var len_buf: [32]u8 = undefined;
    const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{value.len});
    try out.appendSlice(alloc, len_str);
    try out.append(alloc, ':');
    try out.appendSlice(alloc, value);
    try out.append(alloc, '\n');
}

fn copyVerifiedUpdate(alloc: std.mem.Allocator, feed: Feed, platform: Platform) !VerifiedUpdate {
    var out: VerifiedUpdate = .{
        .app_id = try alloc.dupe(u8, feed.app_id),
        .metadata_version = feed.metadata_version,
        .version = &.{},
        .os = &.{},
        .arch = &.{},
        .url = &.{},
        .sha256 = &.{},
        .size = platform.size,
        .notes_url = null,
    };
    errdefer alloc.free(out.app_id);
    out.version = try alloc.dupe(u8, feed.version);
    errdefer alloc.free(out.version);
    out.os = try alloc.dupe(u8, platform.os);
    errdefer alloc.free(out.os);
    out.arch = try alloc.dupe(u8, platform.arch);
    errdefer alloc.free(out.arch);
    out.url = try alloc.dupe(u8, platform.url);
    errdefer alloc.free(out.url);
    out.sha256 = try alloc.dupe(u8, platform.sha256);
    errdefer alloc.free(out.sha256);
    if (feed.notes_url) |url| {
        out.notes_url = try alloc.dupe(u8, url);
        errdefer alloc.free(out.notes_url.?);
    }
    return out;
}

fn findPlatform(feed: Feed, os: []const u8, arch: []const u8) ?Platform {
    for (feed.platforms) |platform| {
        if (std.mem.eql(u8, platform.os, os) and std.mem.eql(u8, platform.arch, arch)) return platform;
    }
    return null;
}

fn decodeEd25519PublicKey(token: []const u8) !Ed25519.PublicKey {
    var bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    try decodeTokenExact(token, &bytes);
    return Ed25519.PublicKey.fromBytes(bytes) catch error.InvalidPublicKey;
}

fn decodeEd25519Signature(token: []const u8) !Ed25519.Signature {
    var bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    try decodeTokenExact(token, &bytes);
    return Ed25519.Signature.fromBytes(bytes);
}

fn decodeTokenExact(token: []const u8, out: []u8) !void {
    const prefix = "ed25519:";
    if (!std.mem.startsWith(u8, token, prefix)) return error.InvalidSignature;
    const encoded = token[prefix.len..];
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidSignature;
    if (decoded_len != out.len) return error.InvalidSignature;
    _ = std.base64.standard.Decoder.decode(out, encoded) catch return error.InvalidSignature;
}

fn nonEmpty(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

fn isSafeSignedString(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (c < 0x21 or c > 0x7e) return false;
    }
    return true;
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

const TestSigned = struct {
    pub const seed: [32]u8 = .{0} ** 32;
    pub const sha = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    pub fn keyPair() Ed25519.KeyPair {
        return Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    }
    pub fn publicKeyToken(alloc: std.mem.Allocator) ![]u8 {
        const pk = keyPair().public_key.toBytes();
        const encoded_len = std.base64.standard.Encoder.calcSize(pk.len);
        const out = try alloc.alloc(u8, "ed25519:".len + encoded_len);
        @memcpy(out[0.."ed25519:".len], "ed25519:");
        _ = std.base64.standard.Encoder.encode(out["ed25519:".len..], &pk);
        return out;
    }
    pub fn signToken(alloc: std.mem.Allocator, feed: Feed, platform: Platform) ![]u8 {
        const payload = try signedPayload(alloc, feed, platform);
        defer alloc.free(payload);
        const sig = try Ed25519.KeyPair.sign(keyPair(), payload, null);
        const sig_bytes = sig.toBytes();
        const encoded_len = std.base64.standard.Encoder.calcSize(sig_bytes.len);
        const out = try alloc.alloc(u8, "ed25519:".len + encoded_len);
        @memcpy(out[0.."ed25519:".len], "ed25519:");
        _ = std.base64.standard.Encoder.encode(out["ed25519:".len..], &sig_bytes);
        return out;
    }
    pub fn feedJson(alloc: std.mem.Allocator, version: []const u8, signature: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc,
            \\{{
            \\  "schema_version": 1,
            \\  "metadata_version": 1,
            \\  "app_id": "com.example.app",
            \\  "version": "{s}",
            \\  "min_supported_version": "1.0.0",
            \\  "notes_url": "https://example.com/notes",
            \\  "platforms": [{{
            \\    "os": "macos",
            \\    "arch": "aarch64",
            \\    "url": "https://example.com/app.zip",
            \\    "sha256": "{s}",
            \\    "size": 5,
            \\    "signature": "{s}"
            \\  }}]
            \\}}
        , .{ version, sha, signature });
    }
};

var test_fetch_body: []const u8 = "";

fn testFetch(alloc: std.mem.Allocator, url: []const u8, max_bytes: usize) anyerror![]u8 {
    try std.testing.expectEqualStrings("https://example.com/update.json", url);
    try std.testing.expect(test_fetch_body.len <= max_bytes);
    return try alloc.dupe(u8, test_fetch_body);
}

fn signedTestPlatform(signature: []const u8) Platform {
    return .{
        .os = "macos",
        .arch = "aarch64",
        .url = "https://example.com/app.zip",
        .sha256 = TestSigned.sha,
        .size = 5,
        .signature = signature,
    };
}

fn signedTestFeed(signature: []const u8, version: []const u8) Feed {
    return .{
        .schema_version = 1,
        .metadata_version = 1,
        .app_id = "com.example.app",
        .version = version,
        .min_supported_version = "1.0.0",
        .notes_url = "https://example.com/notes",
        .platforms = &[_]Platform{signedTestPlatform(signature)},
    };
}

test "validateFeedJson accepts structurally valid signed update feed" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, "1.2.3", sig);
    defer std.testing.allocator.free(json);
    try validateFeedJson(std.testing.allocator, json);
}

test "checkForUpdateJson treats disabled updates as no_update without panic" {
    var result = try checkForUpdateJson(std.testing.allocator, .{}, "com.example.app", "1.0.0", "macos", "aarch64", 0, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), result.no_update);
}

test "checkForUpdateJson accepts repeated metadata_version for update_available" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, "1.2.3", sig);
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    var result = try checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", 1, json);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .update_available);
    try std.testing.expectEqualStrings("1.2.3", result.update_available.version);
}

test "checkForUpdate uses fetcher abstraction with size cap" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, "1.2.3", sig);
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    test_fetch_body = json;
    var result = try checkForUpdate(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", 0, testFetch);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .update_available);
}

test "checkForUpdateJson accepts repeated metadata_version for no_update" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, "1.2.3", sig);
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    var result = try checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.3", "macos", "aarch64", 1, json);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), result.no_update);
}

test "checkForUpdateJson rejects wrong signature app platform and rollback window" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, "1.2.4", sig);
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try std.testing.expectError(error.InvalidSignature, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", 0, json));

    const good_json = try TestSigned.feedJson(std.testing.allocator, "1.2.3", sig);
    defer std.testing.allocator.free(good_json);
    try std.testing.expectError(error.AppIdMismatch, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.other.app", "1.2.2", "macos", "aarch64", 0, good_json));
    try std.testing.expectError(error.PlatformNotFound, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "windows", "x86_64", 0, good_json));
    try std.testing.expectError(error.CurrentVersionUnsupported, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "0.9.0", "macos", "aarch64", 0, good_json));
}

test "checkForUpdateJson rejects tampered min_supported_version" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "schema_version": 1,
        \\  "metadata_version": 1,
        \\  "app_id": "com.example.app",
        \\  "version": "1.2.3",
        \\  "min_supported_version": "1.1.0",
        \\  "platforms": [{{
        \\    "os": "macos",
        \\    "arch": "aarch64",
        \\    "url": "https://example.com/app.zip",
        \\    "sha256": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        \\    "size": 5,
        \\    "signature": "{s}"
        \\  }}]
        \\}}
    , .{sig});
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try std.testing.expectError(error.InvalidSignature, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", 0, json));
}

test "checkForUpdateJson rejects tampered version that would suppress updates" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, "1.0.0", sig);
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try std.testing.expectError(error.InvalidSignature, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.0.0", "macos", "aarch64", 0, json));
}

test "checkForUpdateJson rejects tampered notes_url returned in metadata" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "schema_version": 1,
        \\  "metadata_version": 1,
        \\  "app_id": "com.example.app",
        \\  "version": "1.2.3",
        \\  "min_supported_version": "1.0.0",
        \\  "notes_url": "https://evil.example/notes",
        \\  "platforms": [{{
        \\    "os": "macos",
        \\    "arch": "aarch64",
        \\    "url": "https://example.com/app.zip",
        \\    "sha256": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        \\    "size": 5,
        \\    "signature": "{s}"
        \\  }}]
        \\}}
    , .{sig});
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try std.testing.expectError(error.InvalidSignature, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", 0, json));
}

test "checkForUpdateJson treats empty-string config as disabled" {
    var result = try checkForUpdateJson(std.testing.allocator, .{ .provider = "", .feed_url = "", .public_key = "" }, "com.example.app", "1.0.0", "macos", "aarch64", 0, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), result.no_update);
}

test "checkForUpdateJson rejects lower metadata_version" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, "1.2.3", sig);
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try std.testing.expectError(error.StaleUpdateMetadata, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", 2, json));
}

test "verifyArtifactBytes enforces size and sha256" {
    const platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    try verifyArtifactBytes(platform, "hello");
    try std.testing.expectError(error.ArtifactHashMismatch, verifyArtifactBytes(platform, "hellO"));
    try std.testing.expectError(error.ArtifactHashMismatch, verifyArtifactBytes(platform, "hello!"));
}

test "validateFeedJson rejects http artifact URLs" {
    const bad =
        \\{
        \\  "schema_version": 1,
        \\  "metadata_version": 1,
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
        .metadata_version = 1,
        .app_id = "com.example.app",
        .version = "1.2.3",
        .platforms = &dupes,
    }));

    const one = [_]Platform{platform};
    try std.testing.expectError(error.RollbackWindowInvalid, validateFeed(.{
        .schema_version = 1,
        .metadata_version = 1,
        .app_id = "com.example.app",
        .version = "1.2.3",
        .min_supported_version = "2.0.0",
        .platforms = &one,
    }));
}

test "validateFeedConfig accepts disabled and complete update config" {
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try validateFeedConfig(.{});
    try validateFeedConfig(.{
        .provider = "github-releases",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    });
    try validateFeedConfig(.{
        .provider = "custom-http",
        .feed_url = "https://updates.example.com/feed.json",
        .public_key = public_key,
    });
}

test "validateFeedConfig rejects partial invalid provider url and public key" {
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try std.testing.expectError(error.PartialUpdateConfig, validateFeedConfig(.{ .provider = "github-releases" }));
    try std.testing.expectError(error.PartialUpdateConfig, validateFeedConfig(.{ .feed_url = "https://example.com/update.json" }));
    try std.testing.expectError(error.PartialUpdateConfig, validateFeedConfig(.{ .public_key = public_key }));
    try std.testing.expectError(error.PartialUpdateConfig, validateFeedConfig(.{
        .provider = "github-releases",
        .feed_url = "https://example.com/update.json",
    }));
    try std.testing.expectError(error.InvalidProvider, validateFeedConfig(.{
        .provider = "s3",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }));
    try std.testing.expectError(error.InvalidUrl, validateFeedConfig(.{
        .provider = "github-releases",
        .feed_url = "http://example.com/update.json",
        .public_key = public_key,
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
