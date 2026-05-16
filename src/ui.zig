//! All on-screen drawing and pointer-input handling.
//!
//! Everything in this module talks to raylib. Callers own the underlying
//! state (threshold, debug toggle, image slots, audio level) and pass it in
//! each frame; the UI mutates values through pointer parameters where the
//! widget owns the interaction (slider, checkbox).

const std = @import("std");

const rl = @import("c.zig").rl;
const ImageSlot = @import("image.zig").ImageSlot;

/// Draw `tex` centred in a `sw` x `sh` viewport, preserving aspect ratio.
pub fn drawAvatar(sw: f32, sh: f32, tex: rl.Texture2D) void {
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

/// Thin horizontal bar across the top of the screen showing the current
/// mic level (green fill) and threshold (red tick).
pub fn drawDebugBar(sw: f32, level: f32, threshold: f32) void {
    const bar_w = sw - 40;
    rl.DrawRectangle(20, 20, @intFromFloat(bar_w), 10, rl.LIGHTGRAY);
    rl.DrawRectangle(20, 20, @intFromFloat(bar_w * @min(level, 1.0)), 10, rl.DARKGREEN);
    const tx: i32 = @intFromFloat(20 + bar_w * @min(threshold, 1.0));
    rl.DrawRectangle(tx, 16, 2, 18, rl.RED);
}

/// Settings menu. Holds interaction state that needs to persist across
/// frames (slider drag, last-frame slot rectangles for drop hit-testing).
pub const Menu = struct {
    /// True while the user is dragging the sensitivity slider's handle.
    dragging_sensitivity: bool = false,
    /// Rectangles of the two image-slot drop targets, in screen space.
    /// Set by `draw` and read by `slotAtPoint`. Zero-sized before the first
    /// draw or while the menu is closed.
    slot_rects: [2]rl.Rectangle = .{
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    },

    /// Returns the slot index (0 = closed, 1 = open) whose drop target
    /// contains `point`, based on the last `draw` call. Null if none.
    pub fn slotAtPoint(self: *const Menu, point: rl.Vector2) ?usize {
        for (self.slot_rects, 0..) |rect, i| {
            if (rl.CheckCollisionPointRec(point, rect)) return i;
        }
        return null;
    }

    /// Draws the settings menu as a centred panel with a translucent dim
    /// behind it. Mutates `threshold` / `show_debug` if the user interacts
    /// with the sensitivity slider or the debug-meter checkbox.
    pub fn draw(
        self: *Menu,
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

        // Panel sized to a fraction of the window, clamped so it stays
        // readable on small windows and doesn't sprawl on big ones. Minimum
        // height is set so the two image-slot rows always fit comfortably.
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

        const mouse = rl.GetMousePosition();
        const margin: f32 = 24;

        const cb_y = drawSensitivity(self, px, py, pw, margin, live_level, threshold, mouse);
        drawDebugCheckbox(px, cb_y, margin, show_debug, mouse);
        drawImageSlots(self, px, pw, cb_y, margin, closed_slot, open_slot, mouse);

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
};

/// Mic sensitivity slider + live level meter. Returns the y of the next
/// widget row (the debug checkbox), so the menu doesn't have to redo the
/// vertical math itself.
fn drawSensitivity(
    menu: *Menu,
    px: f32,
    py: f32,
    pw: f32,
    margin: f32,
    live_level: f32,
    threshold: *f32,
    mouse: rl.Vector2,
) f32 {
    // Label + slider laid out with a small horizontal margin inside the panel.
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
    if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT) and rl.CheckCollisionPointRec(mouse, hit)) {
        menu.dragging_sensitivity = true;
    }
    if (!rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
        menu.dragging_sensitivity = false;
    }
    if (menu.dragging_sensitivity) {
        const nt = (mouse.x - track.x) / track.width;
        threshold.* = std.math.clamp(nt, 0, 1);
    }

    const handle_color: rl.Color = if (menu.dragging_sensitivity) rl.SKYBLUE else rl.RAYWHITE;
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

    return py + 150;
}

/// Debug-meter toggle. Click anywhere along the label row, not just on the
/// 20px box, so the hit target isn't fiddly.
fn drawDebugCheckbox(
    px: f32,
    cb_y: f32,
    margin: f32,
    show_debug: *bool,
    mouse: rl.Vector2,
) void {
    const cb_label = "Show debug voice meter";
    const cb_size: i32 = 18;
    const box_side: f32 = 20;
    const box = rl.Rectangle{
        .x = px + margin,
        .y = cb_y,
        .width = box_side,
        .height = box_side,
    };

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
}

/// Two stacked drop-target rows for the closed/open avatar images. Publishes
/// the rectangles into `menu.slot_rects` so the drop dispatcher in `main`
/// can hit-test them on the following frame.
fn drawImageSlots(
    menu: *Menu,
    px: f32,
    pw: f32,
    cb_y: f32,
    margin: f32,
    closed_slot: *const ImageSlot,
    open_slot: *const ImageSlot,
    mouse: rl.Vector2,
) void {
    const box_side: f32 = 20;
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
        menu.slot_rects[i_slot] = row;

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
}
