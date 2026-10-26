const std = @import("std");
const builtin = @import("builtin");
const credentials = @import("credentials.zig");
const private = @import("private_file.zig");
const core = @import("core.zig");

pub const Profile = struct {
    base_url: []const u8,
    model: []const u8,
    api_key_env: ?[]const u8 = null,
};
pub const Config = struct {
    profile: ?Profile = null,
    name: []const u8 = "unconfigured",
    problem: ?[]const u8 = null,
    debounce_ms: u32 = 150,
    timeout_ms: u32 = 8000,
    max_tokens: u32 = 2048,
    input_style: core.InputStyle = .square,
    config_path: []const u8,
    cache_path: []const u8,
    state_path: []const u8 = "",
    credentials_path: []const u8 = "",
};

pub fn paths(a: std.mem.Allocator, env: *const std.process.Environ.Map) !Config {
    const home = env.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse ".";
    const config_root = env.get("XDG_CONFIG_HOME") orelse try std.fs.path.join(a, &.{ home, ".config" });
    const cache_root = env.get(if (builtin.os.tag == .windows) "LOCALAPPDATA" else "XDG_CACHE_HOME") orelse try std.fs.path.join(a, &.{ home, ".cache" });
    var cfg: Config = .{
        .config_path = env.get("SHELL_BUDDY_CONFIG") orelse try std.fs.path.join(a, &.{ config_root, "shell-buddy", "config.json" }),
        .cache_path = env.get("SHELL_BUDDY_CACHE") orelse try std.fs.path.join(a, &.{ cache_root, "shell-buddy", "cache.json" }),
    };
    cfg.state_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(cfg.config_path) orelse ".", "state.json" });
    cfg.credentials_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(cfg.config_path) orelse ".", "credentials.json" });
    return cfg;
}

// An exclusive lock and atomic creation prevent another terminal from seeing a
// half-written template. Existing user configuration is never replaced.
pub fn ensure(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !void {
    const cfg = try paths(a, env);
    try private.parent(a, io, cfg.config_path);
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{cfg.config_path});
    const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .permissions = privatePermissions() });
    defer lock.close(io);
    const existing = std.Io.Dir.cwd().openFile(io, cfg.config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            var atomic = try std.Io.Dir.cwd().createFileAtomic(io, cfg.config_path, .{ .replace = false, .permissions = privatePermissions() });
            defer atomic.deinit(io);
            try atomic.file.writeStreamingAll(io, example);
            try atomic.link(io);
            return;
        },
        else => return err,
    };
    existing.close(io);
}

pub fn load(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Config {
    var cfg = try paths(a, env);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, cfg.config_path, a, .limited(65536)) catch |err| {
        if (err != error.FileNotFound) cfg.problem = "Cannot read model configuration";
        return cfg;
    };
    return parse(a, cfg, bytes);
}

