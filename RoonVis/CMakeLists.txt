cmake_minimum_required(VERSION 4.0)

project(RoonVis LANGUAGES C CXX OBJC OBJCXX)

option(ROONVIS_BUILD_APP "Build the tvOS RoonVis app" ON)
option(ROONVIS_BUILD_TESTS "Build host-side pure C++ tests" OFF)

if(ROONVIS_BUILD_TESTS)
  add_executable(RoonVisTests
    Sources/RoonVis/PresetShelfModel.h
    Sources/RoonVis/PresetBlocklist.h
    Sources/RoonVis/PresetBlocklist.cpp
    Sources/RoonVis/SnapPCM.h
    Sources/RoonVis/SnapPCM.cpp
    tests/TestHarness.h
    tests/PresetBlocklistTests.cpp
    Sources/RoonVis/PresetRotationScheduler.h
    Sources/RoonVis/PresetRotationScheduler.cpp
    Sources/RoonVis/PresetWarmCache.h
    Sources/RoonVis/PresetWarmCache.cpp
    Sources/RoonVis/PresetDwellPlan.h
    Sources/RoonVis/PresetDwellPlan.cpp
    tests/PresetDwellPlanTests.cpp
    Sources/RoonVis/LearnedSlowPresetStore.h
    Sources/RoonVis/LearnedSlowPresetStore.cpp
    Sources/RoonVis/PreprocessCache.h
    Sources/RoonVis/PreprocessCache.cpp
    Sources/RoonVis/PreprocessCacheResource.h
    Sources/RoonVis/PreprocessCacheResource.cpp
    tests/PreprocessCacheResourceTests.cpp
    Sources/RoonVis/DeviceTier.h
    Sources/RoonVis/DeviceTier.cpp
    Sources/RoonVis/PresetRotationCursor.h
    Sources/RoonVis/PresetRotationCursor.cpp
    Sources/RoonVis/RotationEngine.h
    Sources/RoonVis/RotationEngine.cpp
    Sources/RoonVis/AudioOnsetDetector.h
    Sources/RoonVis/AudioOnsetDetector.cpp
    Sources/RoonVis/SyncCalibrationMath.h
    Sources/RoonVis/SyncCalibrationMath.cpp
    tests/DeviceTierTests.cpp
    tests/PresetRotationCursorTests.cpp
    tests/RotationEngineTests.cpp
    tests/AudioOnsetDetectorTests.cpp
    Sources/RoonVis/PresetCompat.h
    Sources/RoonVis/PresetCompat.cpp
    tests/PresetCompatTests.cpp
    Sources/RoonVis/LegacyNameMigration.h
    Sources/RoonVis/LegacyNameMigration.cpp
    tests/LegacyNameMigrationTests.cpp
    Sources/RoonVis/PresetCapabilityManifest.h
    Sources/RoonVis/PresetCapabilityManifest.cpp
    Sources/RoonVis/PresetEligibilityPolicy.h
    Sources/RoonVis/PresetEligibilityPolicy.cpp
    tests/PresetCapabilityManifestTests.cpp
    tests/PresetEligibilityPolicyTests.cpp
    Sources/RoonVis/ShaderBlobStore.h
    Sources/RoonVis/ShaderBlobStore.cpp
    tests/ShaderBlobStoreTests.cpp
    tests/PresetShelfModelTests.cpp
    tests/SnapPCMTests.cpp
    tests/LivePCMDelayBufferTests.cpp
    tests/PresetRotationSchedulerTests.cpp
    tests/PresetWarmCacheTests.cpp
    tests/LearnedSlowPresetStoreTests.cpp
    tests/PreprocessCacheTests.cpp
    "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/src/libprojectM/MilkdropPreset/PresetFileParser.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/src/libprojectM/Utils.cpp"
  )
  target_include_directories(RoonVisTests PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/Sources/RoonVis"
    "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/src/libprojectM"
    "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/src/libprojectM/MilkdropPreset"
  )
  target_compile_features(RoonVisTests PRIVATE cxx_std_17)
  # ShaderBlobStore uses the system SQLite (libsqlite3.tbd on both macOS and tvOS).
  target_link_libraries(RoonVisTests PRIVATE sqlite3)
  # Quality gate: warning-clean on host targets in this branch. The app target gets
  # -Wall -Wextra separately (its own triage; the app can't build in this worktree).
  target_compile_options(RoonVisTests PRIVATE -Wall -Wextra)

  if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/src/libprojectM/Audio/Loudness.cpp")
    add_executable(SnapcastProjectMAudioProbe
      Sources/RoonVis/SnapPCM.h
      Sources/RoonVis/SnapPCM.cpp
      "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/src/libprojectM/Audio/Loudness.cpp"
      "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/src/libprojectM/Audio/MilkdropFFT.cpp"
      "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/src/libprojectM/Audio/PCM.cpp"
      "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/src/libprojectM/Audio/WaveformAligner.cpp"
      tests/SnapcastProjectMAudioProbe.cpp
    )
    target_include_directories(SnapcastProjectMAudioProbe PRIVATE
      "${CMAKE_CURRENT_LIST_DIR}/Sources/RoonVis"
      "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/src/libprojectM"
      "${CMAKE_CURRENT_LIST_DIR}/projectm-build/src/api/include"
    )
    target_compile_features(SnapcastProjectMAudioProbe PRIVATE cxx_std_17)
    target_compile_options(SnapcastProjectMAudioProbe PRIVATE -Wall -Wextra)
  endif()

  # Host-side golden determinism test for the GL-free HLSL preprocess pipeline.
  # Compiles the minimal GL-free projectM + hlslparser source set directly (mirrors the
  # audio-probe pattern) to run PresetFileParser -> AssembleApplyPreprocessorInput ->
  # M4::HLSLParser::ApplyPreprocessor over the real preset pack and assert byte-identical
  # (deterministic) preprocessor output. Requires the app build's generated headers
  # (projectm-build) for the configured MilkdropStaticShaders + projectM export headers.
  set(PROJECTM_SRC "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/src/libprojectM")
  set(HLSLPARSER_SRC "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/vendor/hlslparser/src")
  set(PROJECTM_BUILD "${CMAKE_CURRENT_LIST_DIR}/projectm-build")
  if(EXISTS "${PROJECTM_SRC}/MilkdropPreset/MilkdropShaderPreprocess.cpp"
     AND EXISTS "${PROJECTM_BUILD}/src/libprojectM/MilkdropPreset/MilkdropStaticShaders.cpp")
    add_executable(ShaderTranspileGolden
      tests/ShaderTranspileGolden.cpp
      Sources/RoonVis/MilkdropTranspilePrep.h
      Sources/RoonVis/MilkdropTranspilePrep.cpp
      "${PROJECTM_SRC}/MilkdropPreset/MilkdropShaderPreprocess.cpp"
      "${PROJECTM_SRC}/MilkdropPreset/PresetFileParser.cpp"
      "${PROJECTM_SRC}/Utils.cpp"
      "${PROJECTM_BUILD}/src/libprojectM/MilkdropPreset/MilkdropStaticShaders.cpp"
      "${HLSLPARSER_SRC}/CodeWriter.cpp"
      "${HLSLPARSER_SRC}/Engine.cpp"
      "${HLSLPARSER_SRC}/GLSLGenerator.cpp"
      "${HLSLPARSER_SRC}/HLSLParser.cpp"
      "${HLSLPARSER_SRC}/HLSLTokenizer.cpp"
      "${HLSLPARSER_SRC}/HLSLTree.cpp"
    )
    target_include_directories(ShaderTranspileGolden PRIVATE
      "${CMAKE_CURRENT_LIST_DIR}/Sources/RoonVis"
      "${PROJECTM_SRC}"
      "${PROJECTM_SRC}/MilkdropPreset"
      "${HLSLPARSER_SRC}"
      "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/vendor"
      "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/vendor/glad/include"
      "${PROJECTM_BUILD}/src/libprojectM/MilkdropPreset"
      "${PROJECTM_SRC}/../api/include"
      "${PROJECTM_BUILD}/src/api/include"
      "${PROJECTM_BUILD}/include"
    )
    target_compile_features(ShaderTranspileGolden PRIVATE cxx_std_17)
    target_compile_options(ShaderTranspileGolden PRIVATE -Wall -Wextra)

    # Build-time generator for the prepopulated preprocessed-HLSL cache resource.
    # Same GL-free source set + include dirs as ShaderTranspileGolden (it additionally
    # calls ComputePreprocessCacheKey / PreprocessCacheSalt, already in
    # MilkdropShaderPreprocess.cpp). See "Regenerating the prepopulated cache" in
    # docs/preprocessor-transpile-stutter.md for the regen commands.
    add_executable(PreprocessCacheGen
      tests/PreprocessCacheGen.cpp
      Sources/RoonVis/MilkdropTranspilePrep.h
      Sources/RoonVis/MilkdropTranspilePrep.cpp
      Sources/RoonVis/PreprocessCache.h
      Sources/RoonVis/PreprocessCache.cpp
      Sources/RoonVis/PreprocessCacheResource.h
      Sources/RoonVis/PreprocessCacheResource.cpp
      "${PROJECTM_SRC}/MilkdropPreset/MilkdropShaderPreprocess.cpp"
      "${PROJECTM_SRC}/MilkdropPreset/PresetFileParser.cpp"
      "${PROJECTM_SRC}/Utils.cpp"
      "${PROJECTM_BUILD}/src/libprojectM/MilkdropPreset/MilkdropStaticShaders.cpp"
      "${HLSLPARSER_SRC}/CodeWriter.cpp"
      "${HLSLPARSER_SRC}/Engine.cpp"
      "${HLSLPARSER_SRC}/GLSLGenerator.cpp"
      "${HLSLPARSER_SRC}/HLSLParser.cpp"
      "${HLSLPARSER_SRC}/HLSLTokenizer.cpp"
      "${HLSLPARSER_SRC}/HLSLTree.cpp"
    )
    target_include_directories(PreprocessCacheGen PRIVATE
      "${CMAKE_CURRENT_LIST_DIR}/Sources/RoonVis"
      "${PROJECTM_SRC}"
      "${PROJECTM_SRC}/MilkdropPreset"
      "${HLSLPARSER_SRC}"
      "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/vendor"
      "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/vendor/glad/include"
      "${PROJECTM_BUILD}/src/libprojectM/MilkdropPreset"
      "${PROJECTM_SRC}/../api/include"
      "${PROJECTM_BUILD}/src/api/include"
      "${PROJECTM_BUILD}/include"
    )
    target_compile_features(PreprocessCacheGen PRIVATE cxx_std_17)
    target_compile_options(PreprocessCacheGen PRIVATE -Wall -Wextra)

    # Tier-1 fidelity spike: GL-free reproduction of the exact parse-stage input text
    # (MilkdropShader.cpp:545) per bundled preset shader, emitted as key TSV. Same GL-free
    # source set + include dirs as PreprocessCacheGen; throwaway validation tooling.
    add_executable(ParseInputHashGen
      tests/ParseInputHashGen.cpp
      Sources/RoonVis/MilkdropTranspilePrep.h
      Sources/RoonVis/MilkdropTranspilePrep.cpp
      "${PROJECTM_SRC}/MilkdropPreset/MilkdropShaderPreprocess.cpp"
      "${PROJECTM_SRC}/MilkdropPreset/PresetFileParser.cpp"
      "${PROJECTM_SRC}/Utils.cpp"
      "${PROJECTM_BUILD}/src/libprojectM/MilkdropPreset/MilkdropStaticShaders.cpp"
      "${HLSLPARSER_SRC}/CodeWriter.cpp"
      "${HLSLPARSER_SRC}/Engine.cpp"
      "${HLSLPARSER_SRC}/GLSLGenerator.cpp"
      "${HLSLPARSER_SRC}/HLSLParser.cpp"
      "${HLSLPARSER_SRC}/HLSLTokenizer.cpp"
      "${HLSLPARSER_SRC}/HLSLTree.cpp"
    )
    target_include_directories(ParseInputHashGen PRIVATE
      "${CMAKE_CURRENT_LIST_DIR}/Sources/RoonVis"
      "${PROJECTM_SRC}"
      "${PROJECTM_SRC}/MilkdropPreset"
      "${HLSLPARSER_SRC}"
      "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/vendor"
      "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm/vendor/glad/include"
      "${PROJECTM_BUILD}/src/libprojectM/MilkdropPreset"
      "${PROJECTM_SRC}/../api/include"
      "${PROJECTM_BUILD}/src/api/include"
      "${PROJECTM_BUILD}/include"
    )
    target_compile_features(ParseInputHashGen PRIVATE cxx_std_17)
    target_compile_options(ParseInputHashGen PRIVATE -Wall -Wextra)
  endif()

  # Host-side static preset-compatibility scanner (A15/A8 tier verdicts).
  # Pure feature extraction + derived rules; NOT linked into the tvOS app.
  add_executable(PresetCompatScan
    tests/PresetCompatScan.cpp
    Sources/RoonVis/PresetCompat.cpp
    "${PROJECTM_SRC}/MilkdropPreset/PresetFileParser.cpp"
    "${PROJECTM_SRC}/Utils.cpp"
  )
  target_include_directories(PresetCompatScan PRIVATE
    Sources/RoonVis
    "${PROJECTM_SRC}"
    "${PROJECTM_SRC}/MilkdropPreset"
  )
  target_compile_features(PresetCompatScan PRIVATE cxx_std_17)
  target_compile_options(PresetCompatScan PRIVATE -Wall -Wextra)
