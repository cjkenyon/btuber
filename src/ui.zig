//! All on-screen drawing and pointer-input handling.
//!
//! Everything in this module talks to raylib. Callers own the underlying
//! state (threshold, debug toggle, image slots, audio level) and pass it in
//! each frame; the UI mutates values through pointer parameters where the
//! widget owns the interaction (slider, checkbox).

const std = @import("std");

const rl = @import("c.zig").rl;
const ImageSlot = @import("image.zig").ImageSlot;
const build_options = @import("build_options");

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
    /// True while the user is typing into the sensitivity readout.
    /// While set, the readout becomes a text input and `edit_buf[0..edit_len]`
    /// is the in-progress text; the underlying threshold isn't updated until
    /// the edit is committed (Enter or click-outside).
    editing_sensitivity: bool = false,
    /// Scratch storage for the in-progress text. 16 bytes comfortably fits
    /// any reasonable 0..1 decimal value plus a few extra digits the user
    /// might type before committing.
    edit_buf: [16]u8 = undefined,
    edit_len: usize = 0,
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

    /// True when the menu is currently consuming keyboard input (e.g. the
    /// user is typing into the sensitivity readout). Callers should suppress
    /// their own global keybindings (notably Esc-to-toggle) while this is set.
    pub fn wantsKeyboard(self: *const Menu) bool {
        return self.editing_sensitivity;
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
        bg_color: *rl.Color,
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
        const bg_y = cb_y + 40;
        const slots_y = drawBackgroundPicker(px, pw, bg_y, margin, bg_color, mouse);
        drawImageSlots(self, px, pw, slots_y, margin, closed_slot, open_slot, mouse);

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

        // Version string, tucked into the bottom-right of the panel so the
        // user can tell which build they're running. Buffered into a
        // null-terminated stack array since raylib wants a C string and the
        // build_options slice isn't sentinel-terminated.
        var version_buf: [128]u8 = undefined;
        const version = std.fmt.bufPrintZ(&version_buf, "v{s}", .{build_options.version}) catch "v?";
        const version_size: i32 = 12;
        const version_w = rl.MeasureText(version.ptr, version_size);
        rl.DrawText(
            version.ptr,
            @intFromFloat(px + pw - @as(f32, @floatFromInt(version_w)) - 10),
            @intFromFloat(py + ph - 18),
            version_size,
            rl.GRAY,
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

    // Numeric readout right-aligned on the same row. Doubles as a text
    // input: click it to type a value directly.
    const input_rect = drawSensitivityInput(menu, px, pw, margin, label_y, label_size, threshold, mouse);

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
    const click_in_input = rl.CheckCollisionPointRec(mouse, input_rect);
    if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT) and !click_in_input and rl.CheckCollisionPointRec(mouse, hit)) {
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

/// Numeric readout / text input for the sensitivity threshold. Returns the
/// rectangle it occupied so the slider hit-test can ignore clicks landing on
/// the input. Mutates `threshold` when an edit is committed (Enter or
/// click-outside); cancels on Escape without touching `threshold`.
fn drawSensitivityInput(
    menu: *Menu,
    px: f32,
    pw: f32,
    margin: f32,
    label_y: f32,
    label_size: i32,
    threshold: *f32,
    mouse: rl.Vector2,
) rl.Rectangle {
    // Text shown in the input: either the in-progress edit buffer or a
    // formatted snapshot of the current threshold.
    var snap_buf: [16]u8 = undefined;
    const text: [:0]const u8 = if (menu.editing_sensitivity) blk: {
        menu.edit_buf[menu.edit_len] = 0;
        break :blk menu.edit_buf[0..menu.edit_len :0];
    } else std.fmt.bufPrintZ(&snap_buf, "{d:.3}", .{threshold.*}) catch "?";

    // Size the input box around the widest of the current text or a typical
    // "0.000" so it doesn't jitter on every keystroke.
    const sample_w = rl.MeasureText("0.000", label_size);
    const text_w = rl.MeasureText(text.ptr, label_size);
    const inner_w: f32 = @floatFromInt(@max(sample_w, text_w));
    const pad_x: f32 = 6;
    const pad_y: f32 = 3;
    const box_h = @as(f32, @floatFromInt(label_size)) + pad_y * 2;
    const box = rl.Rectangle{
        .x = px + pw - margin - inner_w - pad_x * 2,
        .y = label_y - pad_y,
        .width = inner_w + pad_x * 2,
        .height = box_h,
    };

    // ---- mouse handling ----
    const hovering = rl.CheckCollisionPointRec(mouse, box);
    if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
        if (hovering and !menu.editing_sensitivity) {
            // Enter edit mode, seeding the buffer with the current value.
            var seed_buf: [16]u8 = undefined;
            const seed = std.fmt.bufPrint(&seed_buf, "{d:.3}", .{threshold.*}) catch "";
            const n = @min(seed.len, menu.edit_buf.len - 1);
            @memcpy(menu.edit_buf[0..n], seed[0..n]);
            menu.edit_len = n;
            menu.editing_sensitivity = true;
        } else if (!hovering and menu.editing_sensitivity) {
            commitSensitivityEdit(menu, threshold);
        }
    }

    // ---- keyboard handling (only while editing) ----
    if (menu.editing_sensitivity) {
        // Accept characters: digits and at most one '.'. Reject anything else.
        while (true) {
            const ch = rl.GetCharPressed();
            if (ch == 0) break;
            if (menu.edit_len >= menu.edit_buf.len - 1) continue;
            const c: u8 = @intCast(ch);
            const is_digit = c >= '0' and c <= '9';
            const is_dot = c == '.' and std.mem.indexOfScalar(u8, menu.edit_buf[0..menu.edit_len], '.') == null;
            if (is_digit or is_dot) {
                menu.edit_buf[menu.edit_len] = c;
                menu.edit_len += 1;
            }
        }
        if (rl.IsKeyPressed(rl.KEY_BACKSPACE) and menu.edit_len > 0) {
            menu.edit_len -= 1;
        }
        if (rl.IsKeyPressed(rl.KEY_ENTER) or rl.IsKeyPressed(rl.KEY_KP_ENTER)) {
            commitSensitivityEdit(menu, threshold);
        } else if (rl.IsKeyPressed(rl.KEY_ESCAPE)) {
            // Cancel: drop the buffer without writing back.
            menu.editing_sensitivity = false;
            menu.edit_len = 0;
        }
    }

    // ---- draw ----
    if (menu.editing_sensitivity) {
        rl.DrawRectangleRec(box, .{ .r = 50, .g = 50, .b = 58, .a = 255 });
        rl.DrawRectangleLinesEx(box, 1, rl.SKYBLUE);
    } else if (hovering) {
        rl.DrawRectangleLinesEx(box, 1, rl.GRAY);
    }
    const text_color: rl.Color = if (menu.editing_sensitivity) rl.RAYWHITE else rl.LIGHTGRAY;
    // Right-align inside the box.
    const text_x = box.x + box.width - pad_x - @as(f32, @floatFromInt(text_w));
    rl.DrawText(text.ptr, @intFromFloat(text_x), @intFromFloat(label_y), label_size, text_color);
    // Blinking caret while editing: ~2 Hz toggle.
    if (menu.editing_sensitivity and @mod(rl.GetTime(), 1.0) < 0.5) {
        const caret_x: i32 = @intFromFloat(text_x + @as(f32, @floatFromInt(text_w)) + 1);
        rl.DrawRectangle(caret_x, @intFromFloat(label_y), 1, label_size, rl.RAYWHITE);
    }

    return box;
}

