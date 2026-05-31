#!/usr/bin/env bash
#
# Cross-compile Nushell (nu + plugins) for Windows 7 and package a deployable
# directory ready to copy to a Win7 machine.
#
# Prerequisites:
#   rustup + nightly toolchain (NIGHTLY_TOOLCHAIN, default: nightly-2026-04-01)
#   rust-src component: rustup +nightly-2026-04-01 component add rust-src
#   cargo-xwin and xwin on PATH
#   curl or wget, and unzip (for bundling less.exe)
#   objdump and rg (for post-build combase.dll verification)
#
# Environment variables:
#   NIGHTLY_TOOLCHAIN  - rustup toolchain name (default: nightly-2026-04-01)
#   TARGET             - cross-compile target (default: x86_64-win7-windows-msvc)
#   DIST_DIR           - output parent directory (default: dist/)
#   CARGO_TARGET_DIR   - passed through to cargo if set
#
# Usage:
#   ./scripts/build-win7.sh
#   ./scripts/build-win7.sh --check-only
#   ./scripts/build-win7.sh --no-less --no-zip

set -euo pipefail

DIR=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")
REPO_ROOT=$(dirname "$DIR")

NIGHTLY_TOOLCHAIN="${NIGHTLY_TOOLCHAIN:-nightly-2026-04-01}"
TARGET="${TARGET:-x86_64-win7-windows-msvc}"
DIST_DIR="${DIST_DIR:-dist}"

INCLUDE_LESS=1
CREATE_ZIP=1
CHECK_ONLY=0

usage() {
    cat <<'EOF'
Usage: build-win7.sh [OPTIONS]

Cross-compile nu and plugins for Windows 7 via cargo-xwin.

Options:
  --no-less     Skip downloading less.exe
  --no-zip      Skip creating the release zip archive
  --check-only  Verify prerequisites and exit without building
  -h, --help    Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-less)
            INCLUDE_LESS=0
            shift
            ;;
        --no-zip)
            CREATE_ZIP=0
            shift
            ;;
        --check-only)
            CHECK_ONLY=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

