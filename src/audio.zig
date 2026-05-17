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

/// Smoothed RMS microphone level, raw (pre-normalization). Written from the
/// audio thread, read from the main thread. Magnitude depends entirely on
/// the input device; see `Capture.level()` for the normalized version.
var mic_level_raw = std.atomic.Value(f32).init(0);

var calibration_active = std.atomic.Value(bool).init(false);
var calibration_peak = std.atomic.Value(f32).init(0);

/// Lower bound on the calibration reference. If a user calibrates against
/// silence (e.g. didn't actually speak), we don't want to divide by ~0 and
/// turn room tone into a fully-open mouth.
const min_calibration_ref: f32 = 0.01;

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

    // Asymmetric exponential smoothing: fast attack so the mouth opens
    // responsively on speech onsets, slow release so brief gaps between
    // syllables don't slam it shut. Coefficients are the weight kept from
    // the previous value per callback (~10ms at 44.1kHz / 441 frames).
    const prev = mic_level_raw.load(.monotonic);
    const k: f32 = 0.9;
    const smoothed = prev * k + rms * (1.0 - k);
    mic_level_raw.store(smoothed, .monotonic);

    if (calibration_active.load(.monotonic)) {
        const peak = calibration_peak.load(.monotonic);
        if (smoothed > peak) calibration_peak.store(smoothed, .monotonic);
    }
}

pub const Capture = struct {
    device: ma.ma_device,
    /// Divisor applied to the raw smoothed RMS in `level()`. Set by
    /// calibration so a user's normal speaking volume maps to ~1.0
    /// regardless of mic sensitivity. Defaults to 1.0 (no normalization).
    calibration_ref: f32 = 1.0,

    pub fn init(self: *Capture) Error!void {
        self.* = .{ .device = undefined };
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

    pub fn level(self: *const Capture) f32 {
        const raw = mic_level_raw.load(.monotonic);
        const ref = @max(self.calibration_ref, min_calibration_ref);
        const n = raw / ref;
        return if (n > 1.0) 1.0 else if (n < 0) 0 else n;
    }

    pub fn beginCalibration(self: *Capture) void {
        _ = self;
        calibration_peak.store(0, .monotonic);
        calibration_active.store(true, .monotonic);
    }

    pub fn calibrationPeak(self: *const Capture) f32 {
        _ = self;
        return calibration_peak.load(.monotonic);
    }

    pub fn endCalibration(self: *Capture) f32 {
        calibration_active.store(false, .monotonic);
        const peak = calibration_peak.load(.monotonic);
        if (peak >= min_calibration_ref) self.calibration_ref = peak;
        return peak;
    }

    pub fn isCalibrating(self: *const Capture) bool {
        _ = self;
        return calibration_active.load(.monotonic);
    }
};
