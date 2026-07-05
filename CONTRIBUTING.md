# Contributing / Developer guide

RoonVis is an **Objective-C++** tvOS app that embeds **libprojectM** (rendered via **ANGLE**,
GLES 3.0 → Metal) and a from-scratch **Snapcast** client. This guide covers building, the
project's conventions, and the gotchas that will bite you.

> Requires macOS with **Xcode** (tvOS SDK), **CMake**, and an Apple Developer account (a free
> Personal Team is fine — builds expire after 7 days).

## First checkout

```sh
git clone --recursive git@github.com:keeper-of-memes/RoonVis.git
cd RoonVis
# Apply the local tvOS/GLES patches to the vendored libraries (idempotent):
RoonVis/patches/apply.sh
```

`vendor/angle` and `vendor/projectm` are submodules pinned to specific upstream commits; our
modifications live as patches in `RoonVis/patches/` and are applied in-tree by `apply.sh`.

## Generate the Xcode project

CMake generates the Xcode project. **Re-run this after adding or removing any source file**, or
the app will fail to link the new symbols:

```sh
cmake -S RoonVis -B RoonVis -G Xcode -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT=appletvos \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DCMAKE_OBJC_COMPILER=/usr/bin/clang -DCMAKE_OBJCXX_COMPILER=/usr/bin/clang++ \
  -DROONVIS_DEVELOPMENT_TEAM=<your-team-id>
```

## Build

```sh
# Simulator (Debug). Always test Release too — see the NSAssert gotcha.
xcodebuild -project RoonVis/RoonVis.xcodeproj -scheme RoonVis -configuration Debug \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -derivedDataPath .derived-data build

# Release: add -configuration Release
# Device:  -destination 'id=<your-device-udid>' -allowProvisioningUpdates
```

## Host unit tests (pure C++, no device)

Testable logic lives in `SnapPCM.{h,cpp}` (endian, WAV parse, Snapcast framing, ring cap, backoff)
and is covered by 140+ host tests plus a golden shader-transpile determinism test:

```sh
cmake -S RoonVis -B RoonVis/build-host-tests -DROONVIS_BUILD_APP=OFF -DROONVIS_BUILD_TESTS=ON
cmake --build RoonVis/build-host-tests --target RoonVisTests && RoonVis/build-host-tests/RoonVisTests
```

See [Testing](../../wiki/Testing) for the full picture.

## Gotchas that will bite you

- **MRC, not ARC.** Manual `retain`/`release`/`autorelease`, `[super dealloc]`. The app target does
  not enable `CLANG_ENABLE_OBJC_ARC`.
- **Regenerate the xcodeproj after adding source files** (the CMake command above), or you'll get
  linker "undefined symbol" errors even though a partial build "succeeded."
- **`NSAssert` is stripped in Release** (`NS_BLOCK_ASSERTIONS`). Never put load-bearing calls inside
  `NSAssert`. **Always build Release** to catch this class of bug.
- **Threading invariant (do not violate):** the Snapcast `Network.framework` serial queue only ever
  appends PCM into the `_livePCMMutex`-guarded ring in `ProjectMBridge`. **All `projectm_*` and
  GL/EGL calls happen only on the main/GL thread.**
- **`vendor/projectm` always shows dirty** in `git status` — expected (patches are applied in-tree).
  **Never `git add vendor/projectm`**; never try to "clean" it. Stage files explicitly; never
  `git add -A`.
- **Editing the vendored libraries:** make your change in-tree, then regenerate the patch
  (`git -C vendor/projectm diff > RoonVis/patches/projectm.patch`) and verify it round-trips via
  `apply.sh`. The submodule SHAs should match the last intentional pin.

## Conventions

- Conventional commit messages.
- Land work in focused commits as each piece is verified; don't batch a large end-of-session diff.
- Put testable logic in the pure-C++ cores (`SnapPCM`) so it's covered by host tests.

## Where things are

- `RoonVis/Sources/RoonVis/` — the app: `ANGLEGLView` (composition root: CAMetalLayer + EGL/GLES +
  render loop), `ProjectMBridge` (libprojectM adapter), `SnapcastClient` (Snapcast TCP client),
  `SnapPCM` (pure C++ cores), `AppDelegate` (lifecycle).
- `RoonVis/CMakeLists.txt` — generates the Xcode project.
- `vendor/angle`, `vendor/projectm` — patched submodules; patches in `RoonVis/patches/`.
- `RoonVis/Resources/` — presets & textures.

See the [Architecture](../../wiki/Architecture) wiki page for the full map.
