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
    icon: core.Icon = .star,
};

const accent = "\x1b[36m";
const muted = "\x1b[90m";
const warning = "\x1b[33m";
const reset = "\x1b[0m";

const Line = struct { text: []const u8, column: usize, color: []const u8, marker: bool = false };
pub const Position = struct { row: usize, column: usize, height: usize };

// Explicit CR/LF wrapping avoids terminal-dependent wide-character autowrap.
// Keep one cell unused, including when the insertion cursor is at line end.
pub fn render(w: *std.Io.Writer, columns: usize, column: usize, rows: usize, view: View) !Position {
    var lines: [2048]Line = undefined;
    var count: usize = 0;
    var cursor_row: usize = 0;
    var cursor_column: usize = column + 3;
    var start: usize = 0;
    var offset: usize = 0;
    var x = column + 3;
    var indent = x;
    while (offset < view.text.len) {
        const after = core.next(view.text, offset);
        const width = core.width(view.text[offset..after]);
        if (x + width >= columns) {
            lines[count] = .{ .text = view.text[start..offset], .column = indent, .color = reset, .marker = count == 0 };
            count += 1;
            start = offset;
            x = column + 3;
            indent = x;
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
    lines[count] = .{ .text = view.text[start..], .column = indent, .color = reset, .marker = count == 0 };
    count += 1;
    const description_count = count;
    if (view.suggestion) |text| append(&lines, &count, text, columns, if (view.ready) muted else "\x1b[2;90m");
    if (view.notice) |text| append(&lines, &count, text, columns, warning);

    const height_limit = @max(2, rows -| 1);
    const output_count = @min(count - description_count, @max(1, height_limit / 2));
    const description_room = height_limit - output_count;
    const first = if (cursor_row >= description_room) cursor_row - description_room + 1 else 0;
    const description_end = @min(description_count, first + description_room);
    const height = description_end - first + output_count;
    try w.writeAll("\r");
    if (column > 0) try w.print("\x1b[{d}C", .{column});
    try w.writeAll(reset ++ "\x1b[J");
    var row: usize = 0;
    while (row < height) : (row += 1) {
        if (row > 0) try w.writeAll("\r\n");
        const index = if (row < description_end - first) first + row else description_count + row - (description_end - first);
        const line = lines[index];
        try w.writeByte('\r');
        const marker = line.marker or (row == 0 and first > 0);
        const left = if (marker) column else line.column;
        if (left > 0) try w.print("\x1b[{d}C", .{left});
        if (marker) {
            try w.writeAll(if (view.notice != null) warning else accent);
            if (view.busy and view.turn == null and view.notice == null) {
                const phase = view.frame % 16;
                try w.writeAll(if (phase < 4 or phase >= 14) "\x1b[2m" else if (phase >= 7 and phase < 11) "\x1b[1m" else "\x1b[22m");
            }
            // Text terminals cannot transform glyphs. An eight-frame orbit
            // occupies the star's cell for exactly one revolution, then restores it.
            const orbit = [_][]const u8{ "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" };
            try w.writeAll(if (view.turn) |frame| orbit[frame % orbit.len] else if (view.icon == .lizard) "\u{f5000}" else "✦");
            try w.writeAll("  " ++ reset);
        }
        try w.writeAll(line.color);
        // Truncation is visual only; accepting always returns the full command.
        if (row + 1 == height and index + 1 < count) {
            var end = line.text.len;
            while (end > 0 and core.width(line.text[0..end]) + line.column + 1 >= columns) end = core.previous(line.text, end);
            try w.writeAll(line.text[0..end]);
            try w.writeAll("…");
        } else try w.writeAll(line.text);
        try w.writeAll(reset);
    }
    const visible_cursor = cursor_row - first;
    if (height - 1 > visible_cursor) try w.print("\x1b[{d}A", .{height - 1 - visible_cursor});
    try w.writeByte('\r');
    if (cursor_column > 0) try w.print("\x1b[{d}C", .{cursor_column});
    return .{ .row = visible_cursor, .column = cursor_column, .height = height };
}

fn append(lines: []Line, count: *usize, text: []const u8, columns: usize, color: []const u8) void {
    var start: usize = 0;
    var offset: usize = 0;
    var width: usize = 2;
    while (offset < text.len) {
        const after = core.next(text, offset);
        const cells = core.width(text[offset..after]);
        if (width + cells >= columns) {
            lines[count.*] = .{ .text = text[start..offset], .column = 2, .color = color };
            count.* += 1;
            start = offset;
            width = 2;
        }
        width += cells;
        offset = after;
    }
    lines[count.*] = .{ .text = text[start..], .column = 2, .color = color };
    count.* += 1;
}