endif()

if(NOT ROONVIS_BUILD_APP)
  return()
endif()

enable_language(Swift)

find_package(Python3 REQUIRED COMPONENTS Interpreter)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED YES)
set(CMAKE_OSX_DEPLOYMENT_TARGET "26.0" CACHE STRING "" FORCE)
set(CMAKE_SUPPRESS_REGENERATION ON)
set(CMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "appletvos appletvsimulator")
set(CMAKE_XCODE_ATTRIBUTE_SDKROOT "appletvos")
set(CMAKE_XCODE_ATTRIBUTE_TVOS_DEPLOYMENT_TARGET "26.0")

set(ANGLE_ROOT "${CMAKE_CURRENT_LIST_DIR}/../vendor/angle")
set(PROJECTM_ROOT "${CMAKE_CURRENT_LIST_DIR}/../vendor/projectm")
set(ANGLE_GENERATED_DIR "${CMAKE_CURRENT_LIST_DIR}/ANGLEGenerated")
set(ANGLE_SOURCES_FILE "${CMAKE_CURRENT_BINARY_DIR}/angle_sources.cmake")

execute_process(
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/cmake/generate_angle_sources.py" "${ANGLE_SOURCES_FILE}"
  RESULT_VARIABLE ANGLE_SOURCE_GEN_RESULT
)
if(NOT ANGLE_SOURCE_GEN_RESULT EQUAL 0)
  message(FATAL_ERROR "Failed to generate ANGLE source list")
