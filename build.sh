#!/usr/bin/env bash
# Build Elona+ Custom-GX for the browser on Boxedwine's multi-threaded web build.
#
# boxedwine.js / boxedwine.wasm are compiled from the Boxedwine source (release tag)
# with emscripten, as upstream's "make multiThreaded" does, plus memory growth
# (upstream links that target with a fixed 512 MB heap) and the source fixes in
# patches/<tag>/ (audio-callback-lock.patch: the "memory access out of bounds"
# crash once sound is on).
#
#   ./build.sh            -> dist/ (serve it over http(s))
#
# Options (environment variables):
#   BOXEDWINE_VERSION=26R1    Boxedwine release: source tag <version>.0 and its Wine 11 file system
#   EMSDK_VERSION=5.0.6       emscripten used to compile (the one the 26R1 release was built with)
#   EMSDK_DIR=cache/emsdk     reuse an existing emsdk checkout instead of installing one
#   MAX_MEMORY_MB=2048        heap growth limit (512..4096; above 2048 costs some speed)
#   JOBS=<cpu count>          parallel compile jobs
#   CGX_VERSION=2.15R.1.1     Ruin0x11/ElonaPlusCustom-GX release
#   ELONA_ZIP=/path/elonaplus2.15R.zip   use a local base game instead of MEGA
#
# Needs: bash, git, make, curl, unzip, zip, openssl, python3, and 7z (or pip for py7zr).
# First run downloads emsdk (~1 GB on disk) and compiles Boxedwine (10-30 minutes);
# later runs reuse both from cache/.
set -euo pipefail

BOXEDWINE_VERSION="${BOXEDWINE_VERSION:-26R1}"
BOXEDWINE_TAG="${BOXEDWINE_TAG:-$BOXEDWINE_VERSION.0}"
EMSDK_VERSION="${EMSDK_VERSION:-5.0.6}"
MAX_MEMORY_MB="${MAX_MEMORY_MB:-2048}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
CGX_VERSION="${CGX_VERSION:-2.15R.1.1}"
ELONA_MEGA_URL="${ELONA_MEGA_URL:-https://mega.nz/file/Zjo2WR4L#cEWZoNlsNGyu5KNS9iZwDToCVaSQfuJ1eK3WznwpWmk}"
ELONA_ZIP="${ELONA_ZIP:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$HERE/cache"   # downloads, emsdk, Boxedwine source and objects; reused between runs
WORK="$HERE/work"     # scratch, rebuilt every run
OUT="$HERE/dist"      # the website
WEB="$HERE/web"       # index.html, shell.js, coi-serviceworker.js
EMSDK_DIR="${EMSDK_DIR:-$CACHE/emsdk}"

BW_GIT="https://github.com/danoon2/Boxedwine.git"
EMSDK_GIT="https://github.com/emscripten-core/emsdk.git"
# Only the Wine 11 root file system (Wine11/boxedwine.zip) is taken from the release.
BW_RELEASE_URL="https://github.com/danoon2/Boxedwine/releases/download/$BOXEDWINE_TAG/Boxedwine${BOXEDWINE_VERSION}Web.zip"
CGX_URL="https://github.com/Ruin0x11/ElonaPlusCustom-GX/releases/download/$CGX_VERSION/Elona+.Custom-GX.$CGX_VERSION.7z"
# The web release ships a stripped Wine 11. Boxedwine's full Wine 11 file system
# (same build, what the desktop app downloads) supplies the few DLLs it lacks.
WINE_FULL_URL="https://boxedwine.org/v2/6/TinyCore15Wine11.0.zip"
WINE_EXTRA_FILES=(
    opt/wine/lib/wine/i386-unix/windowscodecs.dll.so   # PNG loading (gdiplus -> WIC)
    opt/wine/lib/wine/i386-unix/d3d9.dll.so            # imported by hmm.dll
    opt/wine/lib/wine/i386-windows/lz32.dll            # imported by hspext_ext.dll
)
GAME_DIR="home/username/.wine/drive_c/elona"   # C:\elona inside Wine

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in git make curl unzip zip openssl python3; do
    command -v "$tool" >/dev/null || die "missing '$tool'"
done
[ -f "$WEB/index.html" ] && [ -f "$WEB/shell.js" ] || die "web/index.html and web/shell.js must be next to build.sh"
[[ "$MAX_MEMORY_MB" =~ ^[0-9]+$ ]] && [ "$MAX_MEMORY_MB" -ge 512 ] && [ "$MAX_MEMORY_MB" -le 4096 ] \
    || die "MAX_MEMORY_MB must be between 512 and 4096"

mkdir -p "$CACHE"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

# fetch URL FILE: download once into the cache.
fetch() {
    if [ -s "$CACHE/$2" ]; then
        echo "cached: $2"
    else
        echo "downloading: $1"
        curl -fL --retry 3 -o "$CACHE/$2.part" "$1"
        mv "$CACHE/$2.part" "$CACHE/$2"
    fi
}

