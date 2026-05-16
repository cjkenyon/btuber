const std = @import("std");

const rl = @cImport({
    @cInclude("raylib.h");
});

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("usage: {s} <image>\n", .{args[0]});
        return error.MissingArguments;
    }
    const image_path = try arena.dupeZ(u8, args[1]);

    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    rl.InitWindow(800, 600, "btuber");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    const tex = rl.LoadTexture(image_path);
    defer rl.UnloadTexture(tex);

    if (tex.id == 0) {
        std.debug.print("failed to load image: {s}\n", .{args[1]});
        return error.ImageLoadFailed;
    }

    while (!rl.WindowShouldClose()) {
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
    }
}
