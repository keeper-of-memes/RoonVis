#!/usr/bin/env python3
import ast
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ANGLE = ROOT / "vendor" / "angle"


def read_array(path: Path, name: str) -> list[str]:
    text = path.read_text()
    match = re.search(rf"{re.escape(name)}\s*=(?:[^\[]*)\[(.*?)\]", text, re.S)
    if not match:
        raise SystemExit(f"missing GN array: {name}")
    body = "[" + match.group(1) + "]"
    body = re.sub(r"#.*", "", body)
    return ast.literal_eval(body)


def source_files(paths: list[str]) -> list[str]:
    exts = {".c", ".cc", ".cpp", ".m", ".mm"}
    return [p for p in paths if Path(p).suffix in exts]


lib_gni = ANGLE / "src" / "libGLESv2.gni"
compiler_gni = ANGLE / "src" / "compiler.gni"
metal_gni = ANGLE / "src" / "libANGLE" / "renderer" / "metal" / "metal_backend.gni"

sources: list[str] = []
sources += source_files(read_array(lib_gni, "libangle_common_sources"))
sources += ["src/common/backtrace_utils_noop.cpp"]
sources += [
    "src/common/apple_platform_utils.mm",
    "src/common/system_utils_apple.cpp",
    "src/common/system_utils_posix.cpp",
    "src/common/system_utils_ios.cpp",
]
sources += source_files(read_array(lib_gni, "libangle_common_shader_state_sources"))
sources += source_files(read_array(lib_gni, "xxhash_sources"))
sources += source_files(read_array(lib_gni, "libangle_image_util_sources"))
sources += ["src/image_util/AstcDecompressorNoOp.cpp"]
sources += source_files(read_array(lib_gni, "libangle_gpu_info_util_sources"))
sources += [
    "src/gpu_info_util/SystemInfo_apple.mm",
    "src/gpu_info_util/SystemInfo_ios.cpp",
]
sources += source_files(read_array(compiler_gni, "angle_preprocessor_sources"))
sources += source_files(read_array(compiler_gni, "angle_translator_sources"))
sources += source_files(read_array(compiler_gni, "angle_translator_essl_symbol_table_sources"))
sources += source_files(read_array(compiler_gni, "angle_translator_lib_msl_sources"))
sources += source_files(read_array(lib_gni, "libangle_sources"))
sources += [
    "src/common/angle_version_info.cpp",
    "src/libANGLE/capture/FrameCapture_mock.cpp",
    "src/libANGLE/capture/serialize_mock.cpp",
    "src/libANGLE/renderer/driver_utils_mac.mm",
    "src/libANGLE/renderer/driver_utils_ios.mm",
]
sources += source_files(read_array(lib_gni, "libglesv2_entry_point_sources"))
sources += source_files(read_array(lib_gni, "libglesv2_sources"))
sources += source_files(read_array(lib_gni, "libegl_sources"))
sources += ["src/libEGL/egl_loader_autogen.cpp"]
sources += [
    "src/libANGLE/renderer/metal/" + p
    for p in source_files(read_array(metal_gni, "metal_backend_sources"))
]

seen = set()
ordered = []
for source in sources:
    if source not in seen:
        seen.add(source)
        ordered.append(source)

missing = [source for source in ordered if not (ANGLE / source).exists()]
if missing:
    raise SystemExit("missing ANGLE sources:\n" + "\n".join(missing))

out = Path(sys.argv[1])
out.parent.mkdir(parents=True, exist_ok=True)
with out.open("w") as f:
    f.write("set(ANGLE_SOURCES\n")
    for source in ordered:
        f.write(f"  ${{ANGLE_ROOT}}/{source}\n")
    f.write(")\n")