# mega_fetch MEGA_FILE_URL FILE: download and decrypt a public MEGA file link.
mega_fetch() {
    if [ -s "$CACHE/$2" ]; then echo "cached: $2"; return; fi
    local info url key iv
    info="$(python3 - "$1" <<'PY'
import base64, json, struct, sys, urllib.request
link = sys.argv[1]
handle, key = link.split("/file/")[1].split("#")
def b64(s):
    s = s.replace("-", "+").replace("_", "/")
    return base64.b64decode(s + "=" * (-len(s) % 4))
a = struct.unpack(">8I", b64(key))
aes_key = struct.pack(">4I", a[0] ^ a[4], a[1] ^ a[5], a[2] ^ a[6], a[3] ^ a[7])
iv = struct.pack(">4I", a[4], a[5], 0, 0)
req = urllib.request.Request("https://g.api.mega.co.nz/cs?id=1",
    data=json.dumps([{"a": "g", "g": 1, "ssl": 2, "p": handle}]).encode(),
    headers={"Content-Type": "application/json"})
res = json.load(urllib.request.urlopen(req))[0]
if not isinstance(res, dict) or "g" not in res:
    sys.exit("MEGA API error: %r" % (res,))
print(res["g"], aes_key.hex(), iv.hex())
PY
)" || die "could not resolve the MEGA link (set ELONA_ZIP to a local copy instead)"
    read -r url key iv <<<"$info"
    echo "downloading (MEGA): $2"
    curl -fL --retry 3 "$url" | openssl enc -d -aes-128-ctr -K "$key" -iv "$iv" -out "$CACHE/$2.part"
    mv "$CACHE/$2.part" "$CACHE/$2"
}

# extract_7z ARCHIVE DIR
extract_7z() {
    local seven
    for seven in 7zz 7z 7za; do
        if command -v "$seven" >/dev/null; then "$seven" x -y -o"$2" "$1" >/dev/null; return; fi
    done
    if ! python3 -c 'import py7zr' 2>/dev/null; then
        [ -x "$CACHE/venv/bin/python" ] || python3 -m venv "$CACHE/venv"
        "$CACHE/venv/bin/python" -m pip install -q py7zr
        "$CACHE/venv/bin/python" -m py7zr x "$1" "$2"
    else
        python3 -m py7zr x "$1" "$2"
    fi
}

log "emscripten $EMSDK_VERSION"
[ -d "$EMSDK_DIR/.git" ] || git clone --depth 1 "$EMSDK_GIT" "$EMSDK_DIR"
"$EMSDK_DIR/emsdk" install "$EMSDK_VERSION"
"$EMSDK_DIR/emsdk" activate "$EMSDK_VERSION" >/dev/null
set +u
# shellcheck disable=SC1091
source "$EMSDK_DIR/emsdk_env.sh" >/dev/null 2>&1
set -u
emcc --version | head -n1 | grep -qF "$EMSDK_VERSION" || die "emcc is not version $EMSDK_VERSION"

