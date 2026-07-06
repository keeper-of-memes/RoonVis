# Third-party licenses

RoonVis's own source is licensed under **MIT** (see [`LICENSE`](LICENSE)). It bundles and
builds on the following third-party components, each under its own license:

| Component | Where | License | Notes |
|---|---|---|---|
| **projectM** (libprojectM) | `vendor/projectm` (git submodule, patched) | **LGPL-2.1** | Modified. See below. |
| **ANGLE** | `vendor/angle` (git submodule) | **BSD-3-Clause** | Google's OpenGL-ES-over-Metal implementation. |
| **Milkdrop presets** | `RoonVis/Resources/presets/` | **Public domain** | Curated subset of the projectM *Cream of the Crop* pack. |
| **Textures** | `RoonVis/Resources/textures/` | **Public domain** | projectM *Milkdrop texture pack*. |

## projectM (LGPL-2.1) — how we comply

RoonVis links **libprojectM**, which is LGPL-2.1. We apply local patches to it (tvOS/ANGLE
porting shims + performance work). To satisfy the LGPL's requirement that the modified library's
source be available:

- `vendor/projectm` is a **git submodule** pinned to a specific upstream commit, and
- **all our modifications are shipped as patches** in `RoonVis/patches/` (`projectm.patch`,
  applied idempotently by `RoonVis/patches/apply.sh`).

Anyone can obtain the exact modified library source: check out the pinned submodule commit and
apply the patches. Upstream: https://github.com/projectM-visualizer/projectm

## ANGLE (BSD-3-Clause)

`vendor/angle`, pinned as a submodule. Upstream: https://chromium.googlesource.com/angle/angle
(License: `vendor/angle/LICENSE`.)

## Presets & textures (public domain)

Per the upstream `LICENSE.md` of the projectM preset/texture packs, Milkdrop presets and textures
were, in almost all cases, released without a specific license and are treated as **public domain**.
Provenance and links are in [`RoonVis/Resources/presets/SOURCE.md`](RoonVis/Resources/presets/SOURCE.md).

- Presets: https://github.com/projectM-visualizer/presets-cream-of-the-crop
- Textures: https://github.com/projectM-visualizer/presets-milkdrop-texture-pack

We wrote no presets — they are borrowed and redistributed under their public-domain status.

## A note on licensing + the App Store

RoonVis's own MIT license is compatible with source distribution, sideloading, and App Store
distribution alike. The remaining consideration for any binary distribution (including a future
App Store build) is **libprojectM's LGPL-2.1**: the compliance measures above (public sources,
patches, and a relinkable dynamic framework) apply to those builds too. RoonVis is sideload-only
today.
