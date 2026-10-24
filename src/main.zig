const std = @import("std");
const core = @import("core.zig");
const rules = @import("rules.zig");
const config = @import("config.zig");
const cache = @import("cache.zig");
const editor = @import("editor.zig");
const control = @import("control.zig");
const builtin = @import("builtin");
const setup = @import("setup.zig");
const model = @import("model.zig");

pub fn main(init: std.process.Init) void {
    const code = run(init) catch |err| {
        var buf: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "shell-buddy: {s}\n", .{@errorName(err)}) catch "shell-buddy: error\n";
        std.Io.File.stderr().writeStreamingAll(init.io, message) catch {};
        std.process.exit(1);
    };
    std.process.exit(code);
}

fn run(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 1 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "help")) {
        try output(init.io, "usage: shell-buddy <command> [<args>]\n\n" ++
            "Set up and control Shell Buddy\n" ++
            "   init [<shell>]     Configure models, or initialize shell integration\n" ++
            "   start              Enable command suggestions\n" ++
            "   stop               Disable suggestions and cancel active requests\n" ++
            "   restart            Reload configuration and enable suggestions\n" ++
            "   status             Show state and configuration path\n\n" ++
            "Configure and inspect models\n" ++
            "   llm <profile>      Select an LLM profile\n" ++
            "   config-example     Print an example configuration\n" ++
            "   doctor             Check configuration\n" ++
            "   cache-clear        Clear accepted command cache\n\n" ++
            "Generate commands\n" ++
            "   suggest            Print a suggestion without executing it\n" ++
            "   edit               Open the inline editor (shell adapter interface)\n\n" ++
            "Run 'shell-buddy <command> --help' for usage.\n");
        return 0;
    }
    if (std.mem.eql(u8, args[1], "--version")) {
        try output(init.io, @embedFile("version.txt"));
        return 0;
    }
    if (args.len == 3 and std.mem.eql(u8, args[2], "--help")) {
        if (std.mem.eql(u8, args[1], "llm")) {
            try output(init.io, profile_help);
            return 0;
        }
        if (std.mem.eql(u8, args[1], "init")) {
            try output(init.io, setup.help ++ "\nShell integration:\n" ++
                "  - bash        Bash 5 or later\n" ++
                "  - zsh         Zsh 5.8 or later\n" ++
                "  - powershell  PowerShell 7.4 or later with PSReadLine 2.3.6 or later\n");
            return 0;
        }
        if (std.mem.eql(u8, args[1], "suggest") or std.mem.eql(u8, args[1], "edit")) {
            try output(init.io, if (std.mem.eql(u8, args[1], "suggest"))
                "usage: shell-buddy suggest --shell <shell> --intent <description> [<options>]\n\n" ++
                    "  --generate  Request the selected model instead of local predictions\n" ++
                    "  --timings   Print model latency metrics to stderr\n"
            else
                "usage: shell-buddy edit --shell <shell> [--initial <description>]\n");
            return 0;
        }
        const commands = [_][]const u8{ "start", "stop", "restart", "status", "doctor", "cache-clear", "config-example" };
        for (commands) |command| if (std.mem.eql(u8, args[1], command)) {
            try output(init.io, try std.fmt.allocPrint(a, "usage: shell-buddy {s}\n", .{command}));
            return 0;
        };
        return error.UnknownCommand;
    }
    if (std.mem.eql(u8, args[1], "config-example")) {
        try output(init.io, config.example);
        return 0;
    }
    if (std.mem.eql(u8, args[1], "init") and args.len == 2) {
        return setup.run(init);
    }
    if (std.mem.eql(u8, args[1], "init")) {
        if (args.len != 3) return error.ExpectedShell;
        const shell = std.meta.stringToEnum(core.Shell, args[2]) orelse return error.UnsupportedShell;
        try config.ensure(a, init.io, init.environ_map);
        const binary = try std.process.executablePathAlloc(init.io, a);
        const quoted = try core.quote(a, shell, binary);
        // The adapter must keep working when init was invoked by a relative
        // path and the executable is absent from PATH, including after cd.
        try output(init.io, try std.fmt.allocPrint(a, "{s}{s}\n", .{
            if (shell == .powershell) "$env:SHELL_BUDDY_BIN = " else "export SHELL_BUDDY_BIN=", quoted,
        }));
        try output(init.io, switch (shell) {
            .bash => @embedFile("shell/completion.bash"),
            .zsh => @embedFile("shell/completion.zsh"),
            .powershell => @embedFile("shell/completion.ps1"),
        });
        try output(init.io, switch (shell) {
            .bash => @embedFile("shell/bash.bash"),
            .zsh => @embedFile("shell/zsh.zsh"),
            .powershell => @embedFile("shell/powershell.ps1"),
        });
        return 0;
    }
    if (std.mem.eql(u8, args[1], "llm")) {
        if (args.len > 3 or (args.len == 3 and !config.validSelection(args[2]))) {
            try std.Io.File.stderr().writeStreamingAll(init.io, profile_help);
            return 1;
        }
        const cfg = if (args.len == 3) try config.select(a, init.io, init.environ_map, args[2]) else try config.load(a, init.io, init.environ_map);
        if (try configurationError(init, cfg)) return 1;
        if (args.len == 3) _ = try control.update(a, init.io, cfg.state_path, null);
        try output(init.io, try std.fmt.allocPrint(a, "LLM profile: {s}\n", .{try profileLabel(a, cfg)}));
        if (args.len == 2) try output(init.io, "\n" ++ profile_help);
        return 0;
    }
    const start = std.mem.eql(u8, args[1], "start");
    const restart = std.mem.eql(u8, args[1], "restart");
    const stop = std.mem.eql(u8, args[1], "stop");
    const status = std.mem.eql(u8, args[1], "status");
    if (start or restart or stop or status) {
        if (args.len != 2) return error.UnexpectedArgument;
        if (start or restart) try config.ensure(a, init.io, init.environ_map);
        const cfg = if (stop) try config.paths(a, init.environ_map) else try config.load(a, init.io, init.environ_map);
        if ((start or restart) and try configurationError(init, cfg)) return 1;
        const state = if (status) try control.read(a, init.io, cfg.state_path) else try control.update(a, init.io, cfg.state_path, !stop);
        try output(init.io, try std.fmt.allocPrint(a, "Shell Buddy {s}\nconfig: {s}\nprofile: {s}\n", .{
            if (status) (if (state.enabled) "enabled" else "stopped") else if (stop) "stopped" else if (restart) "restarted; configuration reloaded" else "enabled",
            cfg.config_path,
            try profileLabel(a, cfg),
        }));
        if ((start or restart) and init.environ_map.get("SHELL_BUDDY_SHELL") == null) try integrationHint(init);
        return 0;
    }
    const cfg = try config.load(a, init.io, init.environ_map);
    if (std.mem.eql(u8, args[1], "doctor")) {
        const state = try control.read(a, init.io, cfg.state_path);
        const text = try std.fmt.allocPrint(a, "config: {s}\ncache: {s}\nprofile: {s}\nmodel: {s}\nmax_tokens: {d}\nicon: {s}\nthinking: disabled\nenabled: {s}\nshell integration: {s}\nstatus: {s}\n", .{
            cfg.config_path, cfg.cache_path, cfg.name, if (cfg.profile) |p| p.model else "unconfigured", cfg.max_tokens, @tagName(cfg.icon), if (state.enabled) "true" else "false", init.environ_map.get("SHELL_BUDDY_SHELL") orelse "not loaded", cfg.problem orelse "ok",
        });
        try output(init.io, text);
        return if (cfg.problem == null) 0 else 1;
    }
    if (std.mem.eql(u8, args[1], "cache-clear")) {
        const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{cfg.cache_path});
        const lock = std.Io.Dir.cwd().openFile(init.io, lock_path, .{ .mode = .read_write, .lock = .exclusive }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer lock.close(init.io);
        std.Io.Dir.cwd().deleteFile(init.io, cfg.cache_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return 0;
    }
    const is_edit = std.mem.eql(u8, args[1], "edit");
    if (!is_edit and !std.mem.eql(u8, args[1], "suggest")) return error.UnknownCommand;
    var shell: ?core.Shell = null;
    var initial: []const u8 = "";
    var generate = false;
    var timings = false;
    var inline_left: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--generate")) {
            generate = true;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--timings")) {
            timings = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingArgument;
        const option = args[i];
        i += 1;
        if (std.mem.eql(u8, option, "--shell")) {
            shell = std.meta.stringToEnum(core.Shell, args[i]) orelse return error.UnsupportedShell;
        } else if (std.mem.eql(u8, option, "--initial") or std.mem.eql(u8, option, "--intent")) {
            initial = args[i];
        } else if (std.mem.eql(u8, option, "--inline-left")) {
            inline_left = args[i];
        } else return error.UnknownOption;
    }
    const selected = shell orelse return error.ExpectedShell;
    const cwd = try std.process.currentPathAlloc(init.io, a);
    if (is_edit) {
        const result = try editor.edit(init, cfg, selected, cwd, initial, inline_left);
        try output(init.io, result.text);
        return @intCast(@backingInt(result.action));
    }
    if (!(try control.read(init.gpa, init.io, cfg.state_path)).enabled) return error.Stopped;
    const text = core.intent(initial);
    if (!core.validText(text)) return error.InvalidIntent;
    if (!generate) {
        const records = cache.load(a, init.io, cfg.cache_path) catch &.{};
        const key = cache.key(selected, cwd, text, cfg);
        if (cache.find(records, &key)) |hit| {
            try output(init.io, hit);
            try output(init.io, "\n");
            return 0;
        }
        if (try rules.predict(a, selected, text)) |hit| {
            try output(init.io, hit);
            try output(init.io, "\n");
            return 0;
        }
    }
    const value = editor.generate(init, cfg, selected, cwd, text) catch |err| {
        try std.Io.File.stderr().writeStreamingAll(init.io, try std.fmt.allocPrint(a, "shell-buddy: {s} ({s})\n", .{ model.message(err), @errorName(err) }));
        return 1;
    };
    try output(init.io, value.text);
    try output(init.io, "\n");
    if (timings) {
        const metrics = try std.json.Stringify.valueAlloc(a, .{ .first_token_ms = value.first_token_ms, .complete_ms = value.complete_ms }, .{});
        try std.Io.File.stderr().writeStreamingAll(init.io, metrics);
        try std.Io.File.stderr().writeStreamingAll(init.io, "\n");
    }
    return 0;
}