fn parse(a: std.mem.Allocator, initial: Config, bytes: []const u8) Config {
    var cfg = initial;
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always }) catch {
        cfg.problem = "Invalid configuration JSON";
        return cfg;
    };
    if (parsed.value != .object) {
        cfg.problem = "Configuration must be a JSON object";
        return cfg;
    }
    const obj = parsed.value.object;
    // Legacy icon and nerd_font settings do not enable font-dependent caps.
    if (obj.get("input_style")) |v| {
        if (v != .string or (!std.mem.eql(u8, v.string, "square") and !std.mem.eql(u8, v.string, "rounded"))) {
            cfg.problem = "input_style must be 'square' or 'rounded'";
            return cfg;
        }
        cfg.input_style = if (std.mem.eql(u8, v.string, "rounded")) .rounded else .square;
    }
    if (obj.get("max_tokens")) |v| {
        if (v != .integer or v.integer < 1 or v.integer > 32768) {
            cfg.problem = "max_tokens must be an integer between 1 and 32768";
            return cfg;
        }
        cfg.max_tokens = @intCast(v.integer);
    }
    if (obj.get("debounce_ms")) |v| {
        if (v != .integer or v.integer < 0 or v.integer > 2000) {
            cfg.problem = "debounce_ms must be an integer between 0 and 2000";
            return cfg;
        }
        cfg.debounce_ms = @intCast(v.integer);
    }
    if (obj.get("timeout_ms")) |v| {
        if (v != .integer or v.integer < 100 or v.integer > 120000) {
            cfg.problem = "timeout_ms must be an integer between 100 and 120000";
            return cfg;
        }
        cfg.timeout_ms = @intCast(v.integer);
    }
    const selected = obj.get("default");
    const active = selected orelse obj.get("active_profile") orelse return cfg;
    // Existing active_profile configurations remain readable. New configurations
    // use an explicit local/cloud default, which always takes precedence.
    if (selected != null and (active != .string or !validSelection(active.string))) {
        cfg.problem = "default must be 'local' or 'cloud'";
        return cfg;
    }
    if (active == .null) return cfg;
    const profiles = obj.get("profiles") orelse {
        cfg.problem = "Missing profiles";
        return cfg;
    };
    if (active != .string or profiles != .object) {
        cfg.problem = "Invalid profile selection or profiles object";
        return cfg;
    }
    cfg.name = active.string;
    const value = profiles.object.get(cfg.name) orelse {
        cfg.problem = "Selected profile does not exist";
        return cfg;
    };
    const profile = std.json.parseFromValue(Profile, a, value, .{ .ignore_unknown_fields = true }) catch {
        cfg.problem = "Profile requires base_url and model";
        return cfg;
    };
    if (!core.validText(profile.value.model) or !core.validText(profile.value.base_url)) {
        cfg.problem = "Configure a model URL and name";
        return cfg;
    }
    if (profile.value.api_key_env) |name| if (!credentials.validEnvName(name)) {
        cfg.problem = "api_key_env must be an environment variable name; run shell-buddy init";
        return cfg;
    };
    // The generated template is usable offline until the user supplies a model.
    if (std.mem.eql(u8, profile.value.model, "YOUR_LOCAL_MODEL") or std.mem.eql(u8, profile.value.model, "YOUR_CLOUD_MODEL") or std.mem.eql(u8, profile.value.base_url, "https://YOUR_PROVIDER/v1")) return cfg;
    const uri = std.Uri.parse(profile.value.base_url) catch {
        cfg.problem = "Invalid model URL";
        return cfg;
    };
    if ((!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) or uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        cfg.problem = "Model URL must be an HTTP(S) base URL without credentials, query or fragment";
        return cfg;
    }
    cfg.profile = profile.value;
    return cfg;
}

pub fn validSelection(name: []const u8) bool {
    return std.mem.eql(u8, name, "local") or std.mem.eql(u8, name, "cloud");
}

pub fn select(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) !Config {
    if (!validSelection(name)) return error.InvalidProfile;
    try ensure(a, io, env);
    var cfg = try paths(a, env);
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{cfg.config_path});
    const lock = try std.Io.Dir.cwd().openFile(io, lock_path, .{ .mode = .read_write, .lock = .exclusive });
    defer lock.close(io);
    const original = try std.Io.Dir.cwd().readFileAlloc(io, cfg.config_path, a, .limited(65536));
    const document = std.json.parseFromSlice(std.json.Value, a, original, .{ .allocate = .alloc_always }) catch {
        cfg.problem = "Invalid configuration JSON";
        return cfg;
    };
    if (document.value != .object) {
        cfg.problem = "Configuration must be a JSON object";
        return cfg;
    }
    var root = document.value;
    try root.object.put(a, "default", .{ .string = name });
    _ = root.object.orderedRemove("active_profile");
    const bytes = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
    if (bytes.len >= 65536) return error.ConfigurationTooLarge;
    cfg = parse(a, cfg, bytes);
    if (cfg.problem != null) return cfg;
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, cfg.config_path, .{ .replace = true, .permissions = privatePermissions() });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.writeStreamingAll(io, "\n");
    try atomic.replace(io);
    return cfg;
}

