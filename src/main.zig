const std = @import("std");

const rl = @import("c.zig").rl;
const audio = @import("audio.zig");
const config = @import("config.zig");
const ui = @import("ui.zig");
const ImageSlot = @import("image.zig").ImageSlot;

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
    var bg_color: rl.Color = .{ .r = cfg.bg_r, .g = cfg.bg_g, .b = cfg.bg_b, .a = 255 };

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
    defer closed_slot.unload();
    var open_slot: ImageSlot = .{};
    defer open_slot.unload();

    if (initial_closed) |p| {
        if (!closed_slot.loadFrom(p)) {
            std.debug.print("failed to load closed image: {s}\n", .{p});
        }
    }
    if (initial_open) |p| {
        if (!open_slot.loadFrom(p)) {
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
        bg_color.r,
        bg_color.g,
        bg_color.b,
    );

    // ---- main loop ----
    var menu: ui.Menu = .{};
    // Auto-open the menu on first launch when either image is missing, so the
    // user immediately sees the drop targets instead of a blank window.
    var menu_open = !closed_slot.hasTexture() or !open_slot.hasTexture();
    while (!rl.WindowShouldClose()) {
        // Esc toggles the menu, except when the menu itself is consuming
        // keyboard input (e.g. the user is typing into a text field); in
        // that case Esc is the cancel key for the field instead.
        if (rl.IsKeyPressed(rl.KEY_ESCAPE) and !menu.wantsKeyboard()) menu_open = !menu_open;

        // Drag-and-drop: if any files were dropped this frame and the menu is
        // open, route the first dropped path to whichever slot the cursor is
        // over. The menu published its slot rects on the previous frame.
        if (rl.IsFileDropped()) {
            const files = rl.LoadDroppedFiles();
            defer rl.UnloadDroppedFiles(files);
            if (menu_open and files.count > 0) {
                if (menu.slotAtPoint(rl.GetMousePosition())) |i| {
                    const c_path: [*:0]const u8 = @ptrCast(files.paths[0]);
                    const path = std.mem.sliceTo(c_path, 0);
                    const slot = if (i == 0) &closed_slot else &open_slot;
                    if (!slot.loadFrom(path)) {
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
        const draw_tex: ?rl.Texture2D = if (primary.hasTexture())
            primary.tex
        else if (fallback.hasTexture()) fallback.tex else null;

        rl.BeginDrawing();
        defer rl.EndDrawing();
        rl.ClearBackground(bg_color);

        const sw: f32 = @floatFromInt(rl.GetScreenWidth());
        const sh: f32 = @floatFromInt(rl.GetScreenHeight());
        if (draw_tex) |tex| ui.drawAvatar(sw, sh, tex);
        if (show_debug) ui.drawDebugBar(sw, level, threshold);
        if (menu_open) menu.draw(sw, sh, level, &threshold, &show_debug, &bg_color, &closed_slot, &open_slot);
    }
}
