const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const config = @import("config.zig");
pub const Record = struct { key: []const u8, command: []const u8 };

pub fn key(shell: core.Shell, cwd: []const u8, text: []const u8, cfg: config.Config) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const p = cfg.profile;
    for ([_][]const u8{ "v2-no-thinking", @tagName(builtin.os.tag), @tagName(shell), cwd, core.intent(text), cfg.name, if (p) |v| v.base_url else "", if (p) |v| v.model else "", if (p) |v| v.api_key_env orelse "" else "" }) |part| {
        hash.update(part);
        hash.update("\x00");
    }
    var budget: [4]u8 = undefined;
    std.mem.writeInt(u32, &budget, cfg.max_tokens, .little);
    hash.update(&budget);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const Record {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(3 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    const parsed = try std.json.parseFromSlice([]const Record, a, data, .{ .allocate = .alloc_always });
    if (parsed.value.len > 256) return error.InvalidCache;
    return parsed.value;
}

pub fn find(records: []const Record, wanted: []const u8) ?[]const u8 {
    for (records) |record| if (std.mem.eql(u8, record.key, wanted)) {
        return core.command(record.command) catch null;
    };
    return null;
}

pub fn save(a: std.mem.Allocator, io: std.Io, path: []const u8, wanted: []const u8, text: []const u8) !void {
    _ = try core.command(text);
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{path});
    const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .permissions = privatePermissions() });
    defer lock.close(io);
    const previous = load(a, io, path) catch &.{};
    var records: std.ArrayList(Record) = .empty;
    for (previous) |record| {
        if (!std.mem.eql(u8, record.key, wanted) and core.validText(record.command)) try records.append(a, record);
    }
    if (records.items.len >= 256) _ = records.orderedRemove(0);
    try records.append(a, .{ .key = wanted, .command = text });
    const bytes = try std.json.Stringify.valueAlloc(a, records.items, .{});
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .permissions = privatePermissions() });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

fn privatePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

test "cache keys isolate shell, directory, intent, profile and model" {
    const c: config.Config = .{ .config_path = "", .cache_path = "" };
    const first = key(.bash, "/a", "// 当前路径", c);
    try std.testing.expectEqualStrings(&first, &key(.bash, "/a", "当前路径", c));
    try std.testing.expect(!std.mem.eql(u8, &first, &key(.zsh, "/a", "当前路径", c)));
    try std.testing.expect(!std.mem.eql(u8, &first, &key(.bash, "/b", "当前路径", c)));
    var other = c;
    other.name = "other";
    try std.testing.expect(!std.mem.eql(u8, &first, &key(.bash, "/a", "当前路径", other)));
    other = c;
    other.max_tokens = 4096;
    try std.testing.expect(!std.mem.eql(u8, &first, &key(.bash, "/a", "当前路径", other)));
}
