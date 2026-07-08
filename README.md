# RoonVis

**A native tvOS (Apple TV) music visualizer.** RoonVis renders Milkdrop presets with
[libprojectM](https://github.com/projectM-visualizer/projectm) — via [ANGLE](https://github.com/google/angle)
(OpenGL ES 3.0 → Metal) — reacting in real time to audio streamed from **Roon** over **Snapcast**.
It works end-to-end on real hardware.

<!-- TODO: screenshot / gif here -->

> ✅ **Supported on all Apple TV models on tvOS 26** (v0.1.1). Reference device: Apple TV 4K
> 3rd gen (A15). The **Apple TV HD is validated** with reduced defaults (720p @ 30 fps) via a
> vendored ANGLE patch that unlocks ES 3.0 on its GPU; 4K 1st/2nd gen are expected to work but
> are untested on hardware. Older devices have real limitations — see
> [Apple TV device support](../../wiki/Apple-TV-Device-Support) in the wiki.

---

## What it does

Roon plays music → a Raspberry Pi captures it into a virtual audio cable and streams it with Snapcast
→ the Apple TV app receives the live audio and drives projectM, which renders reactive Milkdrop
visuals to your TV.

```
 Roon Core ──► Raspberry Pi ─────────────────────────►  Apple TV 4K
              (snd-aloop loopback              (Snapcast client → live PCM ring
               → snapserver, 44.1k/16/2)        → projectM → ANGLE GLES→Metal
                                                → CADisplayLink → your TV)
        └──► your speakers (grouped Roon zone, delayed to match)
```

**→ Full write-up in the wiki: [How It Works](../../wiki/How-It-Works) ·
[Apple TV Optimizations & Patch Catalog](../../wiki/Apple-TV-Optimizations-and-Patch-Catalog) ·
[Architecture](../../wiki/Architecture).**

---

## Getting started (quick)

Full guide: **[Getting Started](../../wiki/Getting-Started)**. The short version:

1. **Set up the Pi.** On a Raspberry Pi (64-bit Raspberry Pi OS), run:
   ```sh
   sudo bash scripts/pi-setup.sh
   ```
   It installs RoonBridge + Snapcast and configures the snd-aloop loopback automatically.
   → [Setup: Roon / Pi / Snapcast](../../wiki/Setup-Roon-Pi-Snapcast)
2. **Finish in Roon** (the script prints these): authorize RoonBridge; enable the loopback as an
   audio zone and **group it with your speakers**; set that zone's **sample-rate conversion to
   44.1 kHz in Roon's DSP engine (MUSE)**. → [Setup details](../../wiki/Setup-Roon-Pi-Snapcast)
3. **Install the app** — sideload the release `.ipa` with **AltStore** or **Sideloadly** (re-sign
   with *your* Apple ID), **or** build from source (see [Build & Run](../../wiki/Build-and-Run)).
4. **Point it at your Pi** — set `SnapcastServerHost` (the Pi's IP) in `Info.plist` / build config.

---

## Configuration & recommended settings

Before building, set these for your environment:

| What | Where | Set to |
|---|---|---|
| Apple Developer Team ID | CMake `-DROONVIS_DEVELOPMENT_TEAM=...` | your Team ID (free Personal Team is fine) |
| Snapcast server host | **In-app: Settings → Connection** (v0.1.2) | your Pi's IP or hostname |

**Recommended in-app settings**: run **Settings → Audio → Calibrate sync** for the A/V
delay (v0.1.2 — sets it by ear in twenty seconds, including your TV's panel lag; keep
**270 ms** on the Roon audio output as the anchor). Rendering defaults: **1080p @ 60**
(Apple TV HD: **720p @ 30**), warp **mesh 96×72** (HD: **64×48**) — adjustable live in
**Settings → Rendering**.
→ [Recommended Settings](../../wiki/Recommended-Settings) ·
[Delay Structure](../../wiki/Delay-Structure) · [Supported Resolutions](../../wiki/Supported-Resolutions)

---

## Documentation

The **[wiki](../../wiki)** is the full manual — setup, architecture, the engineering deep-dives,
troubleshooting, FAQ, and known issues. Start at the [Home](../../wiki) page.

## License

RoonVis's own source is **MIT** (see [`LICENSE`](LICENSE)). It builds on **libprojectM** (LGPL-2.1,
patched — sources shipped as submodule + `RoonVis/patches/`), **ANGLE** (BSD-3-Clause), and
public-domain Milkdrop presets/textures. Full inventory: [`THIRD_PARTY.md`](THIRD_PARTY.md).

> RoonVis is sideload-only today. Note that any binary distribution also carries **libprojectM's
> LGPL-2.1 terms** — see [`THIRD_PARTY.md`](THIRD_PARTY.md) for how we comply.
