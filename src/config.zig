const std = @import("std");

const path_buf_size = std.Io.Dir.max_path_bytes;

/// Persisted user settings. Paths point into the arena (or are null if not
/// set yet). Defaults match the previous hard-coded values.
pub const Config = struct {
    threshold: f32 = 0.05,
    show_debug: bool = false,
    closed_path: ?[]const u8 = null,
    open_path: ?[]const u8 = null,
    /// Background clear color. Defaults to raylib's RAYWHITE.
    bg_r: u8 = 245,
    bg_g: u8 = 245,
    bg_b: u8 = 245,
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
        } else if (std.mem.eql(u8, key, "bg_color")) {
            // Format: "r,g,b" with each component 0..255. Silently keep
            // defaults on any parse failure.
            var parts = std.mem.splitScalar(u8, val, ',');
            const rs = parts.next() orelse continue;
            const gs = parts.next() orelse continue;
            const bs = parts.next() orelse continue;
            const r = std.fmt.parseInt(u8, std.mem.trim(u8, rs, " \t"), 10) catch continue;
            const g = std.fmt.parseInt(u8, std.mem.trim(u8, gs, " \t"), 10) catch continue;
            const b = std.fmt.parseInt(u8, std.mem.trim(u8, bs, " \t"), 10) catch continue;
            cfg.bg_r = r;
            cfg.bg_g = g;
            cfg.bg_b = b;
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
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
) void {
    var buf: [path_buf_size * 2 + 256]u8 = undefined;
    const data = std.fmt.bufPrint(
        &buf,
        "threshold={d:.6}\nshow_debug={d}\nclosed={s}\nopen={s}\nbg_color={d},{d},{d}\n",
        .{ threshold, @intFromBool(show_debug), closed_path, open_path, bg_r, bg_g, bg_b },
    ) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch return;
}
