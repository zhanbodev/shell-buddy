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
    reveal: ?usize = null,
    input_style: core.InputStyle = .square,
};

pub const reveal_tick_ms = 20;
pub const reveal_frames: usize = 36;
pub const reveal_ms = reveal_tick_ms * reveal_frames;
pub const loading_frame_ms = 80;
const frontier_cells = 22;

const accent = "\x1b[38;2;233;191;102m";
const muted = "\x1b[90m";
const warning = "\x1b[33m";
const reset = "\x1b[0m";
const background = "\x1b[48;2;34;33;25m";
const foreground = "\x1b[38;2;229;229;231m";
const cap_color = "\x1b[38;2;34;33;25m";
const loading_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const Line = struct { text: []const u8, column: usize, color: []const u8 };
pub const Position = struct { row: usize, column: usize, height: usize };

// Animation ticks can change the marker without changing any text or layout.
// Keep only value hashes, never slices into the editor's mutable input buffers.
pub fn bodyHash(view: View, columns: usize, rows: usize) u64 {
    var hash = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hash, .{ columns, rows, view.cursor, view.ready, view.reveal, view.input_style });
    std.hash.autoHash(&hash, view.text.len);
    hash.update(view.text);
    for ([_]?[]const u8{ view.suggestion, view.notice }) |part| {
        std.hash.autoHash(&hash, part != null);
        if (part) |text| {
            std.hash.autoHash(&hash, text.len);
            hash.update(text);
        }
    }
    return hash.final();
}

pub fn renderMarker(w: *std.Io.Writer, view: View) !void {
    try w.writeAll(background);
    try w.writeAll(if (view.notice != null) warning else accent);
    if (view.busy and view.notice == null) {
        try w.writeAll(loading_frames[view.frame % loading_frames.len]);
    } else {
        if (view.turn) |turn| {
            const phase = turn * 2;
            try w.writeAll(if (phase < 4 or phase >= 14) "\x1b[2m" else if (phase >= 7 and phase < 11) "\x1b[1m" else "\x1b[22m");
        }
        try w.writeAll("\x1b[1m");
        try w.writeAll("❯");
    }
    try w.writeAll("\x1b[22m");
}

// Own one prompt row; the native editor restores its prompt on handoff.
// Reserve the last terminal cell and one body cell for the insertion cursor.
pub fn render(w: *std.Io.Writer, columns: usize, _: usize, rows: usize, view: View) !Position {
    const rounded = view.input_style == .rounded;
    const prefix: usize = if (rounded) 3 else 2;
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
    // Paint over existing cells. Erasing the whole region first makes stable
    // descriptions and streamed prefixes blink on every animation tick.
    try w.writeAll("\r" ++ reset);
    var row: usize = 0;
    while (row < height) : (row += 1) {
        if (row > 0) try w.writeAll("\r\n");
        const index = if (row < visible_description) first + row else description_count + row - visible_description;
        const line = lines[index];
        if (row < visible_description and view.reveal != null and view.text.len == 0) {
            try reveal(w, columns, view.input_style, view.reveal.?);
        } else if (row < visible_description) {
            if (rounded) {
                try w.writeAll(cap_color);
                try w.writeAll(cap(true, row, visible_description));
            }
            try w.writeAll(background ++ foreground);
            if (row == 0) {
                try renderMarker(w, view);
                // Arrow and npm-style loading frames both occupy one cell.
                try w.writeAll(foreground ++ " ");
            } else try spaces(w, 2);
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
            try w.writeAll(reset ++ "\x1b[K");
        }
        try w.writeAll(reset);
    }
    // Clear stale rows only after the new content has been painted. The last
    // cell is reserved, including when the last row is the entry animation.
    try w.print("\x1b[{d}G" ++ reset ++ "\x1b[J", .{columns});
    const visible_cursor = cursor_row - first;
    if (height - 1 > visible_cursor) try w.print("\x1b[{d}A", .{height - 1 - visible_cursor});
    try w.writeByte('\r');
    if (cursor_column > 0) try w.print("\x1b[{d}C", .{cursor_column});
    return .{ .row = visible_cursor, .column = cursor_column, .height = height };
}

