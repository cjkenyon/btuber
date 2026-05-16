//! A single user-selected avatar image (closed-mouth or open-mouth) along
//! with the path it came from. The path is kept inline as a fixed-size,
//! null-terminated buffer so we can hand it straight to raylib's C API
//! without allocating.

const rl = @import("c.zig").rl;

pub const path_buf_size = 4096;

pub const ImageSlot = struct {
    tex: rl.Texture2D = .{ .id = 0, .width = 0, .height = 0, .mipmaps = 0, .format = 0 },
    path_buf: [path_buf_size]u8 = [_]u8{0} ** path_buf_size,
    path_len: usize = 0,

    pub fn pathSlice(self: *const ImageSlot) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// True iff a texture has been successfully loaded into this slot.
    pub fn hasTexture(self: *const ImageSlot) bool {
        return self.tex.id != 0;
    }

    /// Try to load `path` as the slot's image. On success the slot's old
    /// texture (if any) is unloaded and replaced. On failure the slot is
    /// left unchanged.
    pub fn loadFrom(self: *ImageSlot, path: []const u8) bool {
        if (path.len >= self.path_buf.len) return false;
        // Load via a scratch buffer first so a failed load doesn't trample
        // the slot's existing path.
        var tmp: [path_buf_size]u8 = undefined;
        @memcpy(tmp[0..path.len], path);
        tmp[path.len] = 0;
        const new_tex = rl.LoadTexture(@ptrCast(&tmp));
        if (new_tex.id == 0) return false;
        if (self.tex.id != 0) rl.UnloadTexture(self.tex);
        self.tex = new_tex;
        @memcpy(self.path_buf[0..path.len], path);
        self.path_buf[path.len] = 0;
        self.path_len = path.len;
        return true;
    }

    /// Free the GPU texture, if any. Safe to call on an empty slot.
    pub fn unload(self: *ImageSlot) void {
        if (self.tex.id != 0) {
            rl.UnloadTexture(self.tex);
            self.tex = .{ .id = 0, .width = 0, .height = 0, .mipmaps = 0, .format = 0 };
        }
    }
};
