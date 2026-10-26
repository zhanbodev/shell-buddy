const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cwd = Io.Dir.cwd;

pub const help =
    "usage: shell-buddy update [--check] [--no-font]\n\n" ++
    "Download the latest stable GitHub release, verify SHA-256, and replace this executable.\n" ++
    "  --check    Check for an update without changing files\n" ++
    "  --no-font  Skip updating the bundled symbol font\n" ++
    "Configuration, credentials, and shell startup files are preserved.\n";

pub const Source = struct {
    metadata: []const u8 = "https://api.github.com/repos/zhanbodev/shell-buddy/releases/latest",
    downloads: []const u8 = "https://github.com/zhanbodev/shell-buddy/releases/download",
    // Dependency injection for the test driver; the CLI never enables HTTP.
    allow_loopback_http: bool = false,
    timeout_ms: i64 = 30_000,
};
pub const Options = struct { check: bool = false, no_font: bool = false };
pub const Context = struct {
    a: Allocator,
    io: Io,
    executable: []const u8,
    current_version: []const u8,
    font_path: ?[]const u8,
    register_font: bool = true,
};
const Target = struct { platform: []const u8, architecture: []const u8, archive: []const u8 };

pub fn target() !Target {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => .{ .platform = "macos", .architecture = "aarch64", .archive = "shell-buddy-macos-aarch64.tar.gz" },
            .x86_64 => .{ .platform = "macos", .architecture = "x86_64", .archive = "shell-buddy-macos-x86_64.tar.gz" },
            else => error.UnsupportedUpdatePlatform,
        },
        .linux => if (builtin.cpu.arch == .x86_64) .{ .platform = "linux", .architecture = "x86_64", .archive = "shell-buddy-linux-x86_64.tar.gz" } else error.UnsupportedUpdatePlatform,
        .windows => if (builtin.cpu.arch == .x86_64) .{ .platform = "windows", .architecture = "x86_64", .archive = "shell-buddy-windows-x86_64.zip" } else error.UnsupportedUpdatePlatform,
        else => error.UnsupportedUpdatePlatform,
    };
}

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    var options: Options = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) options.check = true else if (std.mem.eql(u8, arg, "--no-font")) options.no_font = true else {
            try Io.File.stderr().writeStreamingAll(init.io, help);
            return 1;
        }
    }
    const a = init.arena.allocator();
    const context: Context = .{
        .a = a,
        .io = init.io,
        .executable = try std.process.executablePathAlloc(init.io, a),
        .current_version = std.mem.trim(u8, @embedFile("version.txt"), "\r\n"),
        .font_path = if (options.no_font or options.check) null else fontPath(a, init.environ_map) catch null,
    };
    perform(context, .{}, options) catch |err| {
        try Io.File.stderr().writeStreamingAll(init.io, try std.fmt.allocPrint(a, "Update failed: {s} ({s}).\n", .{ errorMessage(err), @errorName(err) }));
        return 1;
    };
    return 0;
}

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UpdateTimeout => "download timed out; try again later",
        error.UpdateRateLimited => "GitHub rate limit reached; try again later",
        error.UpdateNotFound => "no published release or matching download was found",
        error.UpdateHttpError => "the release server returned an error",
        error.ChecksumMismatch => "SHA-256 verification failed; the installed program was preserved",
        error.InvalidChecksum => "the release checksum is missing, duplicated, or invalid",
        error.InvalidRelease, error.InvalidArchive => "the release bundle is invalid; the installed program was preserved",
        error.VersionMismatch => "the downloaded executable did not report the expected version",
        error.AccessDenied, error.ReadOnlyFileSystem => "the installation directory is not writable; use its package manager or install in a user-writable directory",
        error.WouldBlock => "another update is already running for this installation",
        error.UnsupportedUpdatePlatform => "no release is available for this OS and architecture",
        error.InsecureUpdateUrl => "refused a non-HTTPS download or redirect",
        error.UpdateRollbackFailed => "could not restore the executable; recover it from the printed backup path",
        else => "could not complete the update; check your network and installation permissions",
    };
}

