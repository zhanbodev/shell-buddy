const std = @import("std");
pub const max_command = 4096;
pub const Shell = enum { bash, zsh, powershell };
pub const Action = enum(u8) { accept = 0, execute = 10, cancel = 20 };

pub fn intent(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    return std.mem.trim(u8, if (std.mem.startsWith(u8, trimmed, "//")) trimmed[2..] else trimmed, " \t");
}

pub fn validText(text: []const u8) bool {
    if (text.len == 0 or text.len > max_command or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |byte| if (byte < 32 or byte == 127) return false;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        if ((cp >= 0x80 and cp <= 0x9f) or cp == 0x2028 or cp == 0x2029 or
            (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) return false;
    }
    return true;
}

pub fn command(text: []const u8) ![]const u8 {
    var clean = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, clean, "```")) {
        const first = std.mem.findScalar(u8, clean, '\n') orelse return error.InvalidCommand;
        if (!std.mem.endsWith(u8, clean, "```")) return error.InvalidCommand;
        clean = std.mem.trim(u8, clean[first + 1 .. clean.len - 3], " \t\r\n");
    }
    if (!validText(clean) or std.mem.startsWith(u8, clean, "//") or std.mem.startsWith(u8, clean, "#")) return error.InvalidCommand;
    return clean;
}

pub fn quote(a: std.mem.Allocator, shell: Shell, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try out.writer.writeByte('\'');
    for (text) |c| {
        if (c == '\'') try out.writer.writeAll(if (shell == .powershell) "''" else "'\\''") else try out.writer.writeByte(c);
    }
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

pub const Candidates = struct {
    values: [16][max_command]u8 = undefined,
    lengths: [16]usize = @splat(0),
    len: usize = 0,
    current: usize = 0,

    pub fn get(self: *const Candidates) ?[]const u8 {
        if (self.len == 0) return null;
        return self.values[self.current][0..self.lengths[self.current]];
    }
    pub fn add(self: *Candidates, text: []const u8) bool {
        if (!validText(text)) return false;
        for (0..self.len) |i| if (std.mem.eql(u8, self.values[i][0..self.lengths[i]], text)) return false;
        if (self.len == self.values.len) {
            for (1..self.len) |i| {
                self.values[i - 1] = self.values[i];
                self.lengths[i - 1] = self.lengths[i];
            }
            self.len -= 1;
        }
        @memcpy(self.values[self.len][0..text.len], text);
        self.lengths[self.len] = text.len;
        self.current = self.len;
        self.len += 1;
        return true;
    }
};

pub fn previous(text: []const u8, pos: usize) usize {
    var p = pos;
    if (p > 0) p -= 1;
    while (p > 0 and text[p] & 0xc0 == 0x80) p -= 1;
    return p;
}
pub fn next(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    return @min(text.len, pos + (std.unicode.utf8ByteSequenceLength(text[pos]) catch 1));
}

// Terminal cells, with narrow ambiguous characters. Combining marks take no cell.
pub fn cells(cp: u21) usize {
    if ((cp >= 0x300 and cp <= 0x36f) or (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or (cp >= 0xfe00 and cp <= 0xfe0f) or
        (cp >= 0xfe20 and cp <= 0xfe2f) or cp == 0x200d) return 0;
    if (cp >= 0x1100 and (cp <= 0x115f or cp == 0x2329 or cp == 0x232a or
        (cp >= 0x2e80 and cp <= 0xa4cf) or (cp >= 0xac00 and cp <= 0xd7a3) or
        (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xfe10 and cp <= 0xfe19) or
        (cp >= 0xfe30 and cp <= 0xfe6f) or (cp >= 0xff01 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or (cp >= 0x1f300 and cp <= 0x1faff) or cp >= 0x20000)) return 2;
    return 1;
}
pub fn width(text: []const u8) usize {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| n += cells(cp);
    return n;
}

test "quote paths without evaluating shell syntax" {
    const a = std.testing.allocator;
    const posix = try quote(a, .zsh, "a'$(id).txt");
    defer a.free(posix);
    try std.testing.expectEqualStrings("'a'\\''$(id).txt'", posix);
    const ps = try quote(a, .powershell, "a'b.txt");
    defer a.free(ps);
    try std.testing.expectEqualStrings("'a''b.txt'", ps);
}
test "reject unsafe display, multiple lines and explanations" {
    try std.testing.expectError(error.InvalidCommand, command("echo x\necho y"));
    try std.testing.expectError(error.InvalidCommand, command("echo \x1b[2J"));
    try std.testing.expectError(error.InvalidCommand, command("# run this"));
    try std.testing.expectEqualStrings("touch 'x'", try command("```sh\ntouch 'x'\n```"));
}
test "candidates deduplicate and UTF-8 editing preserves boundaries" {
    var list: Candidates = .{};
    try std.testing.expect(list.add("pwd"));
    try std.testing.expect(!list.add("pwd"));
    try std.testing.expect(list.add("ls"));
    try std.testing.expectEqualStrings("ls", list.get().?);
    try std.testing.expectEqual(@as(usize, 3), previous("你好", 6));
    try std.testing.expectEqual(@as(usize, 6), next("你好", 3));
    try std.testing.expectEqual(@as(usize, 4), width("你好"));
}
