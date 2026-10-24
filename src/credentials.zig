const std = @import("std");
const private = @import("private_file.zig");

pub fn validKey(value: []const u8) bool {
    if (value.len == 0 or value.len > 4096) return false;
    for (value) |c| if (c < 33 or c > 126) return false;
    return true;
}

pub fn validEnvName(value: []const u8) bool {
    if (value.len == 0 or (!std.ascii.isAlphabetic(value[0]) and value[0] != '_')) return false;
    for (value[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn document(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidCredentialsFile;
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCredentialsFile;
    for (parsed.value.object.values()) |value| {
        if (value != .string or !validKey(value.string)) return error.InvalidCredentialsFile;
    }
    return parsed;
}

pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8, profile: []const u8) !?[]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(65536)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.CannotReadCredentials,
    };
    defer {
        std.crypto.secureZero(u8, bytes);
        a.free(bytes);
    }
    var parsed = try document(a, bytes);
    defer parsed.deinit();
    defer for (parsed.value.object.values()) |v| {
        std.crypto.secureZero(u8, @constCast(v.string));
    };
    const value = parsed.value.object.get(profile) orelse return null;
    return try a.dupe(u8, value.string);
}

pub fn resolve(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, path: []const u8, profile: []const u8, env_name: ?[]const u8) !?[]const u8 {
    if (env_name) |name| {
        if (!validEnvName(name)) return error.InvalidApiKeyEnv;
        if (env.get(name)) |key| {
            if (!validKey(key)) return error.InvalidApiKey;
            return key;
        }
    }
    const saved = try load(a, io, path, profile);
    if (saved == null and env_name != null) return error.MissingApiKey;
    return saved;
}

pub fn save(a: std.mem.Allocator, io: std.Io, path: []const u8, profile: []const u8, key: []const u8) !void {
    if (!validKey(key)) return error.InvalidApiKey;
    try private.parent(a, io, path);
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{path});
    defer a.free(lock_path);
    const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .permissions = private.permissions() });
    defer lock.close(io);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(65536)) catch |err| switch (err) {
        error.FileNotFound => try a.dupe(u8, "{}"),
        else => return error.CannotReadCredentials,
    };
    defer {
        std.crypto.secureZero(u8, bytes);
        a.free(bytes);
    }
    var parsed = try document(a, bytes);
    defer parsed.deinit();
    defer for (parsed.value.object.values()) |v| {
        std.crypto.secureZero(u8, @constCast(v.string));
    };
    // Own this copy because document() strings are erased on exit.
    const owned = try parsed.arena.allocator().dupe(u8, key);
    try parsed.value.object.put(parsed.arena.allocator(), profile, .{ .string = owned });
    const serialized = try std.json.Stringify.valueAlloc(a, parsed.value, .{ .whitespace = .indent_2 });
    defer {
        std.crypto.secureZero(u8, serialized);
        a.free(serialized);
    }
    if (serialized.len >= 65536) return error.CredentialsTooLarge;
    var file = try private.atomic(a, io, path);
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, serialized);
    try file.file.writeStreamingAll(io, "\n");
    try file.replace(io);
}

test "credential validation accepts names, rejects secrets as names and header injection" {
    try std.testing.expect(validEnvName("SHELL_BUDDY_API_KEY"));
    try std.testing.expect(!validEnvName("sk-example-secret"));
    try std.testing.expect(!validEnvName(""));
    try std.testing.expect(!validKey("x\r\nAuthorization: x"));
    try std.testing.expect(!validKey(""));
    try std.testing.expect(validKey("test-key_123"));
}
