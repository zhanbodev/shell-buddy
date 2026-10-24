const std = @import("std");
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const control = @import("control.zig");
const terminal = @import("terminal.zig");
const core = @import("core.zig");

pub const help = "usage: shell-buddy init [<shell>]\n\n" ++
    "Without arguments, open the interactive model setup wizard.\n" ++
    "With a shell name, print its integration script for evaluation.\n" ++
    "Configure a model interactively and save its API key with private permissions.\n" ++
    "Use Tab to switch profiles and terminal icons. Press Enter to keep a displayed value.\n" ++
    "Choose star (default) or lizard (requires the Shell Buddy font).\n" ++
    "Setup does not download files or install fonts; release installers include the font.\n" ++
    "API keys are hidden and stored separately in credentials.json (plaintext).\n" ++
    "Press Esc or Ctrl+C to cancel before saving.\n";

pub fn run(init: std.process.Init) !u8 {
    var term = terminal.Terminal.open(init.io) catch return error.InteractiveTerminalRequired;
    defer term.close();
    var wizard: Wizard = .{ .term = &term, .a = init.arena.allocator() };
    defer std.crypto.secureZero(u8, &wizard.decoder.bytes);
    try term.write("Shell Buddy setup\r\n\r\n" ++
        "  - local  Use a local model service, such as Ollama\r\n" ++
        "  - cloud  Use a cloud model service\r\n\r\n" ++
        "Font installation is handled by the release installer; setup downloads nothing.\r\n" ++
        "Tab switches choices; Enter keeps a displayed value; Esc cancels.\r\n");
    const cfg = setup(init, &wizard) catch |err| {
        try term.write("\r\n");
        if (err == error.SetupCancelled or err == error.TerminalClosed) {
            try term.write("Setup cancelled. No changes saved.\r\n");
            return 130;
        }
        return err;
    };
    try term.write(try std.fmt.allocPrint(wizard.a, "\r\nSaved. Default profile: {s}\r\nconfig: {s}\r\ncredentials: {s}\r\nConfiguration reloaded; suggestion state preserved.\r\n", .{ cfg.name, cfg.config_path, cfg.credentials_path }));
    return 0;
}

fn setup(init: std.process.Init, wizard: *Wizard) !config.Config {
    const a = wizard.a;
    const current = try config.load(a, init.io, init.environ_map);
    const selection = try wizard.ask("Profile: ", if (config.validSelection(current.name)) current.name else "local", .profile, false);
    const old = try config.readProfile(a, init.io, current.config_path, selection);
    const old_url = if (old) |p| p.base_url else "";
    const initial_url = if (validUrl(old_url) and !std.mem.eql(u8, old_url, "https://YOUR_PROVIDER/v1")) old_url else if (std.mem.eql(u8, selection, "local")) "http://localhost:11434/v1" else "";
    const base_url = try wizard.ask("Base URL: ", initial_url, .url, false);
    const old_model = if (old) |p| p.model else "";
    const model = try wizard.ask("Model: ", if (validModel(old_model)) old_model else "", .model, false);
    var env_name: ?[]const u8 = if (std.mem.eql(u8, selection, "cloud")) "SHELL_BUDDY_API_KEY" else null;
    // Repair the common mistake of entering a literal API key in api_key_env.
    // It is never displayed, reused, or copied to the credential store.
    if (old) |p| if (p.api_key_env) |name| {
        if (credentials.validEnvName(name)) env_name = name;
    };
    const stored = try credentials.load(a, init.io, current.credentials_path, selection);
    const environment = if (env_name) |name| init.environ_map.get(name) else null;
    const has_env = if (environment) |key| credentials.validKey(key) else false;
    try wizard.term.write("API keys are saved in a private plaintext credentials file.\r\n");
    if (has_env) try wizard.term.write("An environment key is set and takes priority over saved credentials.\r\n");
    const required = std.mem.eql(u8, selection, "cloud") and stored == null and !has_env;
    const key = try wizard.ask(if (stored != null or has_env) "API key (hidden, Enter to keep): " else if (required) "API key (hidden, required): " else "API key (hidden, optional): ", "", .secret, required);
    try wizard.term.write("\r\n  - star    ✦  Standard star (default; no extra font)\r\n" ++
        "  - lizard  Custom mascot (install and configure Shell Buddy font first)\r\n\r\n");
    const icon = try wizard.ask("Terminal icon: ", @tagName(current.icon), .icon, false);
    try wizard.term.write("Saving configuration...\r\n");
    const cfg = try config.saveProfile(a, init.io, init.environ_map, selection, .{ .base_url = base_url, .model = model, .api_key_env = env_name }, if (key.len > 0) key else null, if (std.mem.eql(u8, icon, "lizard")) .lizard else .star);
    _ = try control.update(a, init.io, cfg.state_path, null);
    return cfg;
}

