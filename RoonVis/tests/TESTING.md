# RoonVis Host Tests

Build and run the pure C++ tests on macOS:

```sh
cmake -S RoonVis -B RoonVis/build-host-tests -DROONVIS_BUILD_APP=OFF -DROONVIS_BUILD_TESTS=ON
cmake --build RoonVis/build-host-tests --target RoonVisTests
RoonVis/build-host-tests/RoonVisTests
```

The harness is self-contained: `TestHarness.h` provides `CHECK` and `REQUIRE`
macros, counts pass/fail assertions, and `SnapPCMTests.cpp` returns nonzero on
any failure.

Coverage includes little-endian reads, Snapcast base-header framing decisions,
WAV `fmt `/`data` parsing, WireChunk PCM payload validation, live PCM ring
append/cap behavior, and the reconnect backoff ladder.

The tests cover two review defects fixed by the shared core:

- Duplicate RIFF chunks now use one documented policy: first `fmt ` and first
  `data` win, later duplicates are ignored.
- WireChunk payloads must be whole stereo int16 frames before the app computes
  frame count or copies PCM.
