const std = @import("std");
const core = @import("core.zig");

pub const View = struct {
    text: []const u8,
    cursor: usize,
    suggestion: ?[]const u8 = null,
    notice: ?[]const u8 = null,
    ready: bool = false,
    busy: bool = false,
    frame: usize = 0,
    turn: ?usize = null,
    input_style: core.InputStyle = .square,
};

const accent = "\x1b[38;2;233;191;102m";
const muted = "\x1b[90m";
const warning = "\x1b[33m";
const reset = "\x1b[0m";
const background = "\x1b[48;2;34;33;25m";
const foreground = "\x1b[38;2;229;229;231m";
const cap_color = "\x1b[38;2;34;33;25m";
const Line = struct { text: []const u8, column: usize, color: []const u8 };
pub const Position = struct { row: usize, column: usize, height: usize };

// Own one prompt row; the native editor restores its prompt on handoff.
// Reserve the last terminal cell and one body cell for the insertion cursor.
pub fn render(w: *std.Io.Writer, columns: usize, _: usize, rows: usize, view: View) !Position {
    const rounded = view.input_style == .rounded;
    const prefix: usize = if (rounded) 4 else 3;
    const body_end = columns - 1 - @intFromBool(rounded);
    var lines: [4096]Line = undefined;
    var count: usize = 0;
    var cursor_row: usize = 0;
    var cursor_column = prefix;
    var start: usize = 0;
    var offset: usize = 0;
    var x = prefix;
    while (offset < view.text.len) {
        const after = core.next(view.text, offset);
        const width = core.width(view.text[offset..after]);
        if (x + width >= body_end) {
            lines[count] = .{ .text = view.text[start..offset], .column = prefix, .color = foreground };
            count += 1;
            start = offset;
            x = prefix;
        }
        if (offset == view.cursor) {
            cursor_row = count;
            cursor_column = x;
        }
        x += width;
        offset = after;
    }
    if (offset == view.cursor) {
        cursor_row = count;
        cursor_column = x;
    }
    lines[count] = .{ .text = view.text[start..], .column = prefix, .color = foreground };
    count += 1;
    const description_count = count;
    if (view.suggestion) |text| append(&lines, &count, text, columns, prefix, if (view.ready) reset else muted);
    if (view.notice) |text| {
        append(&lines, &count, text, columns, prefix, warning);
    } else if (view.ready and view.suggestion != null and columns >= 36 and rows >= 5) {
        append(&lines, &count, "Tab another  Enter accept", columns, prefix, muted);
    }

    const height_limit = @max(2, rows -| 1);
    const output_count = @min(count - description_count, @max(1, height_limit / 2));
    const description_room = height_limit - output_count;
    const first = if (cursor_row >= description_room) cursor_row - description_room + 1 else 0;
    const description_end = @min(description_count, first + description_room);
    const visible_description = description_end - first;
    const height = visible_description + output_count;
    try w.writeAll("\r" ++ reset ++ "\x1b[J");
    var row: usize = 0;
    while (row < height) : (row += 1) {
        if (row > 0) try w.writeAll("\r\n");
        const index = if (row < visible_description) first + row else description_count + row - visible_description;
        const line = lines[index];
        if (row < visible_description) {
            if (rounded) {
                try w.writeAll(cap_color);
                try w.writeAll(cap(true, row, visible_description));
            }
            try w.writeAll(background ++ foreground);
            if (row == 0) {
                try w.writeAll(if (view.notice != null) warning else accent);
                if (view.turn != null or (view.busy and view.notice == null)) {
                    const phase = if (view.turn) |turn| turn * 2 else view.frame % 16;
                    try w.writeAll(if (phase < 4 or phase >= 14) "\x1b[2m" else if (phase >= 7 and phase < 11) "\x1b[1m" else "\x1b[22m");
                }
                // A single stable prompt: changes in brightness indicate activity.
                try w.writeAll("❯\x1b[22m" ++ foreground ++ "  ");
            } else try spaces(w, 3);
            try w.writeAll(line.text);
            const used = prefix + core.width(line.text);
            if (view.text.len == 0) {
                const hint = "What do you need?";
                const size = @min(hint.len, body_end - used - 1);
                try w.writeAll(muted);
                try w.writeAll(hint[0..size]);
            }
            // Erase with the active background instead of writing padding.
            // A resize between measuring and painting must not wrap old-width
            // spaces into extra rows and lose the native prompt anchor.
            try w.writeAll("\x1b[K");
            if (rounded) {
                try w.print("\x1b[{d}G", .{columns - 1});
                try w.writeAll(reset ++ cap_color);
                try w.writeAll(cap(false, row, visible_description));
            } else try w.print("\x1b[{d}G", .{columns});
            try w.writeAll(reset ++ "\x1b[K");
        } else {
            try spaces(w, line.column);
            try w.writeAll(line.color);
            if (row + 1 == height and index + 1 < count) {
                var end = line.text.len;
                while (end > 0 and core.width(line.text[0..end]) + line.column + 1 >= columns) end = core.previous(line.text, end);
                try w.writeAll(line.text[0..end]);
                try w.writeAll("…");
            } else try w.writeAll(line.text);
        }
        try w.writeAll(reset);
    }
    const visible_cursor = cursor_row - first;
    if (height - 1 > visible_cursor) try w.print("\x1b[{d}A", .{height - 1 - visible_cursor});
    try w.writeByte('\r');
    if (cursor_column > 0) try w.print("\x1b[{d}C", .{cursor_column});
    return .{ .row = visible_cursor, .column = cursor_column, .height = height };
}

fn cap(left: bool, row: usize, height: usize) []const u8 {
    if (height == 1) return if (left) "\u{f5001}" else "\u{f5002}";
    if (row == 0) return if (left) "\u{f5003}" else "\u{f5004}";
    if (row + 1 == height) return if (left) "\u{f5005}" else "\u{f5006}";
    return "\x1b[48;2;34;33;25m ";
}

fn spaces(w: *std.Io.Writer, n: usize) !void {
    for (0..n) |_| try w.writeByte(' ');
}

fn append(lines: []Line, count: *usize, text: []const u8, columns: usize, indent: usize, color: []const u8) void {
    var start: usize = 0;
    var offset: usize = 0;
    var width = indent;
    while (offset < text.len) {
        const after = core.next(text, offset);
        const cells = core.width(text[offset..after]);
        if (width + cells >= columns) {
            lines[count.*] = .{ .text = text[start..offset], .column = indent, .color = color };
            count.* += 1;
            start = offset;
            width = indent;
        }
        width += cells;
        offset = after;
    }
    lines[count.*] = .{ .text = text[start..], .column = indent, .color = color };
    count.* += 1;
}

test "rounded input reserves cursor cells and uses corners when wrapping" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const p = try render(&out.writer, 12, 0, 6, .{ .text = "你好世界你好", .cursor = 18, .input_style = .rounded });
    try std.testing.expect(p.column < 10);
    try std.testing.expect(p.height > 1);
    try std.testing.expect(std.mem.find(u8, out.written(), "\u{f5003}") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "\u{f5006}") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "✦") == null);
}

test "maximum rounded input and candidate stay within the bounded viewport" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const text: [core.max_command]u8 = @splat('x');
    const p = try render(&out.writer, 10, 0, 6, .{ .text = &text, .cursor = text.len, .suggestion = &text, .ready = true, .input_style = .rounded });
    try std.testing.expect(p.height <= 5);
    try std.testing.expect(p.column < 9);
}