// Paint only the empty entry state. Input always takes priority over animation.
// ECH fills the solid region without moving the cursor; absolute positioning
// before each edge glyph avoids wrapping if a split is resized mid-frame.
fn reveal(w: *std.Io.Writer, columns: usize, style: core.InputStyle, frame: usize) !void {
    const rounded = style == .rounded;
    const origin: usize = @intFromBool(rounded);
    const prefix = origin + 2;
    const end = columns - 1 - origin;
    const phase: usize = @min(frame, reveal_frames);
    const hint = "What do you need?";
    const size = @min(hint.len, end - prefix - 1);
    // Ease in, surge through the middle, then settle. Keep the particle plume
    // visible during the sweep instead of spending most frames near the end.
    const progress = phase * phase * (3 * reveal_frames - 2 * phase);
    const front = prefix + (end - prefix) * progress / (reveal_frames * reveal_frames * reveal_frames);
    if (rounded) try w.writeAll(cap_color ++ "\u{f5001}");
    const protected_end = prefix + size;
    // ECH and particles must never erase or overwrite the placeholder. Change
    // its background by drawing the same glyph in place, without a blank pass.
    if (front > protected_end) try w.print("\x1b[{d}G" ++ background ++ "\x1b[{d}X", .{ protected_end + 1, front - protected_end });
    try w.print("\x1b[{d}G" ++ reset ++ "\x1b[K", .{@max(front, protected_end) + 1});
    try wake(w, @max(protected_end, front -| 6), @max(protected_end, front), phase);
    try frontier(w, front, @min(end, front + frontier_cells), phase, protected_end);
    try w.print("\x1b[{d}G" ++ background ++ accent ++ "\x1b[1m❯\x1b[22m" ++ foreground ++ " ", .{origin + 1});
    for (hint[0..size], 0..) |c, i| {
        // Text is readable from the first frame, including beyond the frontier.
        try w.writeAll(if (prefix + i < front) background ++ muted else reset ++ muted);
        try w.print("\x1b[{d}G{c}", .{ prefix + i + 1, c });
    }
    if (rounded and front == end) {
        try w.print("\x1b[{d}G" ++ reset ++ cap_color ++ "\u{f5002}", .{columns - 1});
    }
    try w.writeAll(reset ++ "\r");
}

// A short curling afterimage runs inside the revealed background, connecting
// the fine sparks to the moving core without changing the bar's fill color.
fn wake(w: *std.Io.Writer, start: usize, end: usize, phase: usize) !void {
    const left = [4]u3{ 0, 1, 2, 6 };
    const right = [4]u3{ 3, 4, 5, 7 };
    for (start..end, 0..) |column, i| {
        const y = (phase / 2 + i) % 4;
        var mask = @as(u8, 1) << left[y];
        if (i >= 2) mask |= @as(u8, 1) << right[(y + 1) % 4];
        if (i >= 4) mask |= @as(u8, 1) << left[(y + 2) % 4];
        try w.writeAll(background ++ accent);
        try w.writeAll(if (i < 4) "\x1b[2m" else "\x1b[22m");
        var glyph: [4]u8 = undefined;
        const size = std.unicode.utf8Encode(0x2800 + @as(u21, mask), &glyph) catch unreachable;
        try w.print("\x1b[{d}G{s}", .{ column + 1, glyph[0..size] });
    }
    try w.writeAll(reset);
}

