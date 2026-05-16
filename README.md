# btuber

A tiny PNGtuber-style avatar. Point it at two images — one with your mouth
closed, one with it open — and it swaps between them whenever your mic picks
up your voice.

## Install

Grab a prebuilt binary for your OS from the
[Releases](../../releases) page and run it.

## Usage

Launch `btuber`. On first run the settings menu opens automatically because
no images are set yet.

- **Drag and drop** a PNG/JPG onto either slot ("Closed image" / "Open image").
- Adjust the **microphone sensitivity** slider until the green meter crosses
  the slider handle when you talk and stays below it when you're quiet.
  (You can also click the number to type a value directly.)
- Press **Esc** to close the menu. Press Esc again any time to reopen it.

Your images, threshold, and debug setting are saved to `btuber.ini` next to
wherever you launched btuber from, so they'll be there next time.

### Tips

- Resize the window to whatever shape you want — the avatar scales to fit.
- Toggle **Show debug voice meter** to get a thin bar at the top of the
  window showing your live mic level (green) vs. the threshold (red tick).
  Handy while tuning sensitivity.
- For use in OBS / Discord / etc., capture the btuber window and chroma-key
  out the white background, or use a window-capture with transparency.

## Command line (optional)

```
btuber [--debug] [closed-image] [open-image] [threshold]
```

All arguments are optional and override the saved settings for that run.

## Building from source

Requires Zig 0.16. On Linux you'll also need the usual X11/Wayland and ALSA
dev packages (see `.github/workflows/ci.yml`).

```
zig build -Doptimize=ReleaseFast
./zig-out/bin/btuber
```