pub fn privatePermissions() std.Io.File.Permissions {
    return private.permissions();
}

pub fn readProfile(a: std.mem.Allocator, io: std.Io, path: []const u8, name: []const u8) !?Profile {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(65536)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidConfiguration;
    if (parsed.value != .object) return error.InvalidConfiguration;
    const profiles = parsed.value.object.get("profiles") orelse return null;
    if (profiles != .object) return error.InvalidConfiguration;
    const value = profiles.object.get(name) orelse return null;
    const profile = std.json.parseFromValue(Profile, a, value, .{ .ignore_unknown_fields = true }) catch return null;
    return profile.value;
}

// Re-read under the same lock used by `llm` so configuring one profile cannot
// overwrite another terminal's changes. Validate before committing either file.
pub fn saveProfile(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8, profile: Profile, key: ?[]const u8, input_style: core.InputStyle) !Config {
    if (!validSelection(name)) return error.InvalidProfile;
    var cfg = try paths(a, env);
    try private.parent(a, io, cfg.config_path);
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{cfg.config_path});
    const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .permissions = privatePermissions() });
    defer lock.close(io);
    const original = std.Io.Dir.cwd().readFileAlloc(io, cfg.config_path, a, .limited(65536)) catch |err| switch (err) {
        error.FileNotFound => example,
        else => return err,
    };
    const parsed = std.json.parseFromSlice(std.json.Value, a, original, .{ .allocate = .alloc_always }) catch return error.InvalidConfiguration;
    if (parsed.value != .object) return error.InvalidConfiguration;
    var root = parsed.value;
    try root.object.put(a, "input_style", .{ .string = @tagName(input_style) });
    _ = root.object.orderedRemove("icon");
    _ = root.object.orderedRemove("nerd_font");
    if (!root.object.contains("max_tokens")) try root.object.put(a, "max_tokens", .{ .integer = 2048 });
    var profiles = root.object.get("profiles") orelse std.json.Value{ .object = .empty };
    if (profiles != .object) return error.InvalidConfiguration;
    var value: std.json.Value = .{ .object = .empty };
    try value.object.put(a, "base_url", .{ .string = profile.base_url });
    try value.object.put(a, "model", .{ .string = profile.model });
    if (profile.api_key_env) |v| try value.object.put(a, "api_key_env", .{ .string = v });
    try profiles.object.put(a, name, value);
    try root.object.put(a, "profiles", profiles);
    try root.object.put(a, "default", .{ .string = name });
    _ = root.object.orderedRemove("active_profile");
    const bytes = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
    if (bytes.len >= 65536) return error.ConfigurationTooLarge;
    cfg = parse(a, cfg, bytes);
    if (cfg.problem != null or cfg.profile == null) return error.InvalidConfiguration;
    var file = try private.atomic(a, io, cfg.config_path);
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.file.writeStreamingAll(io, "\n");
    if (key) |secret| try credentials.save(a, io, cfg.credentials_path, name, secret);
    try file.replace(io);
    return cfg;
}

pub const example =
    \\{
    \\  "default": "local",
    \\  "profiles": {
    \\    "local": {"base_url": "http://localhost:11434/v1", "model": "YOUR_LOCAL_MODEL"},
    \\    "cloud": {"base_url": "https://YOUR_PROVIDER/v1", "model": "YOUR_CLOUD_MODEL", "api_key_env": "SHELL_BUDDY_API_KEY"}
    \\  },
    \\  "input_style": "square",
    \\  "debounce_ms": 150,
    \\  "max_tokens": 2048,
    \\  "timeout_ms": 8000
    \\}
    \\
;