const Kind = enum { profile, icon, url, model, secret };
const Wizard = struct {
    term: *terminal.Terminal,
    a: std.mem.Allocator,
    decoder: terminal.Decoder = .{},

    fn ask(self: *Wizard, label: []const u8, initial: []const u8, kind: Kind, required: bool) ![]const u8 {
        var buffer: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        var len: usize = @min(initial.len, buffer.len);
        @memcpy(buffer[0..len], initial[0..len]);
        var cursor = len;
        var pasting = false;
        var multiline = false;
        var overflow = false;
        try self.term.write("\x1b[?2004h");
        while (true) {
            try self.draw(label, buffer[0..len], cursor, kind == .secret);
            const key = try self.read();
            switch (key) {
                .cancel, .escape => return error.SetupCancelled,
                .paste_start => pasting = true,
                .paste_end => {
                    pasting = false;
                    if (multiline) {
                        try self.term.write("\r\nUse a single line. Please enter the value again.\r\n");
                        len = 0;
                        cursor = 0;
                        multiline = false;
                        overflow = false;
                    }
                },
                .enter => {
                    if (pasting) {
                        multiline = true;
                        continue;
                    }
                    if (overflow) {
                        try self.term.write("\r\nValue too long (maximum 4096 bytes). Please enter it again.\r\n");
                        len = 0;
                        cursor = 0;
                        overflow = false;
                        continue;
                    }
                    const value = buffer[0..len];
                    const valid = switch (kind) {
                        .profile => config.validSelection(value),
                        .icon => std.mem.eql(u8, value, "lizard") or std.mem.eql(u8, value, "star"),
                        .url => validUrl(value) and !std.mem.eql(u8, value, "https://YOUR_PROVIDER/v1"),
                        .model => validModel(value),
                        .secret => (len == 0 and !required) or credentials.validKey(value),
                    };
                    try self.term.write("\r\n");
                    if (valid) return try self.a.dupe(u8, value);
                    try self.term.write(switch (kind) {
                        .profile => "Choose a listed profile, or press Tab to switch.\r\n",
                        .icon => "Choose star or lizard, or press Tab to switch.\r\n",
                        .url => "Enter an HTTP(S) base URL without credentials, query or fragment.\r\n",
                        .model => "Enter the model name provided by your service.\r\n",
                        .secret => "Enter a valid API key; cloud requires an existing or new key.\r\n",
                    });
                    if (kind == .secret) {
                        len = 0;
                        cursor = 0;
                    }
                },
                .tab => if ((kind == .profile or kind == .icon) and !pasting) {
                    const value = if (kind == .icon) (if (std.mem.eql(u8, buffer[0..len], "star")) "lizard" else "star") else (if (std.mem.eql(u8, buffer[0..len], "local")) "cloud" else "local");
                    @memcpy(buffer[0..value.len], value);
                    len = value.len;
                    cursor = len;
                },
                .text => |value| {
                    if (len + value.len > buffer.len) {
                        overflow = true;
                        continue;
                    }
                    std.mem.copyBackwards(u8, buffer[cursor + value.len .. len + value.len], buffer[cursor..len]);
                    @memcpy(buffer[cursor..][0..value.len], value);
                    len += value.len;
                    cursor += value.len;
                },
                .left => cursor = core.previous(buffer[0..len], cursor),
                .right => cursor = core.next(buffer[0..len], cursor),
                .home => cursor = 0,
                .end => cursor = len,
                .backspace, .word => {
                    if (cursor == 0) continue;
                    const start = if (key == .word) 0 else core.previous(buffer[0..len], cursor);
                    std.mem.copyForwards(u8, buffer[start..], buffer[cursor..len]);
                    len -= cursor - start;
                    cursor = start;
                },
                .delete => if (cursor < len) {
                    const end = core.next(buffer[0..len], cursor);
                    std.mem.copyForwards(u8, buffer[cursor..], buffer[end..len]);
                    len -= end - cursor;
                },
                .clear => {
                    len = 0;
                    cursor = 0;
                    overflow = false;
                },
                else => {},
            }
        }
    }

    fn read(self: *Wizard) !terminal.Key {
        var input: [256]u8 = undefined;
        defer std.crypto.secureZero(u8, &input);
        while (true) {
            if (self.term.wasInterrupted()) return error.SetupCancelled;
            if (self.decoder.take(false)) |key| return key;
            const n = try self.term.read(&input, 50);
            if (n == 0) {
                if (self.decoder.take(true)) |key| return key;
            } else try self.decoder.push(input[0..n]);
        }
    }

    fn draw(self: *Wizard, label: []const u8, value: []const u8, cursor: usize, hidden: bool) !void {
        try self.term.write("\r\x1b[2K");
        const columns = self.term.columns();
        const label_len = @min(label.len, columns - 2);
        try self.term.write(label[0..label_len]);
        if (hidden) return;
        const available = columns - label_len - 1;
        var start: usize = 0;
        while (start < cursor and core.width(value[start..cursor]) >= available) start = core.next(value, start);
        var end = start;
        while (end < value.len and core.width(value[start..core.next(value, end)]) <= available) end = core.next(value, end);
        try self.term.write(value[start..end]);
        const back = core.width(value[cursor..end]);
        if (back > 0) {
            var bytes: [32]u8 = undefined;
            try self.term.write(try std.fmt.bufPrint(&bytes, "\x1b[{d}D", .{back}));
        }
    }
};

fn validUrl(value: []const u8) bool {
    if (!core.validText(value)) return false;
    for (value) |c| if (c <= 32) return false;
    const uri = std.Uri.parse(value) catch return false;
    return (std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "https")) and uri.host != null and !uri.host.?.isEmpty() and uri.user == null and uri.password == null and uri.query == null and uri.fragment == null;
}

fn validModel(value: []const u8) bool {
    return core.validText(value) and std.mem.trim(u8, value, " ").len > 0 and !std.mem.startsWith(u8, value, "YOUR_");
}

test "setup rejects unsafe URL defaults and placeholder models" {
    try std.testing.expect(validUrl("http://localhost:11434/v1"));
    try std.testing.expect(!validUrl("https://user:secret@example.com/v1"));
    try std.testing.expect(!validUrl("https://example.com/?key=secret"));
    try std.testing.expect(!validUrl("https://example.com/\x1b[2J"));
    try std.testing.expect(!validUrl("https:///v1"));
    try std.testing.expect(!validModel("YOUR_CLOUD_MODEL"));
    try std.testing.expect(validModel("test-model:latest"));
}
