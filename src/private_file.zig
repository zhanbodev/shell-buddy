const std = @import("std");
const builtin = @import("builtin");

pub fn permissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

pub fn parent(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const directory = std.fs.path.dirname(path) orelse return;
    const created = try std.Io.Dir.cwd().createDirPathStatus(io, directory, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700));
    // Never change permissions on a user's existing HOME or arbitrary override
    // directory. The dedicated application directory is safe to tighten.
    if (created == .created or std.mem.eql(u8, std.fs.path.basename(directory), "shell-buddy")) {
        if (builtin.os.tag == .windows) {
            try windowsAcl(a, directory, true);
        } else {
            const dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
            defer dir.close(io);
            try dir.setPermissions(io, .fromMode(0o700));
        }
    }
}

pub fn atomic(a: std.mem.Allocator, io: std.Io, path: []const u8) !std.Io.File.Atomic {
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .permissions = permissions() });
    errdefer file.deinit(io);
    if (builtin.os.tag == .windows) {
        const name = std.fmt.hex(file.file_basename_hex);
        const temporary = try std.fs.path.join(a, &.{ std.fs.path.dirname(path) orelse ".", &name });
        defer a.free(temporary);
        // Restrict the empty temporary file before writing any credentials.
        try windowsAcl(a, temporary, false);
    }
    return file;
}

fn windowsAcl(a: std.mem.Allocator, path: []const u8, directory: bool) !void {
    const Win = struct {
        const Handle = std.os.windows.HANDLE;
        extern "kernel32" fn GetCurrentProcess() callconv(.winapi) Handle;
        extern "kernel32" fn CloseHandle(Handle) callconv(.winapi) i32;
        extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
        extern "advapi32" fn OpenProcessToken(Handle, u32, *Handle) callconv(.winapi) i32;
        extern "advapi32" fn GetTokenInformation(Handle, u32, ?*anyopaque, u32, *u32) callconv(.winapi) i32;
        extern "advapi32" fn ConvertSidToStringSidW(*anyopaque, *?[*:0]u16) callconv(.winapi) i32;
        extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW([*:0]const u16, u32, *?*anyopaque, ?*u32) callconv(.winapi) i32;
        extern "advapi32" fn GetSecurityDescriptorDacl(*anyopaque, *i32, *?*anyopaque, *i32) callconv(.winapi) i32;
        extern "advapi32" fn SetNamedSecurityInfoW([*:0]u16, u32, u32, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) u32;
        const User = extern struct { sid: *anyopaque, attributes: u32 };
    };
    var token: Win.Handle = undefined;
    if (Win.OpenProcessToken(Win.GetCurrentProcess(), 0x8, &token) == 0) return error.CannotRestrictCredentials;
    defer _ = Win.CloseHandle(token);
    var buffer: [512]u8 align(@alignOf(Win.User)) = undefined;
    var needed: u32 = 0;
    if (Win.GetTokenInformation(token, 1, &buffer, buffer.len, &needed) == 0) return error.CannotRestrictCredentials;
    const user: *const Win.User = @ptrCast(&buffer);
    var sid: ?[*:0]u16 = null;
    if (Win.ConvertSidToStringSidW(user.sid, &sid) == 0) return error.CannotRestrictCredentials;
    defer _ = Win.LocalFree(@ptrCast(sid.?));
    const sid_text = try std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(sid.?));
    defer a.free(sid_text);
    const sddl = try std.fmt.allocPrint(a, "D:P(A;{s};FA;;;{s})", .{ if (directory) "OICI" else "", sid_text });
    defer a.free(sddl);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
    defer a.free(wide);
    var descriptor: ?*anyopaque = null;
    if (Win.ConvertStringSecurityDescriptorToSecurityDescriptorW(wide, 1, &descriptor, null) == 0) return error.CannotRestrictCredentials;
    defer _ = Win.LocalFree(descriptor);
    var present: i32 = 0;
    var defaulted: i32 = 0;
    var acl: ?*anyopaque = null;
    if (Win.GetSecurityDescriptorDacl(descriptor.?, &present, &acl, &defaulted) == 0 or present == 0 or acl == null) return error.CannotRestrictCredentials;
    const wide_path = try std.unicode.wtf8ToWtf16LeAllocZ(a, path);
    defer a.free(wide_path);
    if (Win.SetNamedSecurityInfoW(wide_path, 1, 0x80000004, null, null, acl, null) != 0) return error.CannotRestrictCredentials;
}
