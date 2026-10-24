const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const windows = builtin.os.tag == .windows;
extern "c" fn ttyname_r(c_int, [*]u8, usize) c_int;

var interrupted: std.atomic.Value(bool) = .init(false);
const Signals = if (windows) struct {
    fn open() @This() {
        return .{};
    }
    fn close(_: *@This()) void {}
} else struct {
    original: [3]std.posix.Sigaction,
    const kinds = [_]std.posix.SIG{ .INT, .TERM, .HUP };
    fn handle(_: std.posix.SIG) callconv(.c) void {
        interrupted.store(true, .monotonic);
    }
    fn open() @This() {
        interrupted.store(false, .monotonic);
        var self: @This() = undefined;
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = handle }, .mask = std.posix.sigemptyset(), .flags = 0 };
        for (kinds, 0..) |kind, i| std.posix.sigaction(kind, &action, &self.original[i]);
        return self;
    }
    fn close(self: *@This()) void {
        for (kinds, 0..) |kind, i| std.posix.sigaction(kind, &self.original[i], null);
    }
};

const Win = struct {
    const Handle = std.os.windows.HANDLE;
    extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?Handle) callconv(.winapi) Handle;
    extern "kernel32" fn GetConsoleMode(Handle, *u32) callconv(.winapi) i32;
    extern "kernel32" fn SetConsoleMode(Handle, u32) callconv(.winapi) i32;
    extern "kernel32" fn ReadFile(Handle, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn ReadConsoleInputW(Handle, [*]InputRecord, u32, *u32) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(Handle, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleCP(u32) callconv(.winapi) i32;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleOutputCP(u32) callconv(.winapi) i32;
    extern "kernel32" fn WaitForSingleObject(Handle, u32) callconv(.winapi) u32;
    extern "kernel32" fn GetConsoleScreenBufferInfo(Handle, *Info) callconv(.winapi) i32;
    const Coord = extern struct { x: i16, y: i16 };
    const Rect = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
    const Info = extern struct { size: Coord, cursor: Coord, attributes: u16, window: Rect, maximum: Coord };
    const KeyEvent = extern struct { down: i32, repeat: u16, key: u16, scan: u16, character: u16, modifiers: u32 };
    const InputRecord = extern struct { kind: u16, event: extern union { key: KeyEvent, padding: [16]u8 } };
};

pub const Terminal = struct {
    input: std.Io.File,
    output: std.Io.File,
    original: if (windows) u32 else std.posix.termios,
    original_output: u32 = 0,
    input_cp: u32 = 0,
    output_cp: u32 = 0,
    io: std.Io,
    signals: Signals,
    surrogate: u16 = 0,
    inline_saved: bool = false,
    inline_column: ?usize = null,
    pending: [1024]u8 = undefined,
    pending_len: usize = 0,
    pending_offset: usize = 0,

    pub fn open(io: std.Io) !Terminal {
        if (windows) {
            const input_handle = Win.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("CONIN$"), 0xc0000000, 3, null, 3, 0, null);
            if (input_handle == std.os.windows.INVALID_HANDLE_VALUE) return error.NoTerminal;
            const input: std.Io.File = .{ .handle = input_handle, .flags = .{ .nonblocking = false } };
            errdefer input.close(io);
            const output_handle = Win.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"), 0xc0000000, 3, null, 3, 0, null);
            if (output_handle == std.os.windows.INVALID_HANDLE_VALUE) return error.NoTerminal;
            const output: std.Io.File = .{ .handle = output_handle, .flags = .{ .nonblocking = false } };
            errdefer output.close(io);
            var original: u32 = 0;
            var original_out: u32 = 0;
            if (Win.GetConsoleMode(input_handle, &original) == 0 or Win.GetConsoleMode(output_handle, &original_out) == 0) return error.NoTerminal;
            const in_cp = Win.GetConsoleCP();
            const out_cp = Win.GetConsoleOutputCP();
            if (Win.SetConsoleMode(input_handle, (original & ~@as(u32, 0x57)) | 0x288) == 0) return error.NoTerminal;
            errdefer _ = Win.SetConsoleMode(input_handle, original);
            if (Win.SetConsoleMode(output_handle, original_out | 0x5) == 0) return error.NoTerminal;
            _ = Win.SetConsoleCP(65001);
            _ = Win.SetConsoleOutputCP(65001);
            return .{ .input = input, .output = output, .original = original, .original_output = original_out, .input_cp = in_cp, .output_cp = out_cp, .io = io, .signals = Signals.open() };
        } else {
            // Darwin's /dev/tty alias does not support poll reliably. Open the
            // actual terminal device, retaining /dev/tty as a fallback for pipes.
            var path: [std.fs.max_path_bytes]u8 = undefined;
            const named = ttyname_r(0, &path, path.len) == 0 or ttyname_r(2, &path, path.len) == 0;
            const file = try std.Io.Dir.openFileAbsolute(io, if (named) std.mem.sliceTo(&path, 0) else "/dev/tty", .{ .mode = .read_write });
            errdefer file.close(io);
            const original = try std.posix.tcgetattr(file.handle);
            var raw = original;
            raw.iflag.BRKINT = false;
            raw.iflag.ICRNL = false;
            raw.iflag.INPCK = false;
            raw.iflag.ISTRIP = false;
            raw.iflag.IXON = false;
            raw.oflag.OPOST = false;
            raw.lflag.ECHO = false;
            raw.lflag.ICANON = false;
            raw.lflag.IEXTEN = false;
            raw.lflag.ISIG = false;
            raw.cc[@intCast(@backingInt(std.posix.V.MIN))] = 0;
            raw.cc[@intCast(@backingInt(std.posix.V.TIME))] = 0;
            try std.posix.tcsetattr(file.handle, .NOW, raw);
            return .{ .input = file, .output = file, .original = original, .io = io, .signals = Signals.open() };
        }
    }
    pub fn close(self: *Terminal) void {
        self.write("\x1b[0m\x1b[?2004l") catch {};
        if (self.inline_saved) {
            if (self.inline_column != null) {
                var buffer: [48]u8 = undefined;
                const column = self.lineColumn();
                self.write(if (column > 0) (std.fmt.bufPrint(&buffer, "\r\x1b[{d}C\x1b[K", .{column}) catch "") else "\r\x1b[K") catch {};
            }
            // Restore the cursor expected by the suspended native line editor.
            self.write("\x1b8") catch {};
        } else self.write("\r\x1b[2K") catch {};
        if (windows) {
            _ = Win.SetConsoleMode(self.input.handle, self.original);
            _ = Win.SetConsoleMode(self.output.handle, self.original_output);
            _ = Win.SetConsoleCP(self.input_cp);
            _ = Win.SetConsoleOutputCP(self.output_cp);
            self.output.close(self.io);
        } else std.posix.tcsetattr(self.input.handle, .NOW, self.original) catch {};
        self.input.close(self.io);
        self.signals.close();
    }
    pub fn wasInterrupted(_: *Terminal) bool {
        return interrupted.load(.monotonic);
    }
    pub fn write(self: *Terminal, bytes: []const u8) !void {
        if (windows) {
            var offset: usize = 0;
            while (offset < bytes.len) {
                var n: u32 = 0;
                if (Win.WriteFile(self.output.handle, bytes[offset..].ptr, @intCast(bytes.len - offset), &n, null) == 0 or n == 0) return error.TerminalWrite;
                offset += n;
            }
        } else try self.output.writeStreamingAll(self.io, bytes);
    }
    pub fn read(self: *Terminal, buffer: []u8, timeout_ms: u32) !usize {
        if (self.pending_offset < self.pending_len) {
            const n = @min(buffer.len, self.pending_len - self.pending_offset);
            @memcpy(buffer[0..n], self.pending[self.pending_offset..][0..n]);
            self.pending_offset += n;
            return n;
        }
        return self.readDevice(buffer, timeout_ms);
    }
    fn readDevice(self: *Terminal, buffer: []u8, timeout_ms: u32) !usize {
        if (windows) {
            const result = Win.WaitForSingleObject(self.input.handle, timeout_ms);
            if (result == 258) return 0;
            if (result != 0) return error.TerminalRead;
            // Waiting on a Console handle can wake for key-up/resize events.
            // ReadFile could then block indefinitely; consume records instead.
            var events: [32]Win.InputRecord = undefined;
            var count: u32 = 0;
            if (Win.ReadConsoleInputW(self.input.handle, &events, events.len, &count) == 0) return error.TerminalRead;
            var len: usize = 0;
            for (events[0..count]) |event| {
                if (event.kind != 1 or event.event.key.down == 0) continue;
                const key = event.event.key;
                const escape: ?[]const u8 = switch (key.key) {
                    0x0d => if (key.modifiers & 0xc != 0) "\x1b[13;5u" else null,
                    0x25 => "\x1b[D",
                    0x27 => "\x1b[C",
                    0x26 => "\x1b[A",
                    0x28 => "\x1b[B",
                    0x24 => "\x1b[H",
                    0x23 => "\x1b[F",
                    0x2e => "\x1b[3~",
                    else => null,
                };
                var encoded: [4]u8 = undefined;
                const bytes: []const u8 = escape orelse value: {
                    const char = key.character;
                    if (char >= 0xd800 and char <= 0xdbff) {
                        self.surrogate = char;
                        continue;
                    }
                    var cp: u21 = char;
                    if (char >= 0xdc00 and char <= 0xdfff) {
                        if (self.surrogate == 0) continue;
                        cp = 0x10000 + ((@as(u21, self.surrogate) - 0xd800) << 10) + (char - 0xdc00);
                    }
                    self.surrogate = 0;
                    if (cp == 0) continue;
                    const n = std.unicode.utf8Encode(cp, &encoded) catch continue;
                    break :value encoded[0..n];
                };
                var repeat: usize = @max(1, key.repeat);
                while (repeat > 0 and len + bytes.len <= buffer.len) : (repeat -= 1) {
                    @memcpy(buffer[len..][0..bytes.len], bytes);
                    len += bytes.len;
                }
            }
            return len;
        } else {
            var fds = [_]std.posix.pollfd{.{ .fd = self.input.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const count = try std.posix.poll(&fds, @intCast(timeout_ms));
            if (count == 0) return 0;
            if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return error.TerminalClosed;
            return try self.input.readStreaming(self.io, &.{buffer});
        }
    }
    pub fn columns(self: *Terminal) usize {
        if (windows) {
            var info: Win.Info = undefined;
            if (Win.GetConsoleScreenBufferInfo(self.output.handle, &info) != 0) return @intCast(@max(10, info.window.right - info.window.left + 1));
        } else {
            var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
            if (std.posix.system.ioctl(self.input.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&size)) == 0 and size.col >= 10) return size.col;
        }
        return 80;
    }

    pub fn lineColumn(self: *Terminal) usize {
        return @min(self.inline_column orelse 0, self.columns() -| 4);
    }

    pub fn beginInline(self: *Terminal, left_width: usize) !void {
        try self.write("\x1b7");
        self.inline_saved = true;
        const column = if (windows) value: {
            var info: Win.Info = undefined;
            if (Win.GetConsoleScreenBufferInfo(self.output.handle, &info) == 0) return error.CursorPositionUnavailable;
            break :value @as(usize, @intCast(@max(0, info.cursor.x - info.window.left)));
        } else value: {
            try self.write("\x1b[6n");
            const started = std.Io.Clock.awake.now(self.io).toMilliseconds();
            while (self.pending_len < self.pending.len and std.Io.Clock.awake.now(self.io).toMilliseconds() - started < 80) {
                const n = try self.readDevice(self.pending[self.pending_len..], 10);
                self.pending_len += n;
                if (cursorReport(self.pending[0..self.pending_len])) |report| {
                    // Typing can arrive before or after the terminal response.
                    // Keep those bytes for the editor rather than losing input.
                    std.mem.copyForwards(u8, self.pending[report.start..], self.pending[report.end..self.pending_len]);
                    self.pending_len -= report.end - report.start;
                    break :value report.column;
                }
            }
            return error.CursorPositionUnavailable;
        };
        const width = self.columns();
        const start = (column + width - left_width % width) % width;
        const rows = (start + left_width) / width;
        var buffer: [80]u8 = undefined;
        if (rows > 0) try self.write(try std.fmt.bufPrint(&buffer, "\x1b[{d}A", .{rows}));
        try self.write("\r");
        if (start > 0) try self.write(try std.fmt.bufPrint(&buffer, "\x1b[{d}C", .{start}));
        try self.write(if (rows > 0) "\x1b[J" else "\x1b[K");
        self.inline_column = start;
    }
};

const CursorReport = struct { start: usize, end: usize, column: usize };
fn cursorReport(bytes: []const u8) ?CursorReport {
    for (bytes, 0..) |byte, start| {
        if (byte != 27 or start + 2 >= bytes.len or bytes[start + 1] != '[') continue;
        var end = start + 2;
        while (end < bytes.len and (std.ascii.isDigit(bytes[end]) or bytes[end] == ';')) : (end += 1) {}
        if (end == bytes.len or bytes[end] != 'R') continue;
        const value = bytes[start + 2 .. end];
        const split = std.mem.findScalar(u8, value, ';') orelse continue;
        const row = std.fmt.parseInt(u16, value[0..split], 10) catch continue;
        const column = std.fmt.parseInt(u16, value[split + 1 ..], 10) catch continue;
        if (row == 0 or column == 0) continue;
        return .{ .start = start, .end = end + 1, .column = column - 1 };
    }
    return null;
}

test "cursor reports are recognized without consuming surrounding input" {
    try std.testing.expect(cursorReport("\x1b[8;1") == null);
    try std.testing.expect(cursorReport("\x1b[8;0R") == null);
    try std.testing.expect(cursorReport("\x1b[13;5u") == null);
    const report = cursorReport("你\x1b[8;14R好").?;
    try std.testing.expectEqual(@as(usize, 13), report.column);
    try std.testing.expectEqualStrings("你", "你\x1b[8;14R好"[0..report.start]);
    try std.testing.expectEqualStrings("好", "你\x1b[8;14R好"[report.end..]);
}

pub const Key = union(enum) { text: []const u8, enter, execute, tab, escape, cancel, left, right, home, end, backspace, delete, clear, word, paste_start, paste_end, ignore };
pub const Decoder = struct {
    bytes: [1024]u8 = undefined,
    len: usize = 0,
    text_buffer: [4]u8 = undefined,
    pub fn push(self: *Decoder, bytes: []const u8) !void {
        if (self.len + bytes.len > self.bytes.len) return error.InputOverflow;
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
    pub fn take(self: *Decoder, expire_escape: bool) ?Key {
        if (self.len == 0) return null;
        const text = self.bytes[0..self.len];
        const Pair = struct { sequence: []const u8, key: Key };
        const mappings = [_]Pair{
            .{ .sequence = "\x1b[13;9u", .key = .execute },    .{ .sequence = "\x1b[13;5u", .key = .execute },
            .{ .sequence = "\x1b[27;5;13~", .key = .execute }, .{ .sequence = "\x1b[A", .key = .ignore },
            .{ .sequence = "\x1b[B", .key = .ignore },         .{ .sequence = "\x1b[C", .key = .right },
            .{ .sequence = "\x1b[D", .key = .left },           .{ .sequence = "\x1b[H", .key = .home },
            .{ .sequence = "\x1b[F", .key = .end },            .{ .sequence = "\x1bOH", .key = .home },
            .{ .sequence = "\x1bOF", .key = .end },            .{ .sequence = "\x1b[3~", .key = .delete },
            .{ .sequence = "\x1b[200~", .key = .paste_start }, .{ .sequence = "\x1b[201~", .key = .paste_end },
        };
        if (text[0] == 27) {
            for (mappings) |m| {
                if (std.mem.startsWith(u8, text, m.sequence)) {
                    self.consume(m.sequence.len);
                    return m.key;
                }
                if (std.mem.startsWith(u8, m.sequence, text) and !expire_escape) return null;
            }
            if (text.len == 1) {
                self.consume(1);
                return .escape;
            }
            // Discard unknown CSI sequences as a unit, never insert their bytes as text.
            if (text.len >= 2 and text[1] == '[') {
                for (text[2..], 2..) |c, i| if (c >= 0x40 and c <= 0x7e) {
                    self.consume(i + 1);
                    return .ignore;
                };
                if (!expire_escape) return null;
                self.len = 0;
                return .ignore;
            }
            self.consume(1);
            return .ignore;
        }
        const c = text[0];
        const special: ?Key = switch (c) {
            3 => .cancel,
            4 => .cancel,
            9 => .tab,
            10, 13 => .enter,
            1 => .home,
            5 => .end,
            8, 127 => .backspace,
            21 => .clear,
            23 => .word,
            0, 2, 6...7, 11...12, 14...20, 22, 24...26, 28...31 => .ignore,
            else => null,
        };
        if (special) |k| {
            self.consume(1);
            return k;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch {
            self.consume(1);
            return .ignore;
        };
        if (n > self.len) return null;
        // Text borrows decoder memory until the next take()/push().
        const slice = self.bytes[0..n];
        if (!core.validText(slice)) {
            self.consume(n);
            return .ignore;
        }
        // Keep the return slice stable by moving consumed bytes only on the next call.
        @memcpy(&self.text_buffer, &self.bytes[0..4].*);
        self.consume(n);
        return .{ .text = self.text_buffer[0..n] };
    }
    fn consume(self: *Decoder, n: usize) void {
        std.mem.copyForwards(u8, self.bytes[0 .. self.len - n], self.bytes[n..self.len]);
        self.len -= n;
    }
};

test "key decoder handles fragmented UTF-8, CSI shortcuts and escape timeout" {
    var d: Decoder = .{};
    try d.push("\xe4\xbd");
    try std.testing.expect(d.take(false) == null);
    try d.push("\xa0");
    try std.testing.expectEqualStrings("你", d.take(false).?.text);
    try d.push("\x1b[13;");
    try std.testing.expect(d.take(false) == null);
    try d.push("9u");
    try std.testing.expect(d.take(false).? == .execute);
    try d.push("\x1b");
    try std.testing.expect(d.take(false) == null);
    try std.testing.expect(d.take(true).? == .escape);
}

test "Win32 input records retain SDK ABI layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Win.KeyEvent));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(Win.InputRecord));
}
