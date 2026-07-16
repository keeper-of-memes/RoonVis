# RoonVis Host Tests

Build and run the pure C++ tests on macOS:

```sh
cmake -S RoonVis -B RoonVis/build-host-tests -DROONVIS_BUILD_APP=OFF -DROONVIS_BUILD_TESTS=ON
cmake --build RoonVis/build-host-tests --target RoonVisTests
RoonVis/build-host-tests/RoonVisTests
```

The harness is self-contained: `TestHarness.h` provides `CHECK` and `REQUIRE`
macros, counts pass/fail assertions, and the runner returns nonzero on any
failure. The suite is 770+ checks (see `scripts/build-health.sh`
`HOST_TEST_FLOOR` for the current pin) across the pure-C++ cores.

Suites linked into `RoonVisTests`:

- `SnapPCMTests.cpp` — little-endian reads, Snapcast base-header framing, WAV
  `fmt `/`data` parsing (first-chunk-wins duplicate policy), WireChunk PCM
  validation (whole stereo int16 frames), live-PCM ring cap, reconnect backoff.
- `LivePCMDelayBufferTests.cpp` — interleaved delay-line ring append/drain/rebase
  and the `LivePCMDelayFramesForMs` delay-to-frames math (full 700ms ceiling).
- `AudioOnsetDetectorTests.cpp` — audio onset detection for sync calibration.
- `SyncCalibrationMath` (via other suites) — sync-calibration math helpers.
- `DeviceTierTests.cpp` — A8/A10X/A15 device-tier classification.
- `PresetCompatTests.cpp` — static A15/A8 preset-compatibility heuristics.
- `PresetBlocklistTests.cpp` — static preset blocklist matching.
- `PresetShelfModelTests.cpp` — Browse shelf ordering/grouping model.
- `PresetRotationCursorTests.cpp` — rotation cursor front-reset / anchor logic.
- `PresetRotationSchedulerTests.cpp` — preset rotation/preload scheduling.
- `RotationEngineTests.cpp` — pure rotation-order engine (shuffle/loop/category).
- `PresetWarmCacheTests.cpp` — warm-preset candidate cache.
- `LearnedSlowPresetStoreTests.cpp` — persistent learned-slow-preset store.
- `LegacyNameMigrationTests.cpp` — legacy preset-name migration.
- `PreprocessCacheTests.cpp` — preprocessed-HLSL cache determinism/serialization.

Standalone host tools (built as separate executables, not part of the run above):
`PresetCompatScan` (compat verdicts — see below), `PreprocessCacheGen` (build-time
preprocess-cache `.bin` generator), `ShaderTranspileGolden` (HLSL→GLSL transpile
determinism golden), `SnapcastProjectMAudioProbe` (audio-path probe against
projectM's Audio core).

## Preset compatibility scanner (PresetCompatScan)

Static A15/A8 compatibility verdicts for any directory of `.milk` presets
(recursive). Rules + measured accuracy: `Sources/RoonVis/PresetCompat.cpp`;
design spec: `docs/preset-compat-scan-prompt.md`; CotC results:
`docs/cotc-compat-report.md`.

```sh
cmake -S RoonVis -B RoonVis/build-host-tests -DROONVIS_BUILD_APP=OFF -DROONVIS_BUILD_TESTS=ON
cmake --build RoonVis/build-host-tests --target PresetCompatScan
RoonVis/build-host-tests/PresetCompatScan <presets-dir>            # verdict TSV
RoonVis/build-host-tests/PresetCompatScan --features <presets-dir> # feature dump
RoonVis/build-host-tests/PresetCompatScan --explain <file.milk>    # one preset
```

Device validation: burn-in with `ROONVIS_COMPAT_BURNIN=1` (+ fixed rotation
list, 30 s dwell, `ROONVIS_DISABLE_SLOW_PRESET_SKIP=1`,
`ROONVIS_DISABLE_SNAPCAST=1` so slip.wav provides real audio), then join the
pulled perf-diagnostics.log against predictions with
`scripts/join_compat_burnin.py`. Predictions are never merged into
device-confirmed blocklist labels.