/// Parse the in-progress edit buffer, clamp to 0..1, write to `threshold`,
/// and leave edit mode. An unparseable buffer just cancels.
fn commitSensitivityEdit(menu: *Menu, threshold: *f32) void {
    if (menu.edit_len > 0) {
        if (std.fmt.parseFloat(f32, menu.edit_buf[0..menu.edit_len])) |v| {
            threshold.* = std.math.clamp(v, 0, 1);
        } else |_| {}
    }
    menu.editing_sensitivity = false;
    menu.edit_len = 0;
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

/// Background color picker: a row of preset swatches the user can click to
/// change the window's clear color. Returns the y at which the following
/// widget row should start.
fn drawBackgroundPicker(
    px: f32,
    pw: f32,
    y: f32,
    margin: f32,
    bg_color: *rl.Color,
    mouse: rl.Vector2,
) f32 {
    const label = "Background";
    const label_size: i32 = 18;
    rl.DrawText(
        label,
        @intFromFloat(px + margin),
        @intFromFloat(y),
        label_size,
        rl.RAYWHITE,
    );

    // Common picks: default white, black, plus three chroma-friendly colors.
    const presets = [_]rl.Color{
        .{ .r = 245, .g = 245, .b = 245, .a = 255 }, // RAYWHITE
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 177, .b = 64, .a = 255 }, // chroma green
        .{ .r = 0, .g = 71, .b = 187, .a = 255 }, // chroma blue
        .{ .r = 255, .g = 0, .b = 255, .a = 255 }, // magenta
    };

    const sw_size: f32 = 24;
    const sw_gap: f32 = 8;
    const row_w = sw_size * presets.len + sw_gap * (presets.len - 1);
    const start_x = px + pw - margin - row_w;
    const sw_y = y - 3;

    for (presets, 0..) |c, i| {
        const sx = start_x + (sw_size + sw_gap) * @as(f32, @floatFromInt(i));
        const rect = rl.Rectangle{ .x = sx, .y = sw_y, .width = sw_size, .height = sw_size };
        rl.DrawRectangleRec(rect, c);
        const selected = c.r == bg_color.r and c.g == bg_color.g and c.b == bg_color.b;
        const hover = rl.CheckCollisionPointRec(mouse, rect);
        const border: rl.Color = if (selected) rl.SKYBLUE else if (hover) rl.RAYWHITE else rl.GRAY;
        const thickness: f32 = if (selected) 2 else 1;
        rl.DrawRectangleLinesEx(rect, thickness, border);
        if (hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
            bg_color.* = c;
        }
    }

    return y + sw_size + 16;
}

/// Two stacked drop-target rows for the closed/open avatar images. Publishes
/// the rectangles into `menu.slot_rects` so the drop dispatcher in `main`
/// can hit-test them on the following frame.
fn drawImageSlots(
    menu: *Menu,
    px: f32,
    pw: f32,
    slots_y: f32,
    margin: f32,
    closed_slot: *const ImageSlot,
    open_slot: *const ImageSlot,
    mouse: rl.Vector2,
) void {
    const slot_h: f32 = 64;
    const slot_gap: f32 = 8;
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
