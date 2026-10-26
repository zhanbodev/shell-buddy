// Test-only loopback source injection. Never installed by the default build or packaged.
const std = @import("std");
const updater = @import("updater");
pub fn main(init: std.process.Init) void {
    execute(init) catch |err| {
        std.Io.File.stderr().writeStreamingAll(init.io, @errorName(err)) catch {};
        std.process.exit(1);
    };
}
fn execute(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var options: updater.Options = .{};
    for (args[5..]) |arg| {
        if (std.mem.eql(u8, arg, "--check")) options.check = true;
        if (std.mem.eql(u8, arg, "--no-font")) options.no_font = true;
    }
    try updater.perform(.{
        .a = a,
        .io = init.io,
        .executable = try std.process.executablePathAlloc(init.io, a),
        .current_version = args[3],
        .font_path = args[4],
        .register_font = false,
    }, .{ .metadata = args[1], .downloads = args[2], .allow_loopback_http = true, .timeout_ms = if (std.mem.startsWith(u8, args[1], "https://")) 30_000 else 1000 }, options);
}