pub fn perform(ctx: Context, source: Source, options: Options) !void {
    const a = ctx.a;
    const io = ctx.io;
    const selected = try target();
    try say(ctx, "Checking for updates...\n", .{});
    const metadata = try download(a, io, source, source.metadata, 1024 * 1024);
    defer a.free(metadata);
    const Release = struct { tag_name: []const u8, draft: bool, prerelease: bool, assets: []const struct { name: []const u8 } };
    const release = std.json.parseFromSlice(Release, a, metadata, .{ .ignore_unknown_fields = true }) catch return error.InvalidRelease;
    defer release.deinit();
    const tag = release.value.tag_name;
    const newest = try version(tag);
    if (release.value.draft or release.value.prerelease or newest.pre != null) return error.InvalidRelease;
    const installed = try version(ctx.current_version);
    if (newest.order(installed) != .gt) {
        try say(ctx, "Shell Buddy {s} is up to date (latest: {s}).\n", .{ ctx.current_version, tag });
        return;
    }
    var archive_present = false;
    var checksums_present = false;
    for (release.value.assets) |asset| {
        if (std.mem.eql(u8, asset.name, selected.archive)) archive_present = true;
        if (std.mem.eql(u8, asset.name, "SHA256SUMS")) checksums_present = true;
    }
    if (!archive_present or !checksums_present) return error.UpdateNotFound;
    try say(ctx, "Update available: {s} -> {s}\n", .{ ctx.current_version, tag });
    if (options.check) return;

    // A persistent lock file avoids unlink/recreate races between concurrent updates.
    const lock_path = try std.fmt.allocPrint(a, "{s}.update.lock", .{ctx.executable});
    defer a.free(lock_path);
    const lock = try cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = permissions(0o600) });
    defer lock.close(io);
    // Keep temporary files on the installation filesystem, in a private directory.
    var random: [8]u8 = undefined;
    io.random(&random);
    const stage = try std.fmt.allocPrint(a, "{s}.update-{s}", .{ ctx.executable, std.fmt.bytesToHex(random, .lower) });
    defer a.free(stage);
    try cwd().createDir(io, stage, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700));
    defer cwd().deleteTree(io, stage) catch {};

    const root = try std.fmt.allocPrint(a, "{s}/{s}", .{ source.downloads, tag });
    defer a.free(root);
    const sums_url = try std.fmt.allocPrint(a, "{s}/SHA256SUMS", .{root});
    defer a.free(sums_url);
    const sums = try download(a, io, source, sums_url, 64 * 1024);
    defer a.free(sums);
    const expected = try checksum(sums, selected.archive);
    const archive_url = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, selected.archive });
    defer a.free(archive_url);
    try say(ctx, "Downloading {s}...\n", .{selected.archive});
    const archive = try download(a, io, source, archive_url, 8 * 1024 * 1024);
    defer a.free(archive);
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &actual, .{});
    if (!std.mem.eql(u8, &actual, &expected)) return error.ChecksumMismatch;
    var bundle = unpack(a, io, archive, stage) catch return error.InvalidArchive;
    defer bundle.deinit(a);
    const binary = bundle.binary orelse return error.InvalidArchive;
    if (!options.no_font and bundle.font == null) return error.InvalidArchive;
    const Manifest = struct { version: []const u8, platform: []const u8, architecture: []const u8 };
    const manifest = std.json.parseFromSlice(Manifest, a, bundle.manifest orelse return error.InvalidArchive, .{ .ignore_unknown_fields = true }) catch return error.InvalidArchive;
    defer manifest.deinit();
    if ((try version(manifest.value.version)).order(newest) != .eq or
        !std.mem.eql(u8, manifest.value.platform, selected.platform) or
        !std.mem.eql(u8, manifest.value.architecture, selected.architecture)) return error.InvalidArchive;

    const candidate = try std.fs.path.join(a, &.{ stage, if (builtin.os.tag == .windows) "shell-buddy.exe" else "shell-buddy" });
    defer a.free(candidate);
    {
        const file = try cwd().createFile(io, candidate, .{ .exclusive = true, .permissions = permissions(0o755) });
        defer file.close(io);
        try file.writeStreamingAll(io, binary);
        try file.sync(io);
    }
    const probe = std.process.run(a, io, .{
        .argv = &.{ candidate, "--version" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch return error.VersionMismatch;
    defer a.free(probe.stdout);
    defer a.free(probe.stderr);
    if (probe.term != .exited or probe.term.exited != 0 or
        !std.mem.eql(u8, std.mem.trim(u8, probe.stdout, "\r\n"), std.mem.trimStart(u8, tag, "v"))) return error.VersionMismatch;

    try say(ctx, "Installing: {s}\n", .{ctx.executable});
    try replaceExecutable(ctx, candidate);
    if (!options.no_font) {
        if (ctx.font_path) |font_path| {
            installFont(ctx, font_path, bundle.font.?) catch |err| {
                try say(ctx, "Warning: program updated, but font update failed ({s}); see the font installation guide.\n", .{@errorName(err)});
            };
        } else try say(ctx, "Warning: program updated; font directory is unavailable. Install the bundled font manually if needed.\n", .{});
    }
    try say(ctx, "Shell Buddy updated to {s}. Reload your shell integration in existing sessions.\n", .{tag});
}

fn permissions(mode: std.posix.mode_t) Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(mode);
}

fn replaceExecutable(ctx: Context, candidate: []const u8) !void {
    const io = ctx.io;
    if (builtin.os.tag != .windows) {
        const old = try cwd().openFile(io, ctx.executable, .{});
        const stat = old.stat(io) catch |err| {
            old.close(io);
            return err;
        };
        old.close(io);
        const new = try cwd().openFile(io, candidate, .{ .mode = .read_write });
        defer new.close(io);
        try new.setPermissions(io, .fromMode(stat.permissions.toMode() & 0o777));
        try Io.Dir.rename(cwd(), candidate, cwd(), ctx.executable, io);
        return;
    }
    // Windows may deny replacing a mapped image but allows renaming it first.
    const backup = try std.fmt.allocPrint(ctx.a, "{s}.previous", .{ctx.executable});
    defer ctx.a.free(backup);
    cwd().deleteFile(io, backup) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try Io.Dir.renamePreserve(cwd(), ctx.executable, cwd(), backup, io);
    Io.Dir.renamePreserve(cwd(), candidate, cwd(), ctx.executable, io) catch |err| {
        Io.Dir.renamePreserve(cwd(), backup, cwd(), ctx.executable, io) catch {
            try say(ctx, "Recovery executable: {s}\n", .{backup});
            return error.UpdateRollbackFailed;
        };
        return err;
    };
    cwd().deleteFile(io, backup) catch {}; // A mapped image may remain until this process exits.
}

fn fontPath(a: Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (builtin.os.tag == .windows) return std.fs.path.join(a, &.{ env.get("LOCALAPPDATA") orelse return error.NoHome, "Microsoft", "Windows", "Fonts", "ShellBuddyIcons.ttf" });
    if (builtin.os.tag == .linux) if (env.get("XDG_DATA_HOME")) |data| return std.fs.path.join(a, &.{ data, "fonts", "shell-buddy", "ShellBuddyIcons.ttf" });
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(a, if (builtin.os.tag == .macos) &.{ home, "Library", "Fonts", "ShellBuddyIcons.ttf" } else &.{ home, ".local", "share", "fonts", "shell-buddy", "ShellBuddyIcons.ttf" });
}

fn installFont(ctx: Context, path: []const u8, data: []const u8) !void {
    const existing = cwd().readFileAlloc(ctx.io, path, ctx.a, .limited(1024 * 1024)) catch null;
    defer if (existing) |bytes| ctx.a.free(bytes);
    if (existing == null or !std.mem.eql(u8, existing.?, data)) {
        try cwd().createDirPath(ctx.io, std.fs.path.dirname(path) orelse return error.NoHome);
        var file = try cwd().createFileAtomic(ctx.io, path, .{ .replace = true, .permissions = permissions(0o644) });
        defer file.deinit(ctx.io);
        try file.file.writeStreamingAll(ctx.io, data);
        try file.file.sync(ctx.io);
        try file.replace(ctx.io);
    }
    if (builtin.os.tag == .windows and ctx.register_font) {
        const W = struct {
            const HKEY = std.os.windows.HKEY;
            extern "advapi32" fn RegCreateKeyExW(HKEY, [*:0]const u16, u32, ?[*:0]u16, u32, u32, ?*anyopaque, *HKEY, ?*u32) callconv(.winapi) i32;
            extern "advapi32" fn RegSetValueExW(HKEY, [*:0]const u16, u32, u32, [*]const u8, u32) callconv(.winapi) i32;
            extern "advapi32" fn RegCloseKey(HKEY) callconv(.winapi) i32;
        };
        var key: W.HKEY = undefined;
        if (W.RegCreateKeyExW(std.os.windows.HKEY_CURRENT_USER, std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"), 0, null, 0, 2, null, &key, null) != 0) return error.FontRegistrationFailed;
        defer _ = W.RegCloseKey(key);
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(ctx.a, path);
        defer ctx.a.free(wide);
        if (W.RegSetValueExW(key, std.unicode.utf8ToUtf16LeStringLiteral("Shell Buddy Icons (TrueType)"), 0, 1, @ptrCast(wide.ptr), @intCast((wide.len + 1) * 2)) != 0) return error.FontRegistrationFailed;
    }
}

fn say(ctx: Context, comptime format: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(ctx.a, format, args);
    defer ctx.a.free(text);
    try Io.File.stdout().writeStreamingAll(ctx.io, text);
}

fn version(text: []const u8) !std.SemanticVersion {
    if (text.len == 0 or text.len > 128) return error.InvalidRelease;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '+') return error.InvalidRelease;
    return std.SemanticVersion.parse(if (text[0] == 'v') text[1..] else text) catch error.InvalidRelease;
}

fn checksum(text: []const u8, name: []const u8) ![32]u8 {
    var result: ?[32]u8 = null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 67 or !std.mem.eql(u8, std.mem.trimStart(u8, line[64..], " *"), name)) continue;
        if (result != null or line[64] != ' ') return error.InvalidChecksum;
        var hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash, line[0..64]) catch return error.InvalidChecksum;
        result = hash;
    }
    return result orelse error.InvalidChecksum;
}

