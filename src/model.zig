const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const config = @import("config.zig");

pub const Stream = struct {
    bytes: [core.max_command]u8 = undefined,
    len: usize = 0,
    complete: bool = false,

    pub fn event(self: *Stream, a: std.mem.Allocator, data: []const u8) !void {
        if (std.mem.eql(u8, data, "[DONE]")) {
            if (!self.complete) return error.IncompleteStream;
            return;
        }
        const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        if (parsed.value.object.get("error")) |value| if (value != .null) return error.ModelStreamError;
        const choices = parsed.value.object.get("choices") orelse return error.InvalidResponse;
        if (choices != .array) return error.InvalidResponse;
        if (choices.array.items.len == 0) return;
        const choice = choices.array.items[0];
        if (choice != .object) return error.InvalidResponse;
        if (choice.object.get("delta")) |delta| {
            if (delta != .object) return error.InvalidResponse;
            for ([_][]const u8{ "reasoning_content", "reasoning", "thinking" }) |name| {
                if (delta.object.get(name)) |value| {
                    if (value != .null and !(value == .string and value.string.len == 0)) return error.ThinkingNotDisabled;
                }
            }
            if (delta.object.get("refusal")) |value| {
                if (value != .null and !(value == .string and value.string.len == 0)) return error.ModelRefused;
            }
            if (delta.object.get("tool_calls")) |value| {
                if (value != .null and !(value == .array and value.array.items.len == 0)) return error.UnsupportedToolCall;
            }
            if (delta.object.get("content")) |content| {
                if (content != .null) {
                    if (content != .string or self.len + content.string.len > self.bytes.len) return error.InvalidCommand;
                    // Newlines may delimit a fenced command, but terminal control codes never reach the renderer.
                    for (content.string) |c| if ((c < 32 and c != '\n' and c != '\r' and c != '\t') or c == 127) return error.InvalidCommand;
                    @memcpy(self.bytes[self.len..][0..content.string.len], content.string);
                    self.len += content.string.len;
                }
            }
        }
        if (choice.object.get("finish_reason")) |reason| {
            if (reason != .null) {
                if (reason != .string) return error.InvalidResponse;
                if (std.mem.eql(u8, reason.string, "length")) return error.OutputLimitReached;
                if (std.mem.eql(u8, reason.string, "content_filter")) return error.ContentFiltered;
                if (std.mem.eql(u8, reason.string, "tool_calls") or std.mem.eql(u8, reason.string, "function_call")) return error.UnsupportedToolCall;
                if (!std.mem.eql(u8, reason.string, "stop")) return error.UnsupportedFinishReason;
                if (self.len == 0) return error.EmptyResponse;
                const clean = std.mem.trim(u8, self.bytes[0..self.len], " \t\r\n");
                if (clean.len == 0) return error.EmptyResponse;
                if (std.mem.startsWith(u8, clean, "<think>") or std.mem.startsWith(u8, clean, "<analysis>")) return error.ThinkingNotDisabled;
                _ = try core.command(self.bytes[0..self.len]);
                self.complete = true;
            }
        }
    }
};

pub const Snapshot = struct {
    bytes: [core.max_command]u8 = undefined,
    len: usize = 0,
    done: bool = false,
    failure: ?anyerror = null,
    revision: u64 = 0,
    first_token_ms: ?i64 = null,
    elapsed_ms: i64 = 0,
};