endif()
include("${ANGLE_SOURCES_FILE}")

add_library(ANGLE STATIC ${ANGLE_SOURCES})
target_include_directories(ANGLE PUBLIC
  "${ANGLE_ROOT}/include"
  "${ANGLE_ROOT}/src"
  "${ANGLE_ROOT}/src/common/base"
  "${ANGLE_ROOT}/src/common/third_party/xxhash"
  "${ANGLE_GENERATED_DIR}/angle"
  "${ANGLE_GENERATED_DIR}"
)
target_compile_definitions(ANGLE PRIVATE
  ANGLE_ENABLE_METAL
  ANGLE_CAPTURE_ENABLED=0
  ANGLE_ENABLE_SHARE_CONTEXT_LOCK=1
  ANGLE_ENABLE_CONTEXT_MUTEX=1
  ANGLE_OUTSIDE_WEBKIT
  ANGLE_PLATFORM_EXPORT=
  EGL_NO_X11
  LIBANGLE_IMPLEMENTATION
  GL_GLES_PROTOTYPES=1
  EGL_EGL_PROTOTYPES=1
  GL_GLEXT_PROTOTYPES
  EGL_EGLEXT_PROTOTYPES
)
target_compile_options(ANGLE PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wno-deprecated-declarations>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wno-nullability-completeness>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wno-unguarded-availability>"
)
set_target_properties(ANGLE PROPERTIES
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC NO
  XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"
  XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY "libc++"
  XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "appletvos appletvsimulator"
  XCODE_ATTRIBUTE_SDKROOT "appletvos"
)