// The first two particle cells overlap the solid fill, so the colored front
// remains attached with no blank column between it and the background.
// Only reveal() paints particles; the steady input always uses a plain fill.
fn frontier(w: *std.Io.Writer, start: usize, end: usize, phase: usize, protected_end: usize) !void {
    const width = end - start;
    if (width == 0) return;
    const plume = frontierParticles(width, phase);
    for (plume.masks[0..width], 0..) |mask, i| {
        if (mask == 0 or start + i < protected_end) continue;
        try w.writeAll(reset ++ accent);
        try w.writeAll(if (plume.hot[i]) "\x1b[1m" else if (plume.lit[i]) "\x1b[22m" else "\x1b[2m");
        if (i < 2) try w.writeAll(background);
        var glyph: [4]u8 = undefined;
        const size = std.unicode.utf8Encode(0x2800 + @as(u21, mask), &glyph) catch unreachable;
        try w.print("\x1b[{d}G{s}", .{ start + i + 1, glyph[0..size] });
    }
    try w.writeAll(reset);
}

const Plume = struct {
    masks: [frontier_cells]u8 = @splat(0),
    lit: [frontier_cells]bool = @splat(false),
    hot: [frontier_cells]bool = @splat(false),

    fn dot(self: *Plume, width: usize, x: usize, y: usize, lit: bool, hot: bool) void {
        if (x >= width * 2 or y >= 4) return;
        const bits = [2][4]u3{ .{ 0, 1, 2, 6 }, .{ 3, 4, 5, 7 } };
        self.masks[x / 2] |= @as(u8, 1) << bits[x % 2][y];
        self.lit[x / 2] = self.lit[x / 2] or lit;
        self.hot[x / 2] = self.hot[x / 2] or hot;
    }
};

// Staggered lifetimes produce continuous emission. Different launch speeds,
// curved paths, clustered heads and fading streaks make the plume breathe.
// Every position is analytic; no heap state, random I/O or animation worker.
fn frontierParticles(width: usize, phase: usize) Plume {
    var plume: Plume = .{};
    if (width == 0) return plume;
    const beat = phase % 18;
    const swell = if (beat <= 9) beat else 18 - beat;
    const reach = @max(1, width * (27 + swell) / 36);
    for (0..72) |id| {
        if (beat >= 6 and id % 3 == 0) continue;
        var seed: u32 = @intCast(id + 1);
        seed *%= 0x9e3779b9;
        seed ^= seed >> 16;
        const life: usize = 14 + seed % 16;
        const age = (phase + (seed >> 4) % life) % life;
        const speed = 8 + (seed >> 8) % 21;
        const x = age * speed / 16 + age * age * ((seed >> 15) & 1) / 64;
        if (x >= reach * 2) continue;
        const launch = @as(i32, @intCast((seed >> 19) % 49)) - 24;
        const arc = launch * @as(i32, @intCast(age * (life - age) * 2 / life));
        const height = 384 + @as(i32, @intCast((seed >> 16) & 1)) * 256 + arc;
        const y: usize = @intCast(@divTrunc(std.math.clamp(height, 0, 1023), 256));
        const lit = age * 3 < life * 2;
        const hot = age < 4;
        plume.dot(width, x, y, lit, hot);
        if (id % 9 == 0 and age < life / 2) {
            // A few larger heads give the fine dust a visible size contrast.
            plume.dot(width, x + 1, y, true, true);
            plume.dot(width, x, y ^ 1, true, true);
            plume.dot(width, x + 1, y ^ 1, true, true);
        }
        if (id % 4 == 0) {
            if (x > 0) plume.dot(width, x - 1, y, false, false);
            if (x > 1) plume.dot(width, x - 2, y, false, false);
        }
    }
    // Rotate the emitter instead of pinning two full, static dot columns.
    const curl = phase % 4;
    plume.dot(width, 0, curl, true, true);
    plume.dot(width, 1, (curl + 1) % 4, true, true);
    plume.dot(width, 0, (curl + 2) % 4, true, true);
    plume.dot(width, 2, (curl + 3) % 4, true, false);
    return plume;
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

test "particle frontier stays attached, moves, and clips to its bounded band" {
    var emitter_changes = false;
    for (1..frontier_cells + 1) |width| {
        for (0..reveal_frames) |phase| {
            const plume = frontierParticles(width, phase);
            try std.testing.expect(plume.masks[0] != 0);
            emitter_changes = emitter_changes or plume.masks[0] != 0xff;
            for (plume.masks[width..]) |mask| try std.testing.expectEqual(@as(u8, 0), mask);
        }
    }
    try std.testing.expect(emitter_changes);
    const first = frontierParticles(frontier_cells, 0);
    const later = frontierParticles(frontier_cells, 9);
    try std.testing.expect(!std.mem.eql(u8, &first.masks, &later.masks));
    var a: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer a.deinit();
    try frontier(&a.writer, 30, 44, 0, 0);
    try std.testing.expect(std.mem.find(u8, a.written(), background ++ "\x1b[31G") != null);
}

test "completed and busy inputs have a full background without particle glyphs" {
    for ([_]bool{ false, true }) |busy| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        const p = try render(&out.writer, 80, 0, 24, .{ .text = "当前路径", .cursor = 12, .busy = busy });
        var chars = std.unicode.Utf8View.initUnchecked(out.written()).iterator();
        var dots: usize = 0;
        while (chars.nextCodepoint()) |cp| if (cp >= 0x2800 and cp <= 0x28ff) {
            dots += 1;
        };
        try std.testing.expectEqual(@as(usize, if (busy) 1 else 0), dots);
        try std.testing.expect(std.mem.find(u8, out.written(), background) != null);
        try std.testing.expectEqual(@as(usize, 10), p.column);
    }
}

