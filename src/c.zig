//! Centralised C imports.
//!
//! `@cImport` produces a *distinct* type namespace per call site, so two
//! modules that each `@cImport(@cInclude("raylib.h"))` end up with mutually
//! incompatible `Texture2D` types. To avoid that footgun, every module that
//! needs raylib symbols imports them from here instead.

pub const rl = @cImport({
    @cInclude("raylib.h");
});
