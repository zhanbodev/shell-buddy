const std = @import("std");
const core = @import("core.zig");

fn pathFor(text: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, prefix) or !std.mem.endsWith(u8, text, suffix) or text.len <= prefix.len + suffix.len) return null;
    const path = std.mem.trim(u8, text[prefix.len .. text.len - suffix.len], " \t");
    if (!core.validText(path)) return null;
    // Rules only accept one explicit path, never silently interpret extra instructions.
    if (std.mem.findAny(u8, path, "\"'`;&|$<>") != null) return null;
    for ([_][]const u8{ "，", "。", "；" }) |punctuation| if (std.mem.find(u8, path, punctuation) != null) return null;
    return path;
}

pub fn predict(a: std.mem.Allocator, shell: core.Shell, raw: []const u8) !?[]u8 {
    const text = core.intent(raw);
    if (!core.validText(text)) return null;
    const ps = shell == .powershell;
    for ([_][]const u8{ "当前路径", "显示当前路径", "显示当前目录", "当前目录", "print working directory", "pwd" }) |phrase| {
        if (std.mem.eql(u8, text, phrase)) return try a.dupe(u8, if (ps) "Get-Location" else "pwd");
    }
    for ([_][]const u8{ "列出目录", "列出当前目录", "列出文件", "查看当前目录", "list files", "list directory" }) |phrase| {
        if (std.mem.eql(u8, text, phrase)) return try a.dupe(u8, if (ps) "Get-ChildItem" else "ls");
    }
    const patterns = [_]struct { prefix: []const u8, suffix: []const u8, directory: bool }{
        .{ .prefix = "创建", .suffix = "文件", .directory = false },
        .{ .prefix = "创建文件 ", .suffix = "", .directory = false },
        .{ .prefix = "新建", .suffix = "文件", .directory = false },
        .{ .prefix = "新建文件 ", .suffix = "", .directory = false },
        .{ .prefix = "create file ", .suffix = "", .directory = false },
        .{ .prefix = "创建", .suffix = "目录", .directory = true },
        .{ .prefix = "创建目录 ", .suffix = "", .directory = true },
        .{ .prefix = "创建", .suffix = "文件夹", .directory = true },
        .{ .prefix = "create directory ", .suffix = "", .directory = true },
    };
    for (patterns) |pattern| {
        if (pathFor(text, pattern.prefix, pattern.suffix)) |path| {
            // A ./ prefix prevents leading '-' from becoming an option, including BSD touch.
            const safe_path = if (!ps and !std.mem.startsWith(u8, path, "/") and !std.mem.startsWith(u8, path, "./")) try std.fmt.allocPrint(a, "./{s}", .{path}) else try a.dupe(u8, path);
            defer a.free(safe_path);
            const quoted = try core.quote(a, shell, safe_path);
            defer a.free(quoted);
            return try std.fmt.allocPrint(a, "{s}{s}", .{
                if (ps) (if (pattern.directory) "New-Item -ItemType Directory -Path " else "New-Item -ItemType File -Path ") else (if (pattern.directory) "mkdir -p " else "touch "),
                quoted,
            });
        }
    }
    return null;
}

test "Chinese and English explicit intents on each shell" {
    const a = std.testing.allocator;
    const file = (try predict(a, .zsh, "// 创建hello.txt 文件")).?;
    defer a.free(file);
    try std.testing.expectEqualStrings("touch './hello.txt'", file);
    const dir = (try predict(a, .bash, "创建 工作 文档 目录")).?;
    defer a.free(dir);
    try std.testing.expectEqualStrings("mkdir -p './工作 文档'", dir);
    const ps = (try predict(a, .powershell, "create file hello.txt")).?;
    defer a.free(ps);
    try std.testing.expectEqualStrings("New-Item -ItemType File -Path 'hello.txt'", ps);
    try std.testing.expect((try predict(a, .bash, "创建 x; rm -rf / 文件")) == null);
    try std.testing.expect((try predict(a, .bash, "帮我优化数据库")) == null);
}
