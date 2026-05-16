//! Microphone capture via miniaudio.
//!
//! miniaudio's implementation is statically linked into the raylib artifact
//! through `raudio.c`. We only need its public declarations here, so we mirror
//! the MA_NO_* defines `raudio.c` uses to keep the ABI in sync.
//!
//! The capture callback runs on miniaudio's audio thread; it computes a
//! smoothed RMS level into a file-scope atomic that the main thread reads via
//! `Capture.level()`. The callback has `callconv(.c)` and can't capture
//! context, so the level necessarily lives at file scope rather than inside
//! `Capture`. If multiple captures are ever needed, route through
//! `device.pUserData` instead.

const std = @import("std");

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

/// Smoothed RMS microphone level in roughly 0..1. Written from the audio
/// thread, read from the main thread.
var mic_level = std.atomic.Value(f32).init(0);

pub const Error = error{
    DeviceInitFailed,
    DeviceStartFailed,
};

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

    // Exponential smoothing against the previous value so the level doesn't
    // strobe on every buffer.
    const prev = mic_level.load(.monotonic);
    const smoothed = prev * 0.6 + rms * 0.4;
    mic_level.store(smoothed, .monotonic);
}

/// Owns a miniaudio capture device. `init` configures + opens the device;
/// `start` begins capture; `deinit` stops + closes it.
///
/// `init` takes an out-pointer rather than returning by value: miniaudio
/// stores pointers back into the `ma_device` struct (including from its audio
/// thread), so the device must not move after `ma_device_init` succeeds.
/// Callers should declare a `Capture` at a stable address and pass `&it`.
pub const Capture = struct {
    device: ma.ma_device,

    pub fn init(self: *Capture) Error!void {
        var device_config = ma.ma_device_config_init(ma.ma_device_type_capture);
        device_config.capture.format = ma.ma_format_f32;
        device_config.capture.channels = 1;
        device_config.sampleRate = 44100;
        device_config.dataCallback = captureCallback;

        if (ma.ma_device_init(null, &device_config, &self.device) != ma.MA_SUCCESS) {
            return error.DeviceInitFailed;
        }
    }

    pub fn start(self: *Capture) Error!void {
        if (ma.ma_device_start(&self.device) != ma.MA_SUCCESS) {
            return error.DeviceStartFailed;
        }
    }

    pub fn deinit(self: *Capture) void {
        ma.ma_device_uninit(&self.device);
    }

    /// Latest smoothed RMS level (roughly 0..1). Cheap; safe from any thread.
    pub fn level(self: *const Capture) f32 {
        _ = self;
        return mic_level.load(.monotonic);
    }
};
