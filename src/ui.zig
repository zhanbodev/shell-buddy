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
};

const accent = "\x1b[36m";
const muted = "\x1b[90m";
const warning = "\x1b[33m";
const reset = "\x1b[0m";

// Render only the shell's current input region. Leave the final terminal cell
// empty to avoid wrapping. The display marker is never part of the input.
pub fn render(w: *std.Io.Writer, columns: usize, column: usize, view: View) !void {
    const room = columns -| column -| 1;
    const prefix = @min(2, room);
    const available = room -| prefix;
    var start: usize = 0;
    while (start < view.cursor and core.width(view.text[start..view.cursor]) > available) start = core.next(view.text, start);
    var end = start;
    var used: usize = 0;
    while (end < view.text.len) {
        const after = core.next(view.text, end);
        const width = core.width(view.text[end..after]);
        if (used + width > available) break;
        used += width;
        end = after;
    }
    try w.writeByte('\r');
    if (column > 0) try w.print("\x1b[{d}C", .{column});
    try w.writeAll(reset ++ "\x1b[K");
    const tone = if (view.notice != null) warning else accent;
    try w.writeAll(tone);
    if (view.busy and view.notice == null) {
        // A slow, theme-compatible breath; keep the glyph and cursor fixed.
        const phase = view.frame % 16;
        try w.writeAll(if (phase < 4 or phase >= 14) "\x1b[2m" else if (phase >= 7 and phase < 11) "\x1b[1m" else "\x1b[22m");
    }
    if (prefix > 0) try w.writeAll("✦");
    if (prefix > 1) try w.writeByte(' ');
    try w.writeAll(reset);
    try w.writeAll(view.text[start..end]);
    if (end == view.text.len and available >= used + 3 and (view.suggestion != null or view.notice != null)) {
        var budget = available - used - 2;
        try w.writeAll("  ");
        if (view.suggestion) |suggestion| {
            const complete = try tail(w, suggestion, &budget, if (view.ready) muted else "\x1b[2;90m");
            if (complete) {
                if (view.notice) |notice| {
                    if (budget >= 5) {
                        try w.writeAll("  ");
                        budget -= 2;
                        _ = try tail(w, notice, &budget, warning);
                    }
                }
            }
        } else {
            _ = try tail(w, view.notice.?, &budget, warning);
        }
    }
    try w.writeAll(reset);
    try w.print("\r\x1b[{d}C", .{column + prefix + core.width(view.text[start..view.cursor])});
}

fn tail(w: *std.Io.Writer, text: []const u8, budget: *usize, color: []const u8) !bool {
    const full = core.width(text) <= budget.*;
    const limit = budget.* -| @intFromBool(!full);
    var end: usize = 0;
    var used: usize = 0;
    while (end < text.len) {
        const next = core.next(text, end);
        const width = core.width(text[end..next]);
        if (used + width > limit) break;
        used += width;
        end = next;
    }
    try w.writeAll(color);
    try w.writeAll(text[0..end]);
    if (!full and budget.* > 0) {
        try w.writeAll("…");
        used += 1;
    }
    try w.writeAll(reset);
    budget.* -= used;
    return full;
}