set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(ENABLE_DEBUG_POSTFIX OFF CACHE BOOL "" FORCE)
set(ENABLE_GLES ON CACHE BOOL "" FORCE)
set(ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(ENABLE_PLAYLIST OFF CACHE BOOL "" FORCE)
set(ENABLE_SDL_UI OFF CACHE BOOL "" FORCE)
set(STD_FILESYSTEM_EXISTS TRUE CACHE BOOL "" FORCE)
include_directories("${ANGLE_ROOT}/include")
add_subdirectory("${PROJECTM_ROOT}" "${CMAKE_CURRENT_BINARY_DIR}/projectm-build")
target_link_libraries(projectM PRIVATE
  ANGLE
  z
  objc
  "-framework Foundation"
  "-framework QuartzCore"
  "-framework Metal"
  "-framework CoreFoundation"
  "-framework CoreGraphics"
  "-framework IOSurface"
)
target_link_options(projectM PRIVATE
  "LINKER:-u,_eglChooseConfig"
  "LINKER:-u,_eglCreateContext"
  "LINKER:-u,_eglCreateWindowSurface"
  "LINKER:-u,_eglDestroyContext"
  "LINKER:-u,_eglDestroySurface"
  "LINKER:-u,_eglGetDisplay"
  "LINKER:-u,_eglGetError"
  "LINKER:-u,_eglInitialize"
  "LINKER:-u,_eglMakeCurrent"
  "LINKER:-u,_eglSwapBuffers"
  "LINKER:-u,_eglTerminate"
)
foreach(PROJECTM_TARGET
    Audio
    MilkdropPreset
    Renderer
    SOIL2
    hlslparser
    projectM
    projectM_api
    projectM_eval
    projectM_main
)
  if(TARGET ${PROJECTM_TARGET})
    set_target_properties(${PROJECTM_TARGET} PROPERTIES
      CXX_STANDARD 20
      CXX_STANDARD_REQUIRED YES
      XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"
      XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY "libc++"
    )
  endif()
endforeach()
set_target_properties(projectM PROPERTIES
  FRAMEWORK TRUE
  MACOSX_FRAMEWORK_IDENTIFIER "org.projectm.projectM-4"
  XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"
  XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY "libc++"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "org.projectm.projectM-4"
  XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "appletvos appletvsimulator"
  XCODE_ATTRIBUTE_SDKROOT "appletvos"
)

set(TEST_AUDIO_RESOURCE "${CMAKE_CURRENT_LIST_DIR}/Resources/TestAudio.wav")
set(TEST_PRESET_RESOURCE "${PROJECTM_ROOT}/presets/tests/300-beatdetect-bassmidtreb.milk")
set(PRESET_BLOCKLIST_RESOURCE "${CMAKE_CURRENT_LIST_DIR}/Resources/PresetBlocklist.json")
set(HD_VERIFIED_RESOURCE "${CMAKE_CURRENT_LIST_DIR}/Resources/HDVerifiedPresets.json")
set(HD_CAPABILITY_MANIFEST_RESOURCE "${CMAKE_CURRENT_LIST_DIR}/Resources/HDCapabilityManifest.json")
set(LEGACY_MAP_RESOURCE "${CMAKE_CURRENT_LIST_DIR}/Resources/LegacyNameMap.json")
# Prepopulated preprocessed-HLSL cache: a build-time-generated binary the app seeds into
# its runtime PreprocessCache at startup so the first load of any bundled preset is a cache
# hit. Referenced explicitly (never globbed) so no stray file can slip into the bundle.
# Regenerate via the PreprocessCacheGen host tool -- see the note in
# docs/preprocessor-transpile-stutter.md.
set(PREPROCESS_CACHE_RESOURCE "${CMAKE_CURRENT_LIST_DIR}/Resources/preprocess-cache/preprocess-cache.bin")
# Preset + preview + texture TREES ship via the post-build rsync phase below:
# per-file pbxproj entries would explode configure/build times, and the GLOB path
# had no delete semantics (a removed texture persisted in stale incremental bundles).
set_source_files_properties(
  "${TEST_AUDIO_RESOURCE}"
  "${TEST_PRESET_RESOURCE}"
  "${PRESET_BLOCKLIST_RESOURCE}"
  "${HD_VERIFIED_RESOURCE}"
  "${HD_CAPABILITY_MANIFEST_RESOURCE}"
  "${LEGACY_MAP_RESOURCE}"
  PROPERTIES MACOSX_PACKAGE_LOCATION Resources
)
set_source_files_properties(
  "${PREPROCESS_CACHE_RESOURCE}"
  PROPERTIES MACOSX_PACKAGE_LOCATION preprocess-cache
)

add_executable(RoonVis MACOSX_BUNDLE
  Sources/RoonVis/main.mm
  Sources/RoonVis/AppDelegate.h
  Sources/RoonVis/AppDelegate.mm
  Sources/RoonVis/ANGLEGLView.h
  Sources/RoonVis/ANGLEGLViewInternal.h
  Sources/RoonVis/ANGLEGLView.mm
  Sources/RoonVis/ANGLEGLView+Diagnostics.mm
  Sources/RoonVis/ANGLEGLView+Controls.mm
  Sources/RoonVis/RoonVisEGLContext.h
  Sources/RoonVis/RoonVisEGLContext.mm
  Sources/RoonVis/BrowseModal.swift
  Sources/RoonVis/PresetValidator.h
  Sources/RoonVis/PresetValidator.mm
  Sources/RoonVis/PresetBrowser.swift
  Sources/RoonVis/ThumbnailCache.swift
  Sources/RoonVis/ComponentGallery.swift
  Sources/RoonVis/Components.swift
  Sources/RoonVis/EngineState.swift
  Sources/RoonVis/Overlays.swift
  Sources/RoonVis/PresetOptionsOverlay.swift
  Sources/RoonVis/QuickSettingsPanel.swift
  Sources/RoonVis/RootChrome.swift
  Sources/RoonVis/SettingsScreen.swift
  Sources/RoonVis/SyncCalibration.swift
  Sources/RoonVis/SettingsStore.swift
  Sources/RoonVis/Theme.swift
  Sources/RoonVis/RoonVis-Bridging-Header.h
  Sources/RoonVis/PresetThumbnailRenderer.h
  Sources/RoonVis/PresetThumbnailRenderer.mm
  Sources/RoonVis/PresetShelfModel.h
  Sources/RoonVis/PresetBlocklist.h
  Sources/RoonVis/PresetBlocklist.cpp
  Sources/RoonVis/ProjectMBridge.h
  Sources/RoonVis/ProjectMBridge.mm
  Sources/RoonVis/ProjectMBridgeInternal.h
  Sources/RoonVis/ProjectMBridge+Audio.mm
  Sources/RoonVis/ProjectMBridge+Presets.mm
  Sources/RoonVis/ProjectMBridge+Warm.mm
  Sources/RoonVis/ProjectMPresetSupport.h
  Sources/RoonVis/ProjectMPresetSupport.mm
  Sources/RoonVis/PresetRotationScheduler.h
  Sources/RoonVis/PresetRotationScheduler.cpp
  Sources/RoonVis/PresetWarmCache.h
  Sources/RoonVis/PresetWarmCache.cpp
  Sources/RoonVis/PresetDwellPlan.h
  Sources/RoonVis/PresetDwellPlan.cpp
  Sources/RoonVis/LearnedSlowPresetStore.h
  Sources/RoonVis/LearnedSlowPresetStore.cpp
  Sources/RoonVis/LegacyNameMigration.h
  Sources/RoonVis/LegacyNameMigration.cpp
  Sources/RoonVis/LegacyNameMigrationSupport.h
  Sources/RoonVis/LegacyNameMigrationSupport.mm
  Sources/RoonVis/PreprocessCache.h
  Sources/RoonVis/PreprocessCache.cpp
  Sources/RoonVis/PreprocessCacheResource.h
  Sources/RoonVis/PreprocessCacheResource.cpp
  Sources/RoonVis/PresetWarmSettings.h
  Sources/RoonVis/PresetWarmSettings.mm
  Sources/RoonVis/DeviceTier.h
  Sources/RoonVis/DeviceTier.cpp
  Sources/RoonVis/PresetRotationCursor.h
  Sources/RoonVis/PresetRotationCursor.cpp
  Sources/RoonVis/RotationEngine.h
  Sources/RoonVis/RotationEngine.cpp
  Sources/RoonVis/PresetCapabilityManifest.h
  Sources/RoonVis/PresetCapabilityManifest.cpp
  Sources/RoonVis/PresetEligibilityPolicy.h
  Sources/RoonVis/PresetEligibilityPolicy.cpp
  Sources/RoonVis/ShaderBlobStore.h
  Sources/RoonVis/ShaderBlobStore.cpp
  Sources/RoonVis/ShaderBlobCacheAdapter.h
  Sources/RoonVis/ShaderBlobCacheAdapter.mm
  Sources/RoonVis/AudioOnsetDetector.h
  Sources/RoonVis/AudioOnsetDetector.cpp
  Sources/RoonVis/SyncCalibrationMath.h
  Sources/RoonVis/SyncCalibrationMath.cpp
  Sources/RoonVis/RoonVisCapabilityCatalog.h
  Sources/RoonVis/RoonVisCapabilityCatalog.mm
  Sources/RoonVis/RoonVisDeviceTier.h
  Sources/RoonVis/RoonVisDeviceTier.mm
  Sources/RoonVis/RoonVisCrashReporter.h
  Sources/RoonVis/RoonVisCrashReporter.mm
  Sources/RoonVis/RoonVisPerfCounters.h
  Sources/RoonVis/RoonVisPerfCounters.mm
  Sources/RoonVis/RoonVisPerfDiagnosticsSink.h
  Sources/RoonVis/RoonVisSettings.h
  Sources/RoonVis/RoonVisSettings.mm
  Sources/RoonVis/RoonVisTheme.h
  Sources/RoonVis/RoonVisTheme.mm
  Sources/RoonVis/SnapPCM.h
  Sources/RoonVis/SnapPCM.cpp
  Sources/RoonVis/SnapcastClient.h
  Sources/RoonVis/SnapcastClient.mm
  Sources/RoonVis/Info.plist
  "${TEST_AUDIO_RESOURCE}"
  "${TEST_PRESET_RESOURCE}"
  "${PRESET_BLOCKLIST_RESOURCE}"
  "${HD_VERIFIED_RESOURCE}"
  "${HD_CAPABILITY_MANIFEST_RESOURCE}"
  "${LEGACY_MAP_RESOURCE}"
  "${PREPROCESS_CACHE_RESOURCE}"
)

# Tree-copy phase: rsync the preset + preview + texture trees into the bundle. Runs as
# a post-build script phase, which Xcode executes BEFORE code signing (signing
# seals the copied files). --delete keeps stale files out of incremental
# builds (the historical stale-resource gotcha). The textures/ destination is
# load-bearing: ProjectMBridge registers resourcePath/textures as a texture search path.
add_custom_command(TARGET RoonVis POST_BUILD
  COMMAND rsync -a --delete "${CMAKE_CURRENT_LIST_DIR}/Resources/presets/" "$<TARGET_BUNDLE_CONTENT_DIR:RoonVis>/presets/"
  COMMAND rsync -a --delete "${CMAKE_CURRENT_LIST_DIR}/Resources/PresetPreviews/" "$<TARGET_BUNDLE_CONTENT_DIR:RoonVis>/PresetPreviews/"
  COMMAND rsync -a --delete "${CMAKE_CURRENT_LIST_DIR}/Resources/textures/" "$<TARGET_BUNDLE_CONTENT_DIR:RoonVis>/textures/"
  COMMENT "Copying preset + preview + texture trees into the app bundle"
)

# Quality gate: warning-clean first-party app code (-Wall -Wextra; ObjC/C++ only —
# Swift has its own diagnostics). Vendor targets keep their own suppressions.
target_compile_options(RoonVis PRIVATE
  $<$<COMPILE_LANGUAGE:OBJCXX>:-Wall -Wextra>
  $<$<COMPILE_LANGUAGE:CXX>:-Wall -Wextra>
  $<$<COMPILE_LANGUAGE:OBJC>:-Wall -Wextra>
)

target_link_libraries(RoonVis PRIVATE
  sqlite3
  ANGLE
  projectM
  z
  "-framework Foundation"
  "-framework UIKit"
  "-framework Network"
  "-framework QuartzCore"
  "-framework Metal"
  "-framework CoreFoundation"
  "-framework CoreGraphics"
  "-framework IOSurface"
)
target_include_directories(RoonVis PRIVATE
  "${ANGLE_ROOT}/include"
  "${PROJECTM_ROOT}/src/api/include"
  "${CMAKE_CURRENT_BINARY_DIR}/projectm-build/src/api/include"
)
target_compile_definitions(RoonVis PRIVATE
  GL_GLES_PROTOTYPES=1
  EGL_EGL_PROTOTYPES=1
  GL_GLEXT_PROTOTYPES
  EGL_EGLEXT_PROTOTYPES
  # QA-only PresetValidator (its own EGL/GLES stack) is compiled out of the shipping
  # Release binary; the file stays in the source list but its body is #if'd out.
  $<$<NOT:$<CONFIG:Release>>:ROONVIS_ENABLE_PRESET_VALIDATOR=1>
  # Crasher-scan / perf-sweep diagnostic modes (dev/QA preset-curation tools) are
  # compiled out of Release so their env/NSUserDefaults reads never hit the render path.
  $<$<NOT:$<CONFIG:Release>>:ROONVIS_ENABLE_DIAGNOSTIC_MODES=1>
)
set_target_properties(RoonVis PROPERTIES
  LINKER_LANGUAGE OBJCXX
  XCODE_ATTRIBUTE_CODE_SIGN_STYLE Automatic
  XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${ROONVIS_DEVELOPMENT_TEAM}"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "local.roon-vis.gate-step-a"
  XCODE_ATTRIBUTE_INFOPLIST_FILE "${CMAKE_CURRENT_LIST_DIR}/Sources/RoonVis/Info.plist"
  XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "appletvos appletvsimulator"
  XCODE_ATTRIBUTE_SDKROOT "appletvos"
  XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
  XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_LIST_DIR}/Sources/RoonVis/RoonVis-Bridging-Header.h"
  XCODE_ATTRIBUTE_SWIFT_OBJC_INTERFACE_HEADER_NAME "RoonVis-Swift.h"
  XCODE_ATTRIBUTE_CLANG_ENABLE_MODULES "YES"
  "XCODE_ATTRIBUTE_SWIFT_OPTIMIZATION_LEVEL[variant=Debug]" "-Onone"
  XCODE_EMBED_FRAMEWORKS projectM
  XCODE_EMBED_FRAMEWORKS_CODE_SIGN_ON_COPY YES
  XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/Frameworks"
  XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "3"
  XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME ""
)