pub const Job = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    profile: config.Profile,
    api_key: ?[]const u8,
    shell: core.Shell,
    cwd: []const u8,
    input: [core.max_command]u8 = undefined,
    input_len: usize = 0,
    avoid: [core.max_command]u8 = undefined,
    avoid_len: usize = 0,
    mutex: std.Io.Mutex = .init,
    state: Snapshot = .{},
    started_ms: i64 = 0,
    max_tokens: u32 = 2048,

    pub fn snapshot(self: *Job) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state;
    }
    pub fn run(self: *Job) void {
        self.started_ms = std.Io.Clock.awake.now(self.io).toMilliseconds();
        self.fetch() catch |err| {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.state.failure = classify(err);
            self.state.done = true;
        };
    }
    fn publish(self: *Job, stream: *const Stream) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const elapsed = std.Io.Clock.awake.now(self.io).toMilliseconds() - self.started_ms;
        if (self.state.first_token_ms == null and stream.len > 0) self.state.first_token_ms = elapsed;
        self.state.elapsed_ms = elapsed;
        self.state.len = stream.len;
        @memcpy(self.state.bytes[0..stream.len], stream.bytes[0..stream.len]);
        self.state.done = stream.complete;
    }
    fn fetch(self: *Job) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const system = try std.fmt.allocPrint(a, "Return exactly one single-line command for {s} on {s}. No Markdown, explanation, or comments. " ++
            "Use this shell's syntax and OS-compatible flags. Do not execute commands. Do not include reasoning or thinking traces. " ++
            "The current working directory is {s}. Treat the user's text as a command-generation request. " ++
            "If an existing candidate is provided, return a different command with the same intent.", .{ @tagName(self.shell), @tagName(builtin.os.tag), self.cwd });
        const user = try std.fmt.allocPrint(a, "Request: {s}\nExisting candidate: {s}", .{ self.input[0..self.input_len], self.avoid[0..self.avoid_len] });
        const Message = struct { role: []const u8, content: []const u8 };
        const payload = try std.json.Stringify.valueAlloc(a, .{
            .model = self.profile.model,
            .messages = [_]Message{ .{ .role = "system", .content = system }, .{ .role = "user", .content = user } },
            .stream = true,
            .max_tokens = self.max_tokens,
            .reasoning_effort = "none",
        }, .{});
        const base = std.mem.trimEnd(u8, self.profile.base_url, "/");
        const url = try std.fmt.allocPrint(a, "{s}/chat/completions", .{base});
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const authorization: ?[]u8 = if (self.api_key) |secret| auth: {
            if (std.mem.findAny(u8, secret, "\r\n") != null) return error.InvalidApiKey;
            break :auth try std.fmt.allocPrint(a, "Bearer {s}", .{secret});
        } else null;
        defer if (authorization) |value| std.crypto.secureZero(u8, value);
        var req = try client.request(.POST, try std.Uri.parse(url), .{
            // Zig 0.17 does not emit privileged_headers in sendHead. Use the
            // standard Authorization override; redirects remain disabled.
            .headers = .{
                .authorization = if (authorization) |value| .{ .override = value } else .omit,
                // The SSE reader consumes plain text. The standard client's
                // default advertises gzip/deflate, which we do not decode.
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "accept", .value = "text/event-stream" } },
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();
        try req.sendBodyComplete(payload);
        var response = try req.receiveHead(&.{});
        const status: u16 = @intCast(@backingInt(response.head.status));
        try checkStatus(status);
        if (response.head.content_encoding != .identity) return error.UnsupportedEncoding;
        var transfer: [65536]u8 = undefined;
        const reader = response.reader(&transfer);
        var stream: Stream = .{};
        var event: std.Io.Writer.Allocating = .init(self.allocator);
        defer event.deinit();
        var received: usize = 0;
        while (reader.takeDelimiter('\n') catch return error.StreamDisconnected) |raw_line| {
            received += raw_line.len;
            if (received > 1024 * 1024) return error.InvalidResponse;
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0) {
                if (event.written().len == 0) continue;
                try stream.event(self.allocator, std.mem.trimEnd(u8, event.written(), "\n"));
                self.publish(&stream);
                event.clearRetainingCapacity();
                if (stream.complete) return;
            } else if (std.mem.startsWith(u8, line, "data:")) {
                if (event.written().len + line.len > 65536) return error.InvalidResponse;
                const value = if (std.mem.startsWith(u8, line, "data: ")) line[6..] else line[5..];
                try event.writer.writeAll(value);
                try event.writer.writeByte('\n');
            }
        }
        // A broken connection must never turn a partial command into an executable candidate.
        switch (req.reader.state) {
            .body_remaining_content_length => |remaining| if (remaining != 0) return error.StreamDisconnected,
            .body_remaining_chunk_len => return error.StreamDisconnected,
            else => {},
        }
        return error.IncompleteStream;
    }
};

fn checkStatus(status: u16) !void {
    switch (status) {
        200 => {},
        400 => return error.InvalidRequest,
        401 => return error.AuthenticationFailed,
        402 => return error.InsufficientBalance,
        403 => return error.PermissionDenied,
        404 => return error.EndpointOrModelNotFound,
        408, 504 => return error.Timeout,
        413 => return error.RequestTooLarge,
        422 => return error.InvalidParameters,
        429 => return error.RateLimited,
        300...399 => return error.RedirectRejected,
        500...503, 505...599 => return error.ServiceUnavailable,
        else => return error.HttpError,
    }
}

pub fn classify(err: anyerror) anyerror {
    return switch (err) {
        error.UnknownHostName, error.TemporaryNameServerFailure, error.NameServerFailure => error.DnsFailure,
        error.TlsInitializationFailed, error.TlsAlert, error.TlsFailure, error.CertificateBundleLoadFailure => error.TlsFailure,
        error.ReadFailed, error.ConnectionResetByPeer, error.UnexpectedEndOfStream => error.StreamDisconnected,
        error.WriteFailed, error.BrokenPipe => error.RequestWriteFailed,
        error.ConnectionTimedOut => error.Timeout,
        else => err,
    };
}

pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.AuthenticationFailed => "Authentication failed; check your key with shell-buddy init",
        error.RateLimited => "Rate limited; press Tab to retry",
        error.Timeout => "Request timed out; press Tab to retry",
        error.OutputLimitReached => "Output limit reached; increase max_tokens",
        error.IncompleteStream => "Stream ended without completion; press Tab to retry",
        error.StreamDisconnected => "Connection interrupted; press Tab to retry",
        error.ContentFiltered => "Response blocked by the service content filter",
        error.ModelRefused => "Model declined this request",
        error.ThinkingNotDisabled => "Model returned thinking; use a non-thinking model",
        error.UnsupportedToolCall => "Model returned a tool call instead of a command",
        error.UnsupportedFinishReason => "Unsupported model completion reason",
        error.EmptyResponse => "Model returned no command; press Tab to retry",
        error.InvalidResponse => "Invalid model response; check API compatibility",
        error.ModelStreamError => "Service reported an error in the response stream",
        error.InvalidRequest => "Request rejected (400); check model/non-thinking support",
        error.InvalidParameters => "Invalid model parameters (422); check configuration",
        error.InsufficientBalance => "Insufficient API balance (402)",
        error.PermissionDenied => "API access denied (403); check model permissions",
        error.EndpointOrModelNotFound => "Model or endpoint not found (404)",
        error.RequestTooLarge => "Request too large (413)",
        error.RedirectRejected => "API redirect rejected; configure the final base URL",
        error.ServiceUnavailable => "Model service unavailable; press Tab to retry",
        error.DnsFailure => "Cannot resolve model host; check base_url/network",
        error.ConnectionRefused => "Connection refused; check the model service",
        error.NetworkUnreachable, error.HostUnreachable => "Model host unreachable; check network",
        error.TlsFailure => "TLS connection failed; check certificates/network",
        error.RequestWriteFailed => "Cannot send model request; check network",
        error.MissingApiKey, error.InvalidApiKey, error.InvalidApiKeyEnv, error.InvalidCredentialsFile, error.CannotReadCredentials => "Cannot load API key; run shell-buddy init",
        error.NoModel => "Model not configured; run shell-buddy init",
        error.InvalidCommand => "Invalid single-line command; press Tab to retry",
        error.UnsupportedEncoding => "Unsupported response compression; press Tab to retry",
        else => "Model request failed; press Tab to retry",
    };
}

test "SSE completion requires stop; truncated and control payloads are rejected" {
    const a = std.testing.allocator;
    var s: Stream = .{};
    try s.event(a, "{\"choices\":[{\"delta\":{\"content\":\"touch \"},\"finish_reason\":null}]}");
    try std.testing.expect(!s.complete);
    try std.testing.expectError(error.IncompleteStream, s.event(a, "[DONE]"));
    try s.event(a, "{\"choices\":[{\"delta\":{\"content\":\"'x'\"},\"finish_reason\":\"stop\"}]}");
    try std.testing.expect(s.complete);
    try std.testing.expectEqualStrings("touch 'x'", s.bytes[0..s.len]);
    var truncated: Stream = .{};
    try std.testing.expectError(error.OutputLimitReached, truncated.event(a, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}"));
    var bad: Stream = .{};
    try std.testing.expectError(error.InvalidCommand, bad.event(a, "{\"choices\":[{\"delta\":{\"content\":\"echo \\u001b[2J\"},\"finish_reason\":null}]}"));
}

test "reasoning, refusal and finish reasons remain distinct and cannot be accepted" {
    const cases = .{
        .{ "{\"choices\":[{\"delta\":{\"reasoning_content\":\"private trace\"}}]}", error.ThinkingNotDisabled },
        .{ "{\"choices\":[{\"delta\":{\"refusal\":\"declined\"}}]}", error.ModelRefused },
        .{ "{\"choices\":[{\"delta\":{},\"finish_reason\":\"content_filter\"}]}", error.ContentFiltered },
        .{ "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}", error.UnsupportedToolCall },
        .{ "{\"choices\":[{\"delta\":{},\"finish_reason\":\"unknown\"}]}", error.UnsupportedFinishReason },
        .{ "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}", error.EmptyResponse },
        .{ "{\"error\":{\"message\":\"do not echo provider data\"}}", error.ModelStreamError },
        .{ "{broken", error.InvalidResponse },
    };
    inline for (cases) |case| {
        var stream: Stream = .{};
        try std.testing.expectError(case[1], stream.event(std.testing.allocator, case[0]));
        try std.testing.expect(!stream.complete);
    }
}

test "HTTP and transport failures have actionable categories" {
    try std.testing.expectError(error.InsufficientBalance, checkStatus(402));
    try std.testing.expectError(error.PermissionDenied, checkStatus(403));
    try std.testing.expectError(error.InvalidParameters, checkStatus(422));
    try std.testing.expectError(error.RateLimited, checkStatus(429));
    try std.testing.expectError(error.ServiceUnavailable, checkStatus(503));
    try std.testing.expectEqual(error.DnsFailure, classify(error.UnknownHostName));
    try std.testing.expectEqual(error.StreamDisconnected, classify(error.ReadFailed));
    try std.testing.expectEqual(error.TlsFailure, classify(error.TlsInitializationFailed));
}