test "npm loading frames occupy one cell and preserve arrow cursor positions" {
    for ([_]core.InputStyle{ .square, .rounded }) |style| {
        for (loading_frames, 0..) |glyph, frame| {
            try std.testing.expectEqual(@as(usize, 1), core.width(glyph));
            var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            const p = try render(&out.writer, 80, 0, 24, .{ .text = "测试服务", .cursor = 12, .busy = true, .frame = frame, .input_style = style });
            try std.testing.expect(std.mem.find(u8, out.written(), glyph) != null);
            try std.testing.expect(std.mem.find(u8, out.written(), "❯") == null);
            try std.testing.expectEqual(@as(usize, if (style == .rounded) 11 else 10), p.column);
        }
    }
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = try render(&out.writer, 80, 0, 24, .{ .text = "测试服务", .cursor = 12, .notice = "Request failed", .busy = true });
    try std.testing.expect(std.mem.find(u8, out.written(), "❯") != null);
    for (loading_frames) |glyph| try std.testing.expect(std.mem.find(u8, out.written(), glyph) == null);
}

test "body hash separates animation ticks from text and viewport changes" {
    var view: View = .{ .text = "测试服务", .cursor = 12, .busy = true, .suggestion = "touch " };
    const key = bodyHash(view, 80, 24);
    view.frame = 7;
    view.turn = 3;
    try std.testing.expectEqual(key, bodyHash(view, 80, 24));
    view.suggestion = "touch 'hello.txt'";
    try std.testing.expect(key != bodyHash(view, 80, 24));
    view.suggestion = "touch ";
    try std.testing.expect(key != bodyHash(view, 40, 24));
    view.cursor = 0;
    try std.testing.expect(key != bodyHash(view, 80, 24));
}

test "prompt marker is bold and input starts after one space" {
    for ([_]core.InputStyle{ .square, .rounded }) |style| {
        for ([_]?usize{ null, 0 }) |frame| {
            var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            const p = try render(&out.writer, 80, 0, 24, .{ .text = "", .cursor = 0, .reveal = frame, .input_style = style });
            try std.testing.expect(std.mem.find(u8, out.written(), "\x1b[1m❯\x1b[22m") != null);
            try std.testing.expectEqual(@as(usize, if (style == .rounded) 3 else 2), p.column);
        }
    }
}
