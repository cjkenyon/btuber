const std = @import("std");
const btuber = @import("btuber");

const raylib = @cImport({
    @cInclude("raylib.h");
});

pub fn main() !void {
    raylib.InitWindow(800, 600, "btuber");
    defer raylib.CloseWindow();

    raylib.SetTargetFPS(60);

    while (!raylib.WindowShouldClose()) {
        raylib.BeginDrawing();
        defer raylib.EndDrawing();

        raylib.ClearBackground(raylib.RAYWHITE);
        raylib.DrawText("Welcome to btuber!", 20, 20, 24, raylib.BLACK);
    }
}