const Download = struct {
    a: Allocator,
    io: Io,
    source: Source,
    url: []const u8,
    limit: usize,
    done: std.atomic.Value(bool) = .init(false),
    result: ?[]u8 = null,
    failure: ?anyerror = null,
    fn run(self: *Download) void {
        self.result = self.fetch() catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        self.done.store(true, .release);
    }
    fn fetch(self: *Download) ![]u8 {
        var client: std.http.Client = .{ .allocator = self.a, .io = self.io };
        defer client.deinit();
        var url = try self.a.dupe(u8, self.url);
        defer self.a.free(url);
        for (0..6) |_| {
            const uri = try std.Uri.parse(url);
            const host = if (uri.host) |h| h.percent_encoded else "";
            if (!std.mem.eql(u8, uri.scheme, "https") and !(self.source.allow_loopback_http and std.mem.eql(u8, uri.scheme, "http") and std.mem.eql(u8, host, "127.0.0.1"))) return error.InsecureUpdateUrl;
            var req = try client.request(.GET, uri, .{
                .headers = .{ .accept_encoding = .{ .override = "identity" }, .user_agent = .{ .override = "ShellBuddy/" ++ (comptime std.mem.trim(u8, @embedFile("version.txt"), "\r\n")) } },
                .extra_headers = &.{.{ .name = "accept", .value = "application/json, application/octet-stream" }},
                .redirect_behavior = .unhandled,
            });
            defer req.deinit();
            try req.sendBodiless();
            var response = try req.receiveHead(&.{});
            const status: u16 = @intCast(@backingInt(response.head.status));
            if (status == 301 or status == 302 or status == 303 or status == 307 or status == 308) {
                const next = try self.a.dupe(u8, response.head.location orelse return error.InvalidRelease);
                self.a.free(url);
                url = next;
                continue;
            }
            if (status == 403 or status == 429) return error.UpdateRateLimited;
            if (status == 404) return error.UpdateNotFound;
            if (status != 200) return error.UpdateHttpError;
            if (response.head.content_encoding != .identity) return error.InvalidRelease;
            var buffer: [16 * 1024]u8 = undefined;
            const reader = response.reader(&buffer);
            return reader.allocRemaining(self.a, .limited(self.limit));
        }
        return error.TooManyRedirects;
    }
};