die() {
    echo "error: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

download_file() {
    local url="$1"
    local dest="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        die "need curl or wget to download files"
    fi
}

get_version() {
    awk '
        /^\[workspace\.package\]/ { in_ws = 1; next }
        /^\[/ { in_ws = 0 }
        in_ws && /^version = / {
            gsub(/version = "/, "")
            gsub(/"/, "")
            print
            exit
        }
    ' "$REPO_ROOT/Cargo.toml"
}

check_prerequisites() {
    need_cmd rustup
    need_cmd cargo
    need_cmd xwin

    if ! command -v cargo-xwin >/dev/null 2>&1; then
        die "missing cargo-xwin (install with: cargo install cargo-xwin)"
    fi

    if ! rustup toolchain list | grep -q "^${NIGHTLY_TOOLCHAIN}"; then
        die "rustup toolchain '${NIGHTLY_TOOLCHAIN}' is not installed"
    fi

    if ! rustup "+${NIGHTLY_TOOLCHAIN}" component list --installed | grep -q '^rust-src'; then
        die "rust-src is not installed for ${NIGHTLY_TOOLCHAIN} (run: rustup +${NIGHTLY_TOOLCHAIN} component add rust-src)"
    fi

    if [[ "$INCLUDE_LESS" -eq 1 ]]; then
        need_cmd unzip
    fi

    if [[ "$CREATE_ZIP" -eq 1 ]]; then
        need_cmd zip
    fi

    if [[ "$CHECK_ONLY" -eq 0 ]]; then
        need_cmd objdump
        need_cmd rg
    fi

    echo "Prerequisites OK"
    echo "  nightly toolchain: ${NIGHTLY_TOOLCHAIN}"
    echo "  target:            ${TARGET}"
    echo "  repo root:         ${REPO_ROOT}"
}

fetch_less() {
    local dest_dir="$1"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local less_zip="${tmp_dir}/less-x64.zip"
    local less_url="https://github.com/jftuga/less-Windows/releases/download/less-v668/less-x64.zip"
    local license_url="https://github.com/jftuga/less-Windows/raw/master/LICENSE"

    echo "Fetching less.exe..."
    download_file "$less_url" "$less_zip"
    download_file "$license_url" "${dest_dir}/LICENSE-for-less.txt"
    unzip -q "$less_zip" -d "$tmp_dir"
    cp "${tmp_dir}/less.exe" "${dest_dir}/less.exe"
    rm -rf "$tmp_dir"
}

write_readme() {
    local dest="$1"
    cat >"$dest" <<'EOF'
Nushell for Windows 7
=====================

Copy this entire folder to your Windows 7 machine and add it to your PATH.

Quick test:
  nu.exe -c "version"

Plugins
-------
To use the included Nushell plugins, register the binaries with the `plugin add`
command to tell Nu where to find the plugin. Then use `plugin use` to load the
plugin into your session. For example:

> plugin add .\nu_plugin_query.exe
> plugin use query

For more information, refer to https://www.nushell.sh/book/plugins.html
EOF
}

package_release() {
    local version="$1"
    local release_dir="${DIST_DIR}/nu-${version}-${TARGET}"
    local release_root
    release_root=$(readlink -f "$REPO_ROOT")
    local target_dir
    target_dir=$(release_target_dir)

    if [[ ! -f "${target_dir}/nu.exe" ]]; then
        die "missing build artifact: ${target_dir}/nu.exe"
    fi

    echo "Packaging release to ${release_dir}..."
    rm -rf "$release_dir"
    mkdir -p "$release_dir"

    cp "${target_dir}/nu.exe" "${release_dir}/"
    shopt -s nullglob
    local plugins=("${target_dir}"/nu_plugin_*.exe)
    shopt -u nullglob

    if ((${#plugins[@]} == 0)); then
        die "no plugin binaries found in ${target_dir}"
    fi

    cp "${plugins[@]}" "${release_dir}/"
    cp "${REPO_ROOT}/LICENSE" "${release_dir}/"
    write_readme "${release_dir}/README.txt"

    if [[ "$INCLUDE_LESS" -eq 1 ]]; then
        fetch_less "$release_dir"
    fi

    echo "Release contents:"
    ls -la "$release_dir"

    if [[ "$CREATE_ZIP" -eq 1 ]]; then
        local zip_path="${DIST_DIR}/nu-${version}-${TARGET}.zip"
        echo "Creating ${zip_path}..."
        rm -f "$zip_path"
        (
            cd "$DIST_DIR"
            zip -rq "$(basename "$zip_path")" "$(basename "$release_dir")"
        )
        echo "Created ${zip_path}"
    fi

    echo ""
    echo "Done. Copy ${release_dir} (or the zip) to Windows 7 and add it to PATH."
}

release_target_dir() {
    local base="${CARGO_TARGET_DIR:-${REPO_ROOT}/target}"
    echo "${base}/${TARGET}/release"
}

verify_no_combase() {
    local nu_exe
    nu_exe="$(release_target_dir)/nu.exe"

    if [[ ! -f "$nu_exe" ]]; then
        die "missing build artifact for verification: ${nu_exe}"
    fi

    echo "Verifying ${nu_exe} does not import combase.dll..."
    if objdump -p "$nu_exe" | rg -q 'combase\.dll'; then
        die "nu.exe still imports combase.dll (likely windows 0.62 via sysinfo or another dep); check with: objdump -p ${nu_exe} | rg 'combase|ole32'"
    fi

    echo "OK: no combase.dll import"
}

build_release() {
    echo "---------------------------------------------------------------"
    echo "Building Nushell for ${TARGET}"
    echo "---------------------------------------------------------------"
    echo ""

    cd "$REPO_ROOT"

    cargo "+${NIGHTLY_TOOLCHAIN}" xwin build --release \
        --workspace --exclude nu-test-support \
        --target "${TARGET}" \
        -Z build-std=std,panic_abort
}

main() {
    check_prerequisites

    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        exit 0
    fi

    local version
    version=$(get_version)

    build_release
    verify_no_combase
    package_release "$version"
}

main "$@"