const profile_help = "usage: shell-buddy llm <profile>\n\n" ++
    "  - local  Use the local model service\n" ++
    "  - cloud  Use the cloud model service\n\n" ++
    "Saves the default profile and reloads active editors.\n";

fn integrationHint(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const shell: core.Shell = if (builtin.os.tag == .windows) .powershell else if (init.environ_map.get("SHELL")) |value|
        (std.meta.stringToEnum(core.Shell, std.fs.path.basename(value)) orelse .zsh)
    else
        .zsh;
    const binary = try std.process.executablePathAlloc(init.io, a);
    const quoted = try core.quote(a, shell, binary);
    try output(init.io, "\nShell integration is not loaded in this session.\nRun in your shell:\n");
    try output(init.io, if (shell == .powershell)
        try std.fmt.allocPrint(a, "  & {s} init {s} | Out-String | Invoke-Expression\n", .{ quoted, @tagName(shell) })
    else
        try std.fmt.allocPrint(a, "  eval \"$({s} init {s})\"\n", .{ quoted, @tagName(shell) }));
}

fn profileLabel(a: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    return cfg.problem orelse if (cfg.profile != null) cfg.name else try std.fmt.allocPrint(a, "{s} (not configured; rules and cache only)", .{cfg.name});
}

fn configurationError(init: std.process.Init, cfg: config.Config) !bool {
    const problem = cfg.problem orelse return false;
    try std.Io.File.stderr().writeStreamingAll(init.io, try std.fmt.allocPrint(init.arena.allocator(), "shell-buddy: {s}\nconfig: {s}\n", .{ problem, cfg.config_path }));
    return true;
}

fn output(io: std.Io, text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, text);
}
test {
    std.testing.refAllDecls(@import("core.zig"));
    std.testing.refAllDecls(@import("rules.zig"));
    std.testing.refAllDecls(@import("cache.zig"));
    std.testing.refAllDecls(@import("model.zig"));
    std.testing.refAllDecls(@import("terminal.zig"));
    std.testing.refAllDecls(@import("credentials.zig"));
    std.testing.refAllDecls(@import("setup.zig"));
}
