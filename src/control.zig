const std = @import("std");
const config = @import("config.zig");

pub const State = struct { enabled: bool = true, revision: u64 = 0 };

pub fn read(a: std.mem.Allocator, io: std.Io, path: []const u8) !State {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(256)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer a.free(bytes);
    const parsed = std.json.parseFromSlice(State, a, bytes, .{}) catch return error.InvalidControlState;
    defer parsed.deinit();
    return parsed.value;
}

pub fn update(a: std.mem.Allocator, io: std.Io, path: []const u8, enabled: ?bool) !State {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{path});
    const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .permissions = config.privatePermissions() });
    defer lock.close(io);
    const previous = try read(a, io, path);
    const state: State = .{ .enabled = enabled orelse previous.enabled, .revision = previous.revision +% 1 };
    const bytes = try std.json.Stringify.valueAlloc(a, state, .{ .whitespace = .indent_2 });
    defer a.free(bytes);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .permissions = config.privatePermissions() });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
    return state;
}
