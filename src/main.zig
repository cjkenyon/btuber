const std = @import("std");

const rl = @import("c.zig").rl;
const audio = @import("audio.zig");
const config = @import("config.zig");

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

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var positionals = try std.ArrayList([:0]const u8).initCapacity(arena, args.len);
    var show_debug_cli: ?bool = null;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--debug") or std.mem.eql(u8, a, "-d")) {
            show_debug_cli = true;
        } else {
            try positionals.append(arena, a);
        }
    }

    // Load persisted settings first; CLI args (if any) override them for this
    // run and will then be saved back on exit.
    const cfg: config.Config = config.loadConfig(arena, init.io, config.config_file_name);

    const initial_closed: ?[]const u8 = if (positionals.items.len >= 1)
        positionals.items[0]
    else
        cfg.closed_path;
    const initial_open: ?[]const u8 = if (positionals.items.len >= 2)
        positionals.items[1]
    else
        cfg.open_path;

    var threshold: f32 = cfg.threshold;
    if (positionals.items.len >= 3) {
        threshold = std.fmt.parseFloat(f32, positionals.items[2]) catch threshold;
    }
    var show_debug = show_debug_cli orelse cfg.show_debug;

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

    // Image slots are populated from CLI args (if provided) and otherwise
    // start empty; the user fills them in by dragging files onto the menu.
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

    // ---- microphone capture ----
    // miniaudio keeps internal pointers into `ma_device`, so `capture` must
    // live at a stable address; declaring it here and initialising in place
    // keeps it pinned to this stack frame for the lifetime of the program.
    var capture: audio.Capture = undefined;
    capture.init() catch |err| {
        std.debug.print("failed to init capture device: {s}\n", .{@errorName(err)});
        return err;
    };
    defer capture.deinit();
    capture.start() catch |err| {
        std.debug.print("failed to start capture device: {s}\n", .{@errorName(err)});
        return err;
    };

    // Persist settings on exit, into a file alongside the process's current
    // working directory.
    defer config.saveConfig(
        init.io,
        config.config_file_name,
        threshold,
        show_debug,
        closed_slot.pathSlice(),
        open_slot.pathSlice(),
    );

    // ---- main loop ----
    // Auto-open the menu on first launch when either image is missing, so the
    // user immediately sees the drop targets instead of a blank window.
    var menu_open = closed_slot.tex.id == 0 or open_slot.tex.id == 0;
    while (!rl.WindowShouldClose()) {
        // Esc toggles the settings menu. We intercept it before raylib's
        // default "Esc closes the window" behaviour by clearing the exit key
        // once, below.
        if (rl.IsKeyPressed(rl.KEY_ESCAPE)) menu_open = !menu_open;

        // Drag-and-drop: if any files were dropped this frame and the menu is
        // open, use the cursor position to figure out which slot to assign
        // the first dropped path to. Slot rectangles are published by
        // `drawSettingsMenu` the previous frame.
        if (rl.IsFileDropped()) {
            const files = rl.LoadDroppedFiles();
            defer rl.UnloadDroppedFiles(files);
            if (menu_open and files.count > 0) {
                const mouse_pos = rl.GetMousePosition();
                var hit_idx: ?usize = null;
                for (menu_state.slot_rects, 0..) |rect, i| {
                    if (rl.CheckCollisionPointRec(mouse_pos, rect)) {
                        hit_idx = i;
                        break;
                    }
                }
                if (hit_idx) |i| {
                    const c_path: [*:0]const u8 = @ptrCast(files.paths[0]);
                    const path = std.mem.sliceTo(c_path, 0);
                    const slot = if (i == 0) &closed_slot else &open_slot;
                    if (!slotLoadFrom(slot, path)) {
                        std.debug.print("failed to load image: {s}\n", .{path});
                    }
                }
            }
        }

        const level = capture.level();
        const talking = level > threshold;
        // Pick the slot for this frame; if it's empty, fall back to the other
        // one so we still show *something* once at least one image is set.
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

        if (menu_open) drawSettingsMenu(sw, sh, level, &threshold, &show_debug, &closed_slot, &open_slot);
    }
}

/// Persistent UI state for the settings menu. Lives at module scope because
/// the menu is drawn from a free function and we want drag state to survive
/// across frames without plumbing a struct through.
const MenuState = struct {
    /// True while the user is dragging the sensitivity slider's handle.
    dragging_sensitivity: bool = false,
    /// Rectangles of the two image-slot drop targets, in screen space.
    /// Published by `drawSettingsMenu` each frame and read by the drop
    /// handler in `main`. Zero-sized when the menu isn't drawn.
    slot_rects: [2]rl.Rectangle = .{
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    },
};
var menu_state: MenuState = .{};

