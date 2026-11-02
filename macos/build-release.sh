#!/usr/bin/env bash
#
# Build the release .app bundle(s) and package them as DMGs ready to attach to
# a GitHub Release. This is the same sequence .github/workflows/build-macos.yml
# runs in CI (configure -> build -> install -> ad-hoc sign -> make-dmg), just
# driven locally.
#
# Usage:
#   macos/build-release.sh [poe1|poe2|both]...
#
#   macos/build-release.sh          # PoE1 "Path of Building.app" -> dist/
#   macos/build-release.sh poe2     # PoE2 bundle
#   macos/build-release.sh both     # both, sequentially
#
# Environment overrides:
#   CMAKE               cmake binary to use              (default: cmake)
#   JOBS                parallel compile jobs            (default: hw.ncpu)
#   OUT_DIR             output directory                 (default: <repo>/dist)
#   POB_VERSION         bundle version for all targets   (default: the version
#                       pinned below, kept in sync with CI; must change on
#                       every release or upgrades won't refresh)
#   CODESIGN_IDENTITY   codesign identity                (default: "-", ad-hoc)
#
# Requirements:
#   - Apple Silicon Mac (the vcpkg triplet is arm64-only) + macOS 11+
#   - Xcode Command Line Tools: `xcode-select --install`
#   - CMake >= 3.15: `brew install cmake`
#   - Submodules: `git submodule update --init --recursive`
#
# Anything vcpkg needs (curl, openssl, glfw3, luajit, ANGLE, ...) is built from
# source on first run, so the first configure takes a while. Later runs reuse
# vcpkg's binary cache.
#
# Notes on what you get:
#   - The DMGs are ad-hoc signed, not notarized. Users will hit the Gatekeeper
#     "Apple could not verify" prompt once (right-click -> Open). Notarizing
#     needs an Apple Developer ID and `macos/notarize.sh`.
#   - To get notarized DMGs without building locally, push a tag instead and
#     let CI do it: see "Releasing" in MACOS_PORT.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CMAKE="${CMAKE:-cmake}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION_OVERRIDE="${POB_VERSION:-}"

usage() {
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    echo "error: $*" >&2
    exit 1
}

# ----- Arguments -----
TARGETS=()
for arg in "$@"; do
    case "$arg" in
        poe1|pob|pob1) TARGETS+=("poe1") ;;
        poe2)          TARGETS+=("poe2") ;;
        both|all)      TARGETS+=("poe1" "poe2") ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage >&2; die "unknown target '$arg'" ;;
    esac
done
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    TARGETS=("poe1")
fi

# ----- Preflight -----
[[ "$(uname -s)" == "Darwin" ]] || die "this wrapper builds macOS .app bundles only"
[[ "$(uname -m)" == "arm64" ]] || die "arm64 only (vcpkg-triplets/arm64-osx-pob.cmake); Intel is not supported"

command -v "$CMAKE" >/dev/null 2>&1 || die "cmake not found in PATH. Install it (brew install cmake) or set CMAKE=/path/to/cmake"

CMAKE_VERSION="$("$CMAKE" --version | head -1 | awk '{print $3}')"
if [[ "$(printf '%s\n3.15\n' "$CMAKE_VERSION" | sort -V | head -1)" != "3.15" ]]; then
    die "cmake $CMAKE_VERSION is too old; 3.15 or newer is required"
fi

for tool in codesign hdiutil xcrun; do
    command -v "$tool" >/dev/null 2>&1 ||
        die "$tool not found — install the Xcode Command Line Tools: xcode-select --install"
done

[[ -f SimpleGraphic/CMakeLists.txt ]] ||
    die "SimpleGraphic submodule is empty — run: git submodule update --init --recursive"

# Clear pkg-config's search path so Homebrew's openssl/zlib can't leak into
# vcpkg's curl build (CI does the same). The pkg-config *binary* is still
# needed; it just shouldn't be handed a pre-populated search path.
export PKG_CONFIG_PATH=

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

DMGS=()
VERSIONS=()