fn download(a: Allocator, io: Io, source: Source, url: []const u8, limit: usize) ![]u8 {
    var job: Download = .{ .a = a, .io = io, .source = source, .url = url, .limit = limit };
    var future = try io.concurrent(Download.run, .{&job});
    var joined = false;
    defer if (!joined) {
        future.cancel(io);
        if (job.result) |bytes| a.free(bytes);
    };
    const started = Io.Clock.awake.now(io).toMilliseconds();
    while (!job.done.load(.acquire)) {
        if (Io.Clock.awake.now(io).toMilliseconds() - started >= source.timeout_ms) return error.UpdateTimeout;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    future.await(io);
    joined = true;
    if (job.failure) |err| return err;
    return job.result.?;
}

const Bundle = struct {
    binary: ?[]u8 = null,
    font: ?[]u8 = null,
    manifest: ?[]u8 = null,
    fn deinit(self: *Bundle, a: Allocator) void {
        if (self.binary) |b| a.free(b);
        if (self.font) |b| a.free(b);
        if (self.manifest) |b| a.free(b);
    }
    fn slot(self: *Bundle, name: []const u8) ?*?[]u8 {
        if (std.mem.eql(u8, name, "shell-buddy/bin/shell-buddy" ++ (if (builtin.os.tag == .windows) ".exe" else ""))) return &self.binary;
        if (std.mem.eql(u8, name, "shell-buddy/fonts/ShellBuddyIcons.ttf")) return &self.font;
        if (std.mem.eql(u8, name, "shell-buddy/release.json")) return &self.manifest;
        return null;
    }
    fn limit(self: *Bundle, field: *?[]u8, size: u64) !usize {
        const max: usize = if (field == &self.binary) 5 * 1024 * 1024 else if (field == &self.font) 1024 * 1024 else 64 * 1024;
        if (field.* != null or size == 0 or size > max) return error.InvalidArchive;
        return @intCast(size);
    }
};

fn unpack(a: Allocator, io: Io, archive: []const u8, stage: []const u8) !Bundle {
    var bundle: Bundle = .{};
    errdefer bundle.deinit(a);
    var name_buffer: [1024]u8 = undefined;
    if (builtin.os.tag == .windows) {
        const path = try std.fs.path.join(a, &.{ stage, "bundle.zip" });
        defer a.free(path);
        const file = try cwd().createFile(io, path, .{ .read = true, .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, archive);
        var buffer: [8192]u8 = undefined;
        var reader = file.reader(io, &buffer);
        var iterator = try std.zip.Iterator.init(&reader);
        while (try iterator.next()) |entry| {
            const name = try entry.getFilename(&reader, &name_buffer, .{});
            if (bundle.slot(name)) |field| {
                const size = try bundle.limit(field, entry.uncompressed_size);
                const bytes = try a.alloc(u8, size);
                errdefer a.free(bytes);
                var writer = Io.Writer.fixed(bytes);
                try entry.extractTo(&reader, &writer);
                if (writer.end != size) return error.InvalidArchive;
                field.* = bytes;
            }
        }
    } else {
        var compressed = Io.Reader.fixed(archive);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor = std.compress.flate.Decompress.init(&compressed, .gzip, &window);
        const tar = try decompressor.reader.allocRemaining(a, .limited(16 * 1024 * 1024));
        defer a.free(tar);
        var reader = Io.Reader.fixed(tar);
        var links: [1024]u8 = undefined;
        var iterator = std.tar.Iterator.init(&reader, .{ .file_name_buffer = &name_buffer, .link_name_buffer = &links });
        while (try iterator.next()) |entry| {
            if (bundle.slot(entry.name)) |field| {
                if (entry.kind != .file or entry.link_name.len != 0) return error.InvalidArchive;
                const size = try bundle.limit(field, entry.size);
                field.* = try reader.readAllocAll(a, size);
                iterator.unread_file_bytes = 0;
            }
        }
    }
    return bundle;
}

test "updater rejects unsafe release tags and malformed checksums" {
    try std.testing.expectEqual(std.math.Order.gt, (try version("v0.3.0")).order(try version("0.2.0")));
    try std.testing.expectError(error.InvalidRelease, version("v0.3.0/evil"));
    try std.testing.expectError(error.InvalidRelease, version("v0.3.0\n"));
    const sum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++ "  release.tar.gz\n";
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0xaa)), &(try checksum(sum, "release.tar.gz")));
    try std.testing.expectError(error.InvalidChecksum, checksum(sum ++ sum, "release.tar.gz"));
    try std.testing.expectError(error.InvalidChecksum, checksum(sum, "other.tar.gz"));
}
