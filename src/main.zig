const std = @import("std");

const rl = @cImport({
    @cInclude("raylib.h");
});

// We only need miniaudio's declarations; the implementation is statically
// linked into the raylib artifact via raudio.c. Keep the MA_NO_* defines in
// sync with raudio.c so the public declarations we see match the ABI of the
// compiled library.
const ma = @cImport({
    @cDefine("MA_NO_JACK", "");
    @cDefine("MA_NO_WAV", "");
    @cDefine("MA_NO_FLAC", "");
    @cDefine("MA_NO_MP3", "");
    @cDefine("MA_NO_RESOURCE_MANAGER", "");
    @cDefine("MA_NO_NODE_GRAPH", "");
    @cDefine("MA_NO_ENGINE", "");
    @cDefine("MA_NO_GENERATION", "");
    @cInclude("miniaudio.h");
});

// Shared microphone level (0..1, smoothed RMS), updated from the audio
// capture thread and read from the main thread.
var g_mic_level = std.atomic.Value(f32).init(0);

fn captureCallback(
    device: [*c]ma.ma_device,
    output: ?*anyopaque,
    input: ?*const anyopaque,
    frame_count: ma.ma_uint32,
) callconv(.c) void {
    _ = output;
    const channels: usize = device.*.capture.channels;
    const samples: [*]const f32 = @ptrCast(@alignCast(input.?));
    const total = @as(usize, frame_count) * channels;

    if (total == 0) return;

    var sum_sq: f64 = 0;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const s: f64 = samples[i];
        sum_sq += s * s;
    }
    const rms: f32 = @floatCast(@sqrt(sum_sq / @as(f64, @floatFromInt(total))));

    // Simple exponential smoothing against the previous value so the image
    // doesn't strobe on every single buffer.
    const prev = g_mic_level.load(.monotonic);
    const smoothed = prev * 0.6 + rms * 0.4;
    g_mic_level.store(smoothed, .monotonic);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var positionals = try std.ArrayList([:0]const u8).initCapacity(arena, args.len);
    var show_debug = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--debug") or std.mem.eql(u8, a, "-d")) {
            show_debug = true;
        } else {
            try positionals.append(arena, a);
        }
    }

    if (positionals.items.len < 2) {
        std.debug.print(
            "usage: {s} [--debug] <closed.png> <open.png> [threshold=0.05]\n",
            .{args[0]},
        );
        return error.MissingArguments;
    }
    const closed_path = try arena.dupeZ(u8, positionals.items[0]);
    const open_path = try arena.dupeZ(u8, positionals.items[1]);

    var threshold: f32 = 0.05;
    if (positionals.items.len >= 3) {
        threshold = std.fmt.parseFloat(f32, positionals.items[2]) catch threshold;
    }

    // ---- raylib window + textures ----
    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    rl.InitWindow(800, 600, "btuber");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    const tex_closed = rl.LoadTexture(closed_path);
    defer rl.UnloadTexture(tex_closed);
    const tex_open = rl.LoadTexture(open_path);
    defer rl.UnloadTexture(tex_open);

    if (tex_closed.id == 0 or tex_open.id == 0) {
        std.debug.print("failed to load one of the images\n", .{});
        return error.ImageLoadFailed;
    }

    // ---- miniaudio capture ----
    var device_config = ma.ma_device_config_init(ma.ma_device_type_capture);
    device_config.capture.format = ma.ma_format_f32;
    device_config.capture.channels = 1;
    device_config.sampleRate = 44100;
    device_config.dataCallback = captureCallback;

    var device: ma.ma_device = undefined;
    if (ma.ma_device_init(null, &device_config, &device) != ma.MA_SUCCESS) {
        std.debug.print("failed to init capture device\n", .{});
        return error.AudioInitFailed;
    }
    defer ma.ma_device_uninit(&device);

    if (ma.ma_device_start(&device) != ma.MA_SUCCESS) {
        std.debug.print("failed to start capture device\n", .{});
        return error.AudioStartFailed;
    }

    // ---- main loop ----
    while (!rl.WindowShouldClose()) {
        const level = g_mic_level.load(.monotonic);
        const talking = level > threshold;
        const tex = if (talking) tex_open else tex_closed;

        rl.BeginDrawing();
        defer rl.EndDrawing();
        rl.ClearBackground(rl.RAYWHITE);

        const sw: f32 = @floatFromInt(rl.GetScreenWidth());
        const sh: f32 = @floatFromInt(rl.GetScreenHeight());
        const tw: f32 = @floatFromInt(tex.width);
        const th: f32 = @floatFromInt(tex.height);
        const scale = @min(sw / tw, sh / th);
        const dw = tw * scale;
        const dh = th * scale;
        const dx = (sw - dw) * 0.5;
        const dy = (sh - dh) * 0.5;

        const src = rl.Rectangle{ .x = 0, .y = 0, .width = tw, .height = th };
        const dst = rl.Rectangle{ .x = dx, .y = dy, .width = dw, .height = dh };
        rl.DrawTexturePro(tex, src, dst, .{ .x = 0, .y = 0 }, 0, rl.WHITE);

        if (show_debug) {
            // Little debug bar showing mic level vs. threshold.
            const bar_w = sw - 40;
            rl.DrawRectangle(20, 20, @intFromFloat(bar_w), 10, rl.LIGHTGRAY);
            rl.DrawRectangle(20, 20, @intFromFloat(bar_w * @min(level, 1.0)), 10, rl.DARKGREEN);
            const tx: i32 = @intFromFloat(20 + bar_w * @min(threshold, 1.0));
            rl.DrawRectangle(tx, 16, 2, 18, rl.RED);
        }
    }
}
