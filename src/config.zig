const std = @import("std");

const path_buf_size = 4096;

/// Persisted user settings. Paths point into the arena (or are null if not
/// set yet). Defaults match the previous hard-coded values.
pub const Config = struct {
    threshold: f32 = 0.05,
    show_debug: bool = false,
    closed_path: ?[]const u8 = null,
    open_path: ?[]const u8 = null,
};

/// Settings file name, resolved relative to the process's current working
/// directory (i.e. wherever the app was launched from).
pub const config_file_name = "btuber.ini";

/// Parse a simple `key=value` settings file. Missing/corrupt file -> defaults.
pub fn loadConfig(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Config {
    var cfg: Config = .{};
    const data = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        std.Io.Limit.limited(16 * 1024),
    ) catch return cfg;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "threshold")) {
            cfg.threshold = std.fmt.parseFloat(f32, val) catch cfg.threshold;
        } else if (std.mem.eql(u8, key, "show_debug")) {
            cfg.show_debug = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "closed")) {
            if (val.len > 0) cfg.closed_path = allocator.dupe(u8, val) catch null;
        } else if (std.mem.eql(u8, key, "open")) {
            if (val.len > 0) cfg.open_path = allocator.dupe(u8, val) catch null;
        }
    }
    return cfg;
}

/// Write current settings. Best-effort: any I/O error is silently dropped so
/// shutdown can't fail because of disk problems.
pub fn saveConfig(
    io: std.Io,
    path: []const u8,
    threshold: f32,
    show_debug: bool,
    closed_path: []const u8,
    open_path: []const u8,
) void {
    var buf: [path_buf_size * 2 + 256]u8 = undefined;
    const data = std.fmt.bufPrint(
        &buf,
        "threshold={d:.6}\nshow_debug={d}\nclosed={s}\nopen={s}\n",
        .{ threshold, @intFromBool(show_debug), closed_path, open_path },
    ) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch return;
}
