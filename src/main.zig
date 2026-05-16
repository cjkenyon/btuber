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

// A single user-selected image (closed-mouth or open-mouth) along with the
// path it came from. We keep the path inline as a fixed-size, null-terminated
// buffer so we can hand it straight to raylib's C API without allocating.
const path_buf_size = 4096;
const ImageSlot = struct {
    tex: rl.Texture2D = .{ .id = 0, .width = 0, .height = 0, .mipmaps = 0, .format = 0 },
    path_buf: [path_buf_size]u8 = [_]u8{0} ** path_buf_size,
    path_len: usize = 0,

    fn pathSlice(self: *const ImageSlot) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

/// Try to load `path` as the slot's image. On success the slot's old texture
/// (if any) is unloaded and replaced. On failure the slot is left unchanged.
fn slotLoadFrom(slot: *ImageSlot, path: []const u8) bool {
    if (path.len >= slot.path_buf.len) return false;
    // Load via a scratch buffer first so a failed load doesn't trample the
    // slot's existing path.
    var tmp: [path_buf_size]u8 = undefined;
    @memcpy(tmp[0..path.len], path);
    tmp[path.len] = 0;
    const new_tex = rl.LoadTexture(@ptrCast(&tmp));
    if (new_tex.id == 0) return false;
    if (slot.tex.id != 0) rl.UnloadTexture(slot.tex);
    slot.tex = new_tex;
    @memcpy(slot.path_buf[0..path.len], path);
    slot.path_buf[path.len] = 0;
    slot.path_len = path.len;
    return true;
}

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

    // CLI image paths are optional: when omitted, the settings menu lets the
    // user pick images interactively. If they're given they form the initial
    // state of the two slots.
    const initial_closed: ?[]const u8 = if (positionals.items.len >= 1) positionals.items[0] else null;
    const initial_open: ?[]const u8 = if (positionals.items.len >= 2) positionals.items[1] else null;

    var threshold: f32 = 0.05;
    if (positionals.items.len >= 3) {
        threshold = std.fmt.parseFloat(f32, positionals.items[2]) catch threshold;
    }

    // Mutable so the settings menu's slider can write to it. The capture
    // callback only reads it indirectly via the main thread comparing against
    // `g_mic_level`, so no atomics are needed.

    // ---- raylib window + textures ----
    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    rl.InitWindow(800, 600, "btuber");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);
    // We use Esc to toggle the settings menu, so disable raylib's default
    // "Esc closes the window" behaviour.
    rl.SetExitKey(rl.KEY_NULL);

    // Slots start empty and are filled from the CLI args if provided; the
    // user can later replace them via the settings menu.
    var closed_slot: ImageSlot = .{};
    defer if (closed_slot.tex.id != 0) rl.UnloadTexture(closed_slot.tex);
    var open_slot: ImageSlot = .{};
    defer if (open_slot.tex.id != 0) rl.UnloadTexture(open_slot.tex);

    if (initial_closed) |p| {
        if (!slotLoadFrom(&closed_slot, p)) {
            std.debug.print("failed to load closed image: {s}\n", .{p});
        }
    }
    if (initial_open) |p| {
        if (!slotLoadFrom(&open_slot, p)) {
            std.debug.print("failed to load open image: {s}\n", .{p});
        }
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
    var menu_open = false;
    while (!rl.WindowShouldClose()) {
        // Esc toggles the settings menu. We intercept it before raylib's
        // default "Esc closes the window" behaviour by clearing the exit key
        // once, below.
        if (rl.IsKeyPressed(rl.KEY_ESCAPE)) menu_open = !menu_open;

        const level = g_mic_level.load(.monotonic);
        const talking = level > threshold;
        // Pick the slot for this frame; if it's empty, fall back to the other
        // so we still show something once at least one image is set.
        const primary = if (talking) &open_slot else &closed_slot;
        const fallback = if (talking) &closed_slot else &open_slot;
        const draw_tex: ?rl.Texture2D = if (primary.tex.id != 0)
            primary.tex
        else if (fallback.tex.id != 0) fallback.tex else null;

        rl.BeginDrawing();
        defer rl.EndDrawing();
        rl.ClearBackground(rl.RAYWHITE);

        const sw: f32 = @floatFromInt(rl.GetScreenWidth());
        const sh: f32 = @floatFromInt(rl.GetScreenHeight());
        if (draw_tex) |tex| {
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
        }

        if (show_debug) {
            // Little debug bar showing mic level vs. threshold.
            const bar_w = sw - 40;
            rl.DrawRectangle(20, 20, @intFromFloat(bar_w), 10, rl.LIGHTGRAY);
            rl.DrawRectangle(20, 20, @intFromFloat(bar_w * @min(level, 1.0)), 10, rl.DARKGREEN);
            const tx: i32 = @intFromFloat(20 + bar_w * @min(threshold, 1.0));
            rl.DrawRectangle(tx, 16, 2, 18, rl.RED);
        }

        if (menu_open) drawSettingsMenu(sw, sh, &threshold, &show_debug);
    }
}