/// Draws the settings menu as a centred panel with a translucent dim behind
/// it. Mutates `threshold` if the user interacts with the sensitivity slider.
fn drawSettingsMenu(
    sw: f32,
    sh: f32,
    live_level: f32,
    threshold: *f32,
    show_debug: *bool,
    closed_slot: *const ImageSlot,
    open_slot: *const ImageSlot,
) void {
    // Dim the scene behind the panel.
    rl.DrawRectangle(
        0,
        0,
        @intFromFloat(sw),
        @intFromFloat(sh),
        .{ .r = 0, .g = 0, .b = 0, .a = 160 },
    );

    // Panel sized to a fraction of the window, clamped so it stays readable
    // on small windows and doesn't sprawl on big ones. Minimum height is set
    // so the two image-slot rows always fit comfortably.
    const pw = std.math.clamp(sw * 0.6, 360, 640);
    const ph = std.math.clamp(sh * 0.7, 380, 560);
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
    const live = std.math.clamp(live_level, 0, 1);
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

    // ---- Image slots (drag & drop) ----
    const slot_h: f32 = 64;
    const slot_gap: f32 = 8;
    const slots_y = cb_y + box_side + 20;
    var i_slot: usize = 0;
    while (i_slot < 2) : (i_slot += 1) {
        const slot: *const ImageSlot = if (i_slot == 0) closed_slot else open_slot;
        const slot_label: [:0]const u8 = if (i_slot == 0) "Closed image" else "Open image";
        const row = rl.Rectangle{
            .x = px + margin,
            .y = slots_y + (slot_h + slot_gap) * @as(f32, @floatFromInt(i_slot)),
            .width = pw - margin * 2,
            .height = slot_h,
        };
        menu_state.slot_rects[i_slot] = row;

        // Highlight on hover so it's obvious this is a drop target.
        const hover = rl.CheckCollisionPointRec(mouse, row);
        const bg: rl.Color = if (hover)
            .{ .r = 55, .g = 60, .b = 75, .a = 255 }
        else
            .{ .r = 45, .g = 48, .b = 55, .a = 255 };
        rl.DrawRectangleRec(row, bg);
        rl.DrawRectangleLinesEx(row, 1, if (hover) rl.SKYBLUE else rl.GRAY);

        // Left side: kind label + current filename (or placeholder).
        rl.DrawText(
            slot_label.ptr,
            @intFromFloat(row.x + 10),
            @intFromFloat(row.y + 8),
            14,
            rl.LIGHTGRAY,
        );
        if (slot.path_len == 0) {
            rl.DrawText(
                "drag an image here",
                @intFromFloat(row.x + 10),
                @intFromFloat(row.y + 30),
                16,
                rl.GRAY,
            );
        } else {
            // basename isn't null-terminated, so copy it into a scratch buf
            // before handing to raylib's C-string text API.
            const base = std.fs.path.basename(slot.pathSlice());
            var name_buf: [256]u8 = undefined;
            const n = @min(base.len, name_buf.len - 1);
            @memcpy(name_buf[0..n], base[0..n]);
            name_buf[n] = 0;
            rl.DrawText(
                @ptrCast(&name_buf),
                @intFromFloat(row.x + 10),
                @intFromFloat(row.y + 30),
                16,
                rl.RAYWHITE,
            );
        }

        // Right side: small aspect-preserving thumbnail when an image is set.
        if (slot.tex.id != 0) {
            const thumb_h: f32 = slot_h - 12;
            const tw_f: f32 = @floatFromInt(slot.tex.width);
            const th_f: f32 = @floatFromInt(slot.tex.height);
            const tscale = thumb_h / th_f;
            const tdw = tw_f * tscale;
            const thumb_dst = rl.Rectangle{
                .x = row.x + row.width - tdw - 6,
                .y = row.y + 6,
                .width = tdw,
                .height = thumb_h,
            };
            rl.DrawTexturePro(
                slot.tex,
                .{ .x = 0, .y = 0, .width = tw_f, .height = th_f },
                thumb_dst,
                .{ .x = 0, .y = 0 },
                0,
                rl.WHITE,
            );
        }
    }

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