log "Boxedwine $BOXEDWINE_TAG from source (multi-threaded, heap 512 MB growing to $MAX_MEMORY_MB MB)"
SRC="$CACHE/boxedwine-$BOXEDWINE_TAG"
[ -d "$SRC/.git" ] || git clone --depth 1 --branch "$BOXEDWINE_TAG" "$BW_GIT" "$SRC"
# Source fixes for this tag (patches/<tag>/*.patch), each applied once.
for patch in "$HERE/patches/$BOXEDWINE_TAG"/*.patch; do
    [ -e "$patch" ] || continue
    if git -C "$SRC" apply --reverse --check "$patch" 2>/dev/null; then
        echo "patch already applied: ${patch#"$HERE"/}"
    else
        git -C "$SRC" apply "$patch" || die "could not apply ${patch#"$HERE"/}"
        echo "patch applied: ${patch#"$HERE"/}"
    fi
done
# Same compile and link settings as upstream's multiThreaded target, plus memory growth.
# The makefile's own -s TOTAL_MEMORY=536870912 becomes the initial heap size.
# -Wno-pthreads-mem-growth silences emcc's warning that JS heap access is slower with
# pthreads + growth; Boxedwine's emulation runs in wasm, which isn't affected.
BUILD_DIR="Build/MultiThreaded-grow-em$EMSDK_VERSION"
rm -f "$SRC/project/emscripten/$BUILD_DIR"/boxedwine.{html,js,wasm,worker.js}   # always relink
make -C "$SRC/project/emscripten" -j"$JOBS" \
    BUILD_DIR="$BUILD_DIR" \
    SHELL_FILE=shell.html \
    EXTRA_CPP_FLAGS="-DBOXEDWINE_MULTI_THREADED -pthread" \
    EXTRA_LD_FLAGS="-pthread -sPTHREAD_POOL_SIZE=32 -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=$((MAX_MEMORY_MB * 1024 * 1024)) -Wno-pthreads-mem-growth"
BUILT="$SRC/project/emscripten/$BUILD_DIR"
[ -f "$BUILT/boxedwine.js" ] && [ -f "$BUILT/boxedwine.wasm" ] || die "build finished without boxedwine.js/boxedwine.wasm"
cp "$BUILT/boxedwine.js" "$BUILT/boxedwine.wasm" "$OUT/"
[ ! -f "$BUILT/boxedwine.worker.js" ] || cp "$BUILT/boxedwine.worker.js" "$OUT/"   # older emscripten only
cp "$SRC/license.txt" "$OUT/license.txt"

log "Wine 11 file system from the Boxedwine $BOXEDWINE_VERSION release"
fetch "$BW_RELEASE_URL" "Boxedwine${BOXEDWINE_VERSION}Web.zip"
unzip -p "$CACHE/Boxedwine${BOXEDWINE_VERSION}Web.zip" Wine11/boxedwine.zip > "$OUT/boxedwine.zip"
[ -s "$OUT/boxedwine.zip" ] || die "Wine11/boxedwine.zip not found in the release zip"

log "Extra Wine 11 DLLs from Boxedwine's full file system"
fetch "$WINE_FULL_URL" "TinyCore15Wine11.0.zip"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
unzip -q -o "$CACHE/TinyCore15Wine11.0.zip" "${WINE_EXTRA_FILES[@]}" -d "$STAGE"

log "Elona+ 2.15R base game"
if [ -n "$ELONA_ZIP" ]; then
    cp "$ELONA_ZIP" "$CACHE/elonaplus2.15R.zip"
else
    mega_fetch "$ELONA_MEGA_URL" "elonaplus2.15R.zip"
fi
unzip -tq "$CACHE/elonaplus2.15R.zip" >/dev/null || { rm -f "$CACHE/elonaplus2.15R.zip"; die "base game zip is corrupt, run again"; }
mkdir -p "$WORK/base"
unzip -q "$CACHE/elonaplus2.15R.zip" -d "$WORK/base"
BASE="$(dirname "$(find "$WORK/base" -maxdepth 3 -name elonaplus.exe | head -n1)")"
[ -d "$BASE" ] || die "elonaplus.exe not found in the base game zip"

log "Elona+ Custom-GX $CGX_VERSION"
fetch "$CGX_URL" "Custom-GX.$CGX_VERSION.7z"
mkdir -p "$WORK/cgx"
extract_7z "$CACHE/Custom-GX.$CGX_VERSION.7z" "$WORK/cgx"
CGX="$(dirname "$(find "$WORK/cgx" -maxdepth 3 -name elonapluscgx.exe | head -n1)")"
[ -d "$CGX" ] || die "elonapluscgx.exe not found in the Custom-GX archive"

log "Assembling the game"
mkdir -p "$STAGE/$GAME_DIR"
cp -a "$BASE/." "$STAGE/$GAME_DIR/"
cp -a "$CGX/." "$STAGE/$GAME_DIR/"   # Custom-GX overwrites the base files
# Japanese readmes/charts have Shift-JIS names; the game never opens them.
LC_ALL=C find "$STAGE/$GAME_DIR" -name '*[^ -~]*' -print -delete
# No network in the browser: turn off the online features and joypad polling.
# Fullscreen: the game owns the whole 800x600 emulated screen, no window frame.
LC_ALL=C sed -i -E \
    -e 's/^(fullscreen\.[[:space:]]+)"[0-9]+"/\1"1"/' \
    -e 's/^(net\.[[:space:]]+)"[0-9]+"/\1"0"/' \
    -e 's/^(netWish\.[[:space:]]+)"[0-9]+"/\1"0"/' \
    -e 's/^(netChat\.[[:space:]]+)"[0-9]+"/\1"0"/' \
    -e 's/^(joypad\.[[:space:]]+)"[0-9]+"/\1"0"/' \
    "$STAGE/$GAME_DIR/config.txt"

log "Packing elona.zip"
(cd "$STAGE" && zip -q -r -X -n .mp3:.ogg:.png:.jpg "$OUT/elona.zip" home opt)

log "Web assets"
cp "$WEB"/index.html "$WEB"/shell.js "$WEB"/coi-serviceworker.js "$OUT/"

rm -rf "$WORK"
log "Done: $OUT"
ls -lh "$OUT"
cat <<EOF

Test locally:  cd dist && python3 -m http.server 8000   then open http://localhost:8000/
Publish:       upload the contents of dist/ to any static host (GitHub Pages works,
               coi-serviceworker.js supplies the headers the multi-threaded build needs).
EOF
