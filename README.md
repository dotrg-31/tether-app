# Tether

Use your iPad as a wired second display for your Mac over the USB cable. No shared Apple ID required,
and touch input is supported.

Sidecar needs the Mac and iPad on the same Apple ID. Tether doesn't: it is a pair of small apps, one on
each device, that talk over the same USB channel Xcode and Finder use.

## How it works

- **Mac app** (menu bar): when the iPad connects, it creates a virtual display sized to that iPad's screen
  (Retina 2x, e.g. 1366×1024 points / 2732×2048 pixels on a 12.9" iPad Pro), captures it with
  ScreenCaptureKit, encodes low-latency H.264 on the hardware video encoder, and sends it through
  `usbmuxd`. Nothing goes over Wi-Fi.
- **iPad app**: decodes the stream with `AVSampleBufferDisplayLayer`, shows it full screen in landscape,
  and sends touches back as mouse input.

Touch on the iPad: tap = click, double tap = double click, one-finger drag = click-drag,
two-finger tap = right click, two-finger drag = scroll, trackpad or Pencil hover = move the pointer.

## Requirements

- A Mac with Apple silicon or a hardware H.264 encoder, macOS 14 or later, and Xcode (built with Xcode 27).
- An iPad on iPadOS 16 or later, connected with a cable.
- An Apple ID signed in to Xcode. A free Apple ID works, but iPadOS stops launching apps signed this way
  after 7 days; re-run the install script to renew. A paid Apple Developer account removes the limit.

## Build and install

1. Copy `signing.example` to `signing.local` and fill in your team ID and a bundle ID prefix of your own.
2. Mac: `scripts/install-mac.sh` builds and opens Tether (it lives in the menu bar). Allow
   **Screen Recording** and **Accessibility** for Tether in System Settings > Privacy & Security.
   Accessibility is only needed for touch control.
3. iPad: connect the cable, unlock the iPad and tap **Trust**. Turn on
   **Settings > Privacy & Security > Developer Mode** (the iPad restarts).
4. `scripts/install-ipad.sh` builds, installs and opens the iPad app. The first time, approve the developer
   under **Settings > General > VPN & Device Management** on the iPad.
5. Open Tether on both devices. The iPad appears as a display in System Settings > Displays, where you can
   arrange it.

The menu bar menu shows live frame rate, bandwidth and encoder type, and has a **Start at Login** option.

## Performance

Measured on an M4 Pro MacBook Pro, macOS 27:

| Situation | Frames sent | Bandwidth | Mac CPU (one core) |
|---|---|---|---|
| Static screen | 0 to 1 fps | ~0 Mbit/s | ~0.3% |
| Full-screen motion | 52 to 57 fps | 7 to 11 Mbit/s | 8 to 12% (includes the test animation) |

Encoding runs on the hardware media engine; Tether refuses to start rather than fall back to software
encoding. Quitting removes the virtual display.

## Testing

- `build/Build/Products/Release/Tether.app/Contents/MacOS/Tether --selftest out.png [WxH]` creates a
  virtual display (default 1366x1024 points), streams it through a local socket, decodes it, saves the
  picture and prints idle and full-motion frame rate, bitrate and CPU.
- `--direct` connects to 127.0.0.1:7878 instead of USB, for running the iPad app in the iOS Simulator.

## Status and limits

- Tested on one device: iPad Pro 12.9" (4th generation, USB-C). The Mac side was self-tested at the screen
  sizes of iPad mini, iPad Air, iPad (10th gen) and both iPad Pro sizes. Lightning iPads should work through
  the same USB channel but are untested.
- The virtual display uses `CGVirtualDisplay`, a private macOS API. That rules out the Mac App Store and
  could break with a future macOS update.
- No audio, no Apple Pencil pressure, no keyboard forwarding from the iPad.

## Project layout

- `Mac/`: menu bar app (virtual display, capture, encoder, usbmux client, input injection).
- `iPad/`: receiver app.
- `Shared/`: wire protocol and H.264 helpers used by both.
- `design/`: icon sources (SVG).
- `scripts/`: build and install scripts.
