#!/usr/bin/env bash
# Fetch, build and install the pinned clink release this project runs against.
#
# market-pulse consumes clink the way any downstream project does: clone the
# release tag, bootstrap the pinned Arrow toolchain (a prebuilt archive on
# supported platforms, a source build otherwise), build with the SQL frontend,
# and install into a local prefix. Everything lands under .clink/ inside this
# repository; nothing is written to system paths.
#
#   CLINK_VERSION      release tag to pin (default: the version this repo ships against)
#   CLINK_REPO         git URL (default: https://github.com/orhaugh/clink)
#   CLINK_JOBS         build parallelism (default: number of CPUs, capped at 10)
#   CLINK_SKIP_ICEBERG set to 1 to skip the iceberg-cpp toolchain build and the
#                      Iceberg impl. Required when the pinned Arrow is built
#                      without object stores (CLINK_ARROW_OBJECT_STORES=OFF, as
#                      this repo's CI does): iceberg-cpp's bundle references
#                      Arrow's S3 symbols unconditionally, so it cannot link
#                      against a no-S3 Arrow. Nothing here uses Iceberg.
#   CLINK_CMAKE_ARGS   extra arguments appended to the clink configure line
#   CLINK_SDK          path to a prebuilt SDK tarball
#                      (clink-<version>-linux-x86_64-ubuntu24.04.tar.gz) to
#                      install instead of the release: a release's asset, or
#                      the one a clink release-binaries dry run uploads. CI
#                      uses it to run this project against a clink release
#                      candidate before it is tagged.
#
# Idempotent: re-running against an existing matching install is a no-op.

set -euo pipefail

CLINK_VERSION="${CLINK_VERSION:-v0.15.0}"
CLINK_REPO="${CLINK_REPO:-https://github.com/orhaugh/clink}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/.clink/src"
PREFIX="${ROOT}/.clink/prefix"
STAMP="${PREFIX}/.market-pulse-installed"

ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
JOBS="${CLINK_JOBS:-$(( ncpu < 10 ? ncpu : 10 ))}"

install_sdk() {
    # $1 = SDK tarball, $2 = stamp contents. Verifies the tarball against the
    # .sha256 beside it when there is one, then unpacks it as the prefix.
    local tarball="$1" stamp="$2"
    local dir name tmp
    dir="$(cd "$(dirname "${tarball}")" && pwd)"
    name="$(basename "${tarball}")"
    if [[ -f "${dir}/${name}.sha256" ]]; then
        ( cd "${dir}" && sha256sum -c "${name}.sha256" >/dev/null )
    fi
    tmp="$(mktemp -d)"
    tar xzf "${tarball}" -C "${tmp}"
    mkdir -p "${ROOT}/.clink"
    rm -rf "${PREFIX}"
    mv "${tmp}/${name%.tar.gz}" "${PREFIX}"
    rm -rf "${tmp}"
    echo "${stamp}" > "${STAMP}"
    echo "== clink ${stamp} installed from the prebuilt SDK."
    echo "   CLI:            ${PREFIX}/bin/clink"
    echo "   CMake package:  ${PREFIX}/lib/cmake/clink (use -DCMAKE_PREFIX_PATH=${PREFIX})"
}

if [[ -n "${CLINK_SDK:-}" ]]; then
    want="sdk:$(basename "${CLINK_SDK}" .tar.gz)"
    if [[ -x "${PREFIX}/bin/clink" && -f "${STAMP}" ]] && grep -qx "${want}" "${STAMP}"; then
        echo "clink ${want} already installed at ${PREFIX}"
        exit 0
    fi
    echo "== market-pulse: installing clink from ${CLINK_SDK}"
    install_sdk "${CLINK_SDK}" "${want}"
    exit 0
fi

if [[ -x "${PREFIX}/bin/clink" && -f "${STAMP}" ]] \
   && grep -qx "${CLINK_VERSION}" "${STAMP}"; then
    echo "clink ${CLINK_VERSION} already installed at ${PREFIX}"
    exit 0
fi

echo "== market-pulse: installing clink ${CLINK_VERSION} into ${PREFIX}"

# Fast path: a prebuilt SDK tarball on the release (published from v0.4.0
# onwards for linux x86_64, glibc floor Ubuntu 24.04). Download, verify the
# published checksum, extract - about a minute, no compiler involved. Any
# miss (other platform, older release, no network) falls through to the
# source build below. CLINK_FROM_SOURCE=1 skips the attempt entirely.
if [[ "${CLINK_FROM_SOURCE:-0}" != "1" && "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]]; then
    asset="clink-${CLINK_VERSION}-linux-x86_64-ubuntu24.04.tar.gz"
    base="${CLINK_REPO%.git}/releases/download/${CLINK_VERSION}"
    tmp="$(mktemp -d)"
    echo "-- trying the prebuilt SDK: ${base}/${asset}"
    if curl -fsSL -o "${tmp}/${asset}" "${base}/${asset}" \
       && curl -fsSL -o "${tmp}/${asset}.sha256" "${base}/${asset}.sha256"; then
        install_sdk "${tmp}/${asset}" "${CLINK_VERSION}"
        rm -rf "${tmp}"
        exit 0
    fi
    rm -rf "${tmp}"
    echo "-- no prebuilt SDK for this release/platform; building from source"
fi

# 1. The release source, shallow, at the pinned tag.
if [[ -d "${SRC}/.git" ]]; then
    have="$(git -C "${SRC}" describe --tags --exact-match 2>/dev/null || true)"
    if [[ "${have}" != "${CLINK_VERSION}" ]]; then
        echo "-- existing checkout is '${have:-unknown}', refetching ${CLINK_VERSION}"
        rm -rf "${SRC}"
    fi
fi
if [[ ! -d "${SRC}/.git" ]]; then
    git clone --depth 1 --branch "${CLINK_VERSION}" "${CLINK_REPO}" "${SRC}"
fi

# 2. clink's pinned Arrow/Parquet/iceberg toolchain (~/.clink-deps by default).
#    Fast on platforms with a prebuilt archive (macOS arm64, Linux x86_64/arm64);
#    a from-source fallback exists everywhere else and is slow the first time.
(cd "${SRC}" && scripts/build-arrow.sh)
extra_args=()
if [[ "${CLINK_SKIP_ICEBERG:-0}" == "1" ]]; then
    extra_args+=("-DCLINK_WITH_ICEBERG=OFF")
else
    (cd "${SRC}" && scripts/build-iceberg-cpp.sh)
fi
if [[ -n "${CLINK_CMAKE_ARGS:-}" ]]; then
    # Deliberate word-splitting: CLINK_CMAKE_ARGS is a flat argument string.
    # shellcheck disable=SC2206
    extra_args+=(${CLINK_CMAKE_ARGS})
fi

# 3. Build the engine with the SQL frontend, and install it locally.
cmake -S "${SRC}" -B "${SRC}/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCLINK_BUILD_SQL=ON \
    -DCLINK_BUILD_TESTS=OFF \
    -DCLINK_BUILD_EXAMPLES=OFF \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    "${extra_args[@]}"
cmake --build "${SRC}/build" --parallel "${JOBS}"
cmake --install "${SRC}/build"

echo "${CLINK_VERSION}" > "${STAMP}"
echo
echo "== clink ${CLINK_VERSION} installed."
echo "   CLI:            ${PREFIX}/bin/clink"
echo "   CMake package:  ${PREFIX}/lib/cmake/clink (use -DCMAKE_PREFIX_PATH=${PREFIX})"
