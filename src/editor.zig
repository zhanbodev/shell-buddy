const std = @import("std");
const core = @import("core.zig");
const rules = @import("rules.zig");
const cache = @import("cache.zig");
const config = @import("config.zig");
const model = @import("model.zig");
const terminal = @import("terminal.zig");
const control = @import("control.zig");
const credentials = @import("credentials.zig");
const ui = @import("ui.zig");

pub const Result = struct { action: core.Action, text: []const u8 };
pub fn now(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

pub fn makeJob(init: std.process.Init, cfg: config.Config, shell: core.Shell, cwd: []const u8) !model.Job {
    const profile = cfg.profile orelse return error.NoModel;
    const secret = try credentials.resolve(init.arena.allocator(), init.io, init.environ_map, cfg.credentials_path, cfg.name, profile.api_key_env);
    return .{ .io = init.io, .allocator = init.gpa, .profile = profile, .api_key = secret, .shell = shell, .cwd = cwd, .max_tokens = cfg.max_tokens };
}

pub const Generated = struct { text: []const u8, first_token_ms: ?i64, complete_ms: i64 };
pub fn generate(init: std.process.Init, cfg: config.Config, shell: core.Shell, cwd: []const u8, text: []const u8) !Generated {
    if (!core.validText(text)) return error.InvalidIntent;
    const observed = try control.read(init.gpa, init.io, cfg.state_path);
    if (!observed.enabled) return error.Stopped;
    var job = try makeJob(init, cfg, shell, cwd);
    @memcpy(job.input[0..text.len], text);
    job.input_len = text.len;
    var future = try init.io.concurrent(model.Job.run, .{&job});
    defer future.cancel(init.io);
    const start = now(init.io);
    var checked_at = start;
    while (true) {
        const snapshot = job.snapshot();
        if (snapshot.done or now(init.io) - checked_at >= 100) {
            const state = try control.read(init.gpa, init.io, cfg.state_path);
            if (!state.enabled) return error.Stopped;
            if (state.revision != observed.revision) return error.ConfigurationReloaded;
            checked_at = now(init.io);
        }
        if (snapshot.done) {
            future.await(init.io);
            if (snapshot.failure) |err| return err;
            const text_result = try core.command(snapshot.bytes[0..snapshot.len]);
            return .{ .text = try init.arena.allocator().dupe(u8, text_result), .first_token_ms = snapshot.first_token_ms, .complete_ms = snapshot.elapsed_ms };
        }
        if (now(init.io) - start >= cfg.timeout_ms) return error.Timeout;
        try init.io.sleep(.fromMilliseconds(5), .awake);
    }
}

pub fn edit(init: std.process.Init, initial_cfg: config.Config, shell: core.Shell, cwd: []const u8, initial: []const u8, inline_left: ?[]const u8) !Result {
    const io = init.io;
    const a = init.arena.allocator();
    var observed = try control.read(init.gpa, io, initial_cfg.state_path);
    if (!observed.enabled) return .{ .action = .cancel, .text = initial };
    var settings: std.heap.ArenaAllocator = .init(init.gpa);
    defer settings.deinit();
    // Read after the control revision so a concurrent restart cannot be missed.
    var cfg = try config.load(settings.allocator(), io, init.environ_map);
    const original = core.intent(initial);
    if (original.len > core.max_command or (original.len > 0 and !core.validText(original))) return error.InvalidIntent;
    var text: [core.max_command]u8 = undefined;
    var len = original.len;
    @memcpy(text[0..len], original);
    var cursor = len;
    var term = try terminal.Terminal.open(io);
    defer term.close();
    if (inline_left) |left| {
        if (left.len > core.max_command or (left.len > 0 and !core.validText(left))) return error.InvalidIntent;
        try term.beginInline(core.width(left));
    }
    try term.write("\x1b[?2004h");
    const records = cache.load(a, io, cfg.cache_path) catch &.{};
    var scratch: std.heap.ArenaAllocator = .init(init.gpa);
    defer scratch.deinit();
    var candidates: core.Candidates = .{};
    var changed = true;
    var revision: u64 = 0;
    var edited_at = now(io);
    var requested = false;
    var status: ?[]const u8 = null;
    var job: model.Job = undefined;
    var future: ?std.Io.Future(void) = null;
    defer if (future) |*f| f.cancel(io);
    var started_at: i64 = 0;
    var decoder: terminal.Decoder = .{};
    var escape_at: i64 = 0;
    var pasting = false;
    var last_hash: ?u64 = null;
    var checked_at = now(io);
    var turn_started: ?i64 = null;
    var replacing = false;

    while (true) {
        if (term.wasInterrupted()) return .{ .action = .cancel, .text = "" };
        if (now(io) - checked_at >= 100) {
            const state = try control.read(init.gpa, io, cfg.state_path);
            checked_at = now(io);
            if (!state.enabled) return .{ .action = .cancel, .text = try std.fmt.allocPrint(a, "// {s}", .{text[0..len]}) };
            if (state.revision != observed.revision) {
                observed = state;
                var pending: std.heap.ArenaAllocator = .init(init.gpa);
                const next = config.load(pending.allocator(), io, init.environ_map) catch |err| {
                    pending.deinit();
                    return err;
                };
                if (next.problem) |problem| {
                    status = try a.dupe(u8, problem);
                    pending.deinit();
                } else {
                    if (future) |*f| f.cancel(io);
                    future = null;
                    settings.deinit();
                    settings = pending;
                    cfg = next;
                    candidates = .{};
                    replacing = false;
                    turn_started = null;
                    revision +%= 1;
                    changed = true;
                    requested = false;
                    edited_at = now(io);
                }
            }
        }
        if (changed) {
            changed = false;
            _ = scratch.reset(.retain_capacity);
            const key = cache.key(shell, cwd, text[0..len], cfg);
            if (cache.find(records, &key)) |hit| {
                _ = candidates.add(hit);
            } else if (try rules.predict(scratch.allocator(), shell, text[0..len])) |hit| {
                _ = candidates.add(hit);
            }
            status = null;
        }
        var preview: model.Snapshot = .{};
        if (future) |*f| {
            preview = job.snapshot();
            if (preview.done) {
                f.await(io);
                future = null;
                replacing = false;
                if (preview.revision == revision) {
                    if (preview.failure) |err| {
                        status = model.message(err);
                    } else {
                        const ready = core.command(preview.bytes[0..preview.len]) catch null;
                        if (ready) |value| {
                            status = if (candidates.add(value)) null else "No alternative candidate; press Tab to retry";
                        } else status = "Invalid single-line command; press Tab to retry";
                    }
                }
                preview = .{};
            } else if (now(io) - started_at >= cfg.timeout_ms) {
                f.cancel(io);
                future = null;
                replacing = false;
                status = model.message(error.Timeout);
                preview = .{};
            }
        }
        if (!pasting and core.intent(text[0..len]).len > 0 and candidates.len == 0 and !requested and now(io) - edited_at >= cfg.debounce_ms) {
            requested = true;
            if (cfg.profile == null) {
                status = cfg.problem orelse "Model not configured; local rules are available";
            } else {
                job = makeJob(init, cfg, shell, cwd) catch |err| {
                    status = model.message(err);
                    try draw(&term, .{ .text = text[0..len], .cursor = cursor, .notice = status, .icon = cfg.icon }, &last_hash);
                    continue;
                };
                @memcpy(job.input[0..len], text[0..len]);
                job.input_len = len;
                job.state.revision = revision;
                started_at = now(io);
                future = try io.concurrent(model.Job.run, .{&job});
                status = null;
            }
        }
        const turn: ?usize = if (turn_started) |start| value: {
            const elapsed = now(io) - start;
            if (elapsed < 480) break :value @intCast(@divTrunc(elapsed, 60));
            turn_started = null;
            break :value null;
        } else null;
        const suggestion = (if (replacing) @as(?[]const u8, null) else candidates.get()) orelse p: {
            if (future != null and preview.len > 0) {
                const raw = std.mem.trim(u8, preview.bytes[0..preview.len], " \t\r\n");
                if (core.validText(raw)) break :p raw;
            }
            break :p null;
        };
        try draw(&term, .{
            .text = text[0..len],
            .cursor = cursor,
            .suggestion = if (turn != null) null else suggestion,
            .notice = if (turn != null) null else status,
            .ready = !replacing and candidates.get() != null,
            .turn = turn,
            .icon = cfg.icon,
            .busy = future != null,
        }, &last_hash);

        const expired = escape_at != 0 and now(io) - escape_at >= 40;
        const key = decoder.take(expired) orelse {
            var input: [256]u8 = undefined;
            const n = try term.read(&input, if (future != null) 10 else 20);
            if (n > 0) {
                try decoder.push(input[0..n]);
                escape_at = now(io);
            }
            continue;
        };
        var modified = false;
        if (pasting) {
            switch (key) {
                .paste_end => {
                    pasting = false;
                    edited_at = now(io);
                },
                .text => |value| {
                    modified = insert(&text, &len, &cursor, value);
                },
                .enter, .tab => {
                    modified = insert(&text, &len, &cursor, " ");
                },
                else => {},
            }
        } else {
            switch (key) {
                .text => |value| {
                    modified = insert(&text, &len, &cursor, value);
                },
                .left => {
                    cursor = core.previous(text[0..len], cursor);
                },
                .right => {
                    cursor = core.next(text[0..len], cursor);
                },
                .home => {
                    cursor = 0;
                },
                .end => {
                    cursor = len;
                },
                .backspace => if (cursor > 0) {
                    const before = core.previous(text[0..len], cursor);
                    remove(&text, &len, before, cursor);
                    cursor = before;
                    modified = true;
                },
                .delete => if (cursor < len) {
                    remove(&text, &len, cursor, core.next(text[0..len], cursor));
                    modified = true;
                },
                .clear => {
                    remove(&text, &len, 0, cursor);
                    cursor = 0;
                    modified = true;
                },
                .word => if (cursor > 0) {
                    var before = cursor;
                    while (before > 0 and text[before - 1] == ' ') before -= 1;
                    while (before > 0 and text[before - 1] != ' ') before = core.previous(text[0..len], before);
                    remove(&text, &len, before, cursor);
                    cursor = before;
                    modified = true;
                },
                .paste_start => {
                    pasting = true;
                },
                .paste_end, .ignore => {},
                .escape => return .{ .action = .cancel, .text = if (len == 0) "" else try std.fmt.allocPrint(a, "// {s}", .{text[0..len]}) },
                .cancel => return .{ .action = .cancel, .text = "" },
                .enter, .execute => {
                    // Never accept a hidden candidate during a Tab refresh.
                    if (replacing or turn != null) continue;
                    if (candidates.get()) |ready| {
                        const state = try control.read(init.gpa, io, cfg.state_path);
                        if (!state.enabled) return .{ .action = .cancel, .text = try std.fmt.allocPrint(a, "// {s}", .{text[0..len]}) };
                        if (state.revision != observed.revision) {
                            checked_at = 0;
                            continue;
                        }
                        const value = try a.dupe(u8, ready);
                        const cache_key = cache.key(shell, cwd, text[0..len], cfg);
                        // Cache errors cannot prevent accepting a command.
                        cache.save(a, io, cfg.cache_path, &cache_key, value) catch {};
                        return .{ .action = if (key == .execute) .execute else .accept, .text = value };
                    }
                },
                .tab => {
                    if (core.intent(text[0..len]).len == 0) continue;
                    turn_started = now(io);
                    status = null;
                    if (future != null) replacing = true;
                    if (future == null) {
                        if (candidates.len > 0 and candidates.current + 1 < candidates.len) {
                            candidates.current += 1;
                        } else if (cfg.profile == null) {
                            status = cfg.problem orelse "Configure a model to generate alternatives";
                        } else {
                            job = makeJob(init, cfg, shell, cwd) catch |err| {
                                status = model.message(err);
                                continue;
                            };
                            @memcpy(job.input[0..len], text[0..len]);
                            job.input_len = len;
                            if (candidates.get()) |current| {
                                @memcpy(job.avoid[0..current.len], current);
                                job.avoid_len = current.len;
                            }
                            job.state.revision = revision;
                            started_at = now(io);
                            requested = true;
                            future = try io.concurrent(model.Job.run, .{&job});
                            replacing = true;
                            status = null;
                        }
                    }
                },
            }
        }
        if (modified) {
            replacing = false;
            turn_started = null;
            if (future) |*f| {
                f.cancel(io);
                future = null;
            }
            candidates.len = 0;
            candidates.current = 0;
            changed = true;
            requested = false;
            revision +%= 1;
            edited_at = now(io);
        }
    }
}

fn insert(text: *[core.max_command]u8, len: *usize, cursor: *usize, value: []const u8) bool {
    if (len.* + value.len > text.len) return false;
    std.mem.copyBackwards(u8, text[cursor.* + value.len .. len.* + value.len], text[cursor.*..len.*]);
    @memcpy(text[cursor.*..][0..value.len], value);
    cursor.* += value.len;
    len.* += value.len;
    return true;
}
fn remove(text: *[core.max_command]u8, len: *usize, from: usize, to: usize) void {
    std.mem.copyForwards(u8, text[from .. len.* - (to - from)], text[to..len.*]);
    len.* -= to - from;
}

fn draw(term: *terminal.Terminal, view: ui.View, last: *?u64) !void {
    var buffer: [20000]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    var frame = view;
    if (view.busy) frame.frame = @intCast(@divTrunc(now(term.io), 120));
    const position = try ui.render(&w, term.columns(), term.lineColumn(), term.rows(), frame);
    const hash = std.hash.Wyhash.hash(0, w.buffered());
    if (last.* == null or last.*.? != hash) {
        if (term.display_row > 0) {
            var movement: [32]u8 = undefined;
            try term.write(try std.fmt.bufPrint(&movement, "\x1b[{d}A", .{term.display_row}));
        }
        try term.write(w.buffered());
        term.display_row = position.row;
        last.* = hash;
    }
}