/// Persistent UI state for the settings menu. Lives at module scope because
/// the menu is drawn from a free function and we want drag state to survive
/// across frames without plumbing a struct through.
const MenuState = struct {
    /// True while the user is dragging the sensitivity slider's handle.
    dragging_sensitivity: bool = false,
};
var menu_state: MenuState = .{};

/// Draws the settings menu as a centred panel with a translucent dim behind
/// it. Mutates `threshold` if the user interacts with the sensitivity slider.
fn drawSettingsMenu(sw: f32, sh: f32, threshold: *f32, show_debug: *bool) void {
    // Dim the scene behind the panel.
    rl.DrawRectangle(
        0,
        0,
        @intFromFloat(sw),
        @intFromFloat(sh),
        .{ .r = 0, .g = 0, .b = 0, .a = 160 },
    );

    // Panel sized to a fraction of the window, clamped so it stays readable
    // on small windows and doesn't sprawl on big ones.
    const pw = std.math.clamp(sw * 0.6, 320, 640);
    const ph = std.math.clamp(sh * 0.6, 240, 480);
    const px = (sw - pw) * 0.5;
    const py = (sh - ph) * 0.5;

    const panel = rl.Rectangle{ .x = px, .y = py, .width = pw, .height = ph };
    rl.DrawRectangleRec(panel, .{ .r = 30, .g = 30, .b = 36, .a = 240 });
    rl.DrawRectangleLinesEx(panel, 2, rl.LIGHTGRAY);

    const title = "Settings";
    const title_size: i32 = 28;
    const title_w = rl.MeasureText(title, title_size);
    rl.DrawText(
        title,
        @intFromFloat(px + (pw - @as(f32, @floatFromInt(title_w))) * 0.5),
        @intFromFloat(py + 20),
        title_size,
        rl.RAYWHITE,
    );

    // ---- Microphone sensitivity slider ----
    // Label + slider laid out with a small horizontal margin inside the panel.
    const margin: f32 = 24;
    const label = "Microphone sensitivity";
    const label_size: i32 = 18;
    const label_y = py + 70;
    rl.DrawText(
        label,
        @intFromFloat(px + margin),
        @intFromFloat(label_y),
        label_size,
        rl.RAYWHITE,
    );

    // Numeric readout right-aligned on the same row.
    var val_buf: [16]u8 = undefined;
    const val_text = std.fmt.bufPrintZ(&val_buf, "{d:.3}", .{threshold.*}) catch "?";
    const val_w = rl.MeasureText(val_text.ptr, label_size);
    rl.DrawText(
        val_text.ptr,
        @intFromFloat(px + pw - margin - @as(f32, @floatFromInt(val_w))),
        @intFromFloat(label_y),
        label_size,
        rl.LIGHTGRAY,
    );

    // Track is a thin rounded rectangle; handle is a filled circle on top.
    // Slider value maps the full 0..1 range, matching the debug bar's scale.
    const track = rl.Rectangle{
        .x = px + margin,
        .y = label_y + 34,
        .width = pw - margin * 2,
        .height = 6,
    };
    rl.DrawRectangleRec(track, rl.DARKGRAY);

    const t = std.math.clamp(threshold.*, 0, 1);
    const handle_x = track.x + track.width * t;
    const handle_y = track.y + track.height * 0.5;
    const handle_r: f32 = 10;

    // Hit area is generously taller than the track itself so the slider is
    // easy to grab without pixel-hunting.
    const hit = rl.Rectangle{
        .x = track.x - handle_r,
        .y = track.y - handle_r,
        .width = track.width + handle_r * 2,
        .height = track.height + handle_r * 2,
    };
    const mouse = rl.GetMousePosition();
    if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT) and rl.CheckCollisionPointRec(mouse, hit)) {
        menu_state.dragging_sensitivity = true;
    }
    if (!rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
        menu_state.dragging_sensitivity = false;
    }
    if (menu_state.dragging_sensitivity) {
        const nt = (mouse.x - track.x) / track.width;
        threshold.* = std.math.clamp(nt, 0, 1);
    }

    const handle_color: rl.Color = if (menu_state.dragging_sensitivity) rl.SKYBLUE else rl.RAYWHITE;
    rl.DrawCircleV(.{ .x = handle_x, .y = handle_y }, handle_r, handle_color);

    // Tiny live mic-level indicator under the track so the user can see what
    // their current threshold is being compared against while adjusting.
    const meter = rl.Rectangle{
        .x = track.x,
        .y = track.y + 18,
        .width = track.width,
        .height = 4,
    };
    rl.DrawRectangleRec(meter, .{ .r = 60, .g = 60, .b = 70, .a = 255 });
    const live = std.math.clamp(g_mic_level.load(.monotonic), 0, 1);
    rl.DrawRectangle(
        @intFromFloat(meter.x),
        @intFromFloat(meter.y),
        @intFromFloat(meter.width * live),
        @intFromFloat(meter.height),
        rl.DARKGREEN,
    );

    // ---- Debug voice meter checkbox ----
    const cb_label = "Show debug voice meter";
    const cb_size: i32 = 18;
    const cb_y = py + 150;
    const box_side: f32 = 20;
    const box = rl.Rectangle{
        .x = px + margin,
        .y = cb_y,
        .width = box_side,
        .height = box_side,
    };

    // Toggle on click anywhere along the label row (box + text), so the hit
    // target isn't a tiny 20px square.
    const cb_label_w = rl.MeasureText(cb_label, cb_size);
    const cb_hit = rl.Rectangle{
        .x = box.x,
        .y = box.y,
        .width = box_side + 10 + @as(f32, @floatFromInt(cb_label_w)),
        .height = box_side,
    };
    if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT) and rl.CheckCollisionPointRec(mouse, cb_hit)) {
        show_debug.* = !show_debug.*;
    }

    rl.DrawRectangleRec(box, .{ .r = 50, .g = 50, .b = 58, .a = 255 });
    rl.DrawRectangleLinesEx(box, 2, rl.LIGHTGRAY);
    if (show_debug.*) {
        // Inset filled square as the "check" mark. Keeps us from needing a
        // glyph font for a tick character.
        const inset: f32 = 5;
        rl.DrawRectangle(
            @intFromFloat(box.x + inset),
            @intFromFloat(box.y + inset),
            @intFromFloat(box_side - inset * 2),
            @intFromFloat(box_side - inset * 2),
            rl.SKYBLUE,
        );
    }
    rl.DrawText(
        cb_label,
        @intFromFloat(box.x + box_side + 10),
        @intFromFloat(box.y + (box_side - @as(f32, @floatFromInt(cb_size))) * 0.5),
        cb_size,
        rl.RAYWHITE,
    );

    const close_hint = "Esc to close";
    const close_size: i32 = 16;
    const close_w = rl.MeasureText(close_hint, close_size);
    rl.DrawText(
        close_hint,
        @intFromFloat(px + (pw - @as(f32, @floatFromInt(close_w))) * 0.5),
        @intFromFloat(py + ph - 30),
        close_size,
        rl.LIGHTGRAY,
    );
}