build_target() {
    local target="$1" lua_tree bundle_name bundle_id support_dir dmg_name pinned_version
    case "$target" in
        poe1)
            lua_tree="PathOfBuilding"
            bundle_name="Path of Building"
            bundle_id="ch.spidy.PathOfBuildingMac"
            support_dir="PathOfBuildingMac"
            dmg_name="PathOfBuilding-Mac"
            pinned_version="2.66.2-2"
            ;;
        poe2)
            lua_tree="PathOfBuilding-PoE2"
            bundle_name="Path of Building - PoE2"
            bundle_id="ch.spidy.PathOfBuildingMacPoE2"
            support_dir="PathOfBuildingMacPoE2"
            dmg_name="PathOfBuilding-Mac-PoE2"
            pinned_version="0.15.0"
            ;;
        *) die "unknown target '$target'" ;;
    esac

    [[ -f "$lua_tree/src/Launch.lua" ]] ||
        die "$lua_tree submodule is empty — run: git submodule update --init --recursive"

    # The bundle version drives Info.plist *and* the launcher's App Support
    # refresh marker (launcher.cpp re-extracts the bundled Lua tree only when
    # this string differs from the one recorded at install time). Rebuilding
    # with different Lua under an unchanged version is silently ignored by
    # existing installs, so this must change for every release. Keep it in sync
    # with CMakeLists.txt and the workflows; POB_VERSION overrides it.
    local version="${VERSION_OVERRIDE:-$pinned_version}"

    local build_dir="$REPO_ROOT/build-${target}-release"
    local stage_dir="$OUT_DIR/stage-${target}"
    local app="$stage_dir/$bundle_name.app"
    local dmg="$OUT_DIR/$dmg_name.dmg"

    echo
    echo "==> [$target] $bundle_name $version"
    echo "    build: $build_dir"
    echo "    stage: $stage_dir"

    echo "==> [$target] configure"
    "$CMAKE" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release \
        -DPOB_LUA_TREE="$REPO_ROOT/$lua_tree" \
        -DPOB_BUNDLE_VERSION="$version" \
        -DPOB_BUNDLE_NAME="$bundle_name" \
        -DPOB_BUNDLE_ID="$bundle_id" \
        -DPOB_APP_SUPPORT_DIR="$support_dir"

    echo "==> [$target] build ($JOBS jobs)"
    "$CMAKE" --build "$build_dir" --parallel "$JOBS"

    echo "==> [$target] install"
    # Start from a clean stage so a previous build's leftovers can't end up in
    # the DMG. Guarded so we can only ever delete inside $OUT_DIR.
    if [[ -e "$stage_dir" ]]; then
        case "$stage_dir" in
            "$OUT_DIR"/stage-*) rm -rf -- "$stage_dir" ;;
            *) die "refusing to remove unexpected path: $stage_dir" ;;
        esac
    fi
    "$CMAKE" --install "$build_dir" --prefix "$stage_dir"

    echo "==> [$target] sign (identity: $IDENTITY)"
    CODESIGN_IDENTITY="$IDENTITY" macos/sign.sh "$app"

    echo "==> [$target] package DMG"
    macos/make-dmg.sh "$app" "$dmg"

    DMGS+=("$dmg")
    VERSIONS+=("$target $version $dmg")
}

for target in "${TARGETS[@]}"; do
    build_target "$target"
done

echo
echo "==> Done"
printf '    %s\n' "${VERSIONS[@]}"
echo
echo "Attach to a GitHub Release (gh CLI, after 'gh auth login'):"
echo "    gh release create <tag> ${DMGS[*]} --title \"<title>\" --generate-notes"
echo "  or, for a release that already exists:"
echo "    gh release upload <tag> ${DMGS[*]} --clobber"
echo "  or use the web UI: Releases -> Edit release -> attach the .dmg files."
echo
if [[ "$IDENTITY" == "-" ]]; then
    echo "These DMGs are ad-hoc signed and not notarized: users who download them"
    echo "must right-click -> Open once to get past Gatekeeper. To notarize, sign"
    echo "with CODESIGN_IDENTITY='Developer ID Application: ...' and run"
    echo "macos/notarize.sh on each DMG."
fi
