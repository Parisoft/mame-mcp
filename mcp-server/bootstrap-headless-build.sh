#!/usr/bin/env bash
# license:BSD-3-Clause
#
# bootstrap-headless-build.sh
#
# Stages the build dependencies needed to compile a headless MAME in an
# environment where `apt` is unavailable (e.g. an agent sandbox with an
# HTTPS allow-list), then optionally builds SUBTARGET=tiny.
#
# On a normal CI box you do NOT need this -- just install:
#   libsdl2-dev libsdl2-ttf-dev libfontconfig-dev libegl1-mesa-dev
# and run the make line printed at the end.
#
# See docs/mcp/PLAN.md section 11 for why each workaround exists.

set -euo pipefail

DEPS="${DEPS:-$HOME/.mcpdeps}"
SDL_TAG="${SDL_TAG:-release-2.32.10}"
TTF_TAG="${TTF_TAG:-release-2.22.0}"
JOBS="${JOBS:-1}"          # >=3GB RAM per job required; see PLAN.md 11.5
WANT_SWAP_GB="${WANT_SWAP_GB:-4}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- SDL runtime
log "SDL2 runtime (.so) via pysdl2-dll wheel"
python3 -c 'import sdl2dll' 2>/dev/null || \
  pip3 install --quiet --break-system-packages pysdl2-dll
DLL="$(python3 -c 'import sdl2dll,os;print(os.path.join(os.path.dirname(sdl2dll.__file__),"dll"))')"
echo "    runtime: $DLL"

# ---------------------------------------------------------------- headers
log "Headers from GitHub (apt is unavailable)"
mkdir -p /tmp/hdrsrc
[ -d /tmp/hdrsrc/SDL ]     || git clone --depth 1 -q -b "$SDL_TAG" https://github.com/libsdl-org/SDL.git     /tmp/hdrsrc/SDL
[ -d /tmp/hdrsrc/SDL_ttf ] || git clone --depth 1 -q -b "$TTF_TAG" https://github.com/libsdl-org/SDL_ttf.git /tmp/hdrsrc/SDL_ttf
[ -d /tmp/hdrsrc/fc ]      || git clone --depth 1 -q https://github.com/behdad/fontconfig.git                /tmp/hdrsrc/fc

# ---------------------------------------------------------------- sysroot
log "Staging sysroot at $DEPS"
rm -rf "$DEPS"; mkdir -p "$DEPS"/{include/SDL2,include/fontconfig,lib,bin}
cp /tmp/hdrsrc/SDL/include/*.h            "$DEPS/include/SDL2/"
cp /tmp/hdrsrc/SDL_ttf/SDL_ttf.h          "$DEPS/include/SDL2/"
cp /tmp/hdrsrc/fc/fontconfig/fontconfig.h /tmp/hdrsrc/fc/fontconfig/fcprivate.h "$DEPS/include/fontconfig/"
[ -f "$DEPS/include/SDL2/SDL_config.h" ] || \
  cp /tmp/hdrsrc/SDL/include/SDL_config.h.default "$DEPS/include/SDL2/SDL_config.h" 2>/dev/null || true
cat > "$DEPS/include/SDL2/SDL_revision.h" <<EOF
#define SDL_REVISION "$SDL_TAG"
#define SDL_REVISION_NUMBER 0
EOF

ln -sf "$DLL/libSDL2-2.0.so"     "$DEPS/lib/libSDL2.so"
ln -sf "$DLL/libSDL2-2.0.so"     "$DEPS/lib/libSDL2-2.0.so.0"
ln -sf "$DLL/libSDL2_ttf-2.0.so" "$DEPS/lib/libSDL2_ttf.so"
ln -sf "$DLL/libSDL2_ttf-2.0.so" "$DEPS/lib/libSDL2_ttf-2.0.so.0"
for f in /usr/lib/x86_64-linux-gnu/libfontconfig.so.1 /usr/lib/x86_64-linux-gnu/libfreetype.so.6; do
  [ -e "$f" ] && ln -sf "$f" "$DEPS/lib/$(basename "$f" | sed 's/\.so\..*/.so/')"
done

# NO_X11=1 makes scripts/src/osd/sdl.lua link -lEGL on Linux. With -video none
# EGL is never called, so an empty stub satisfies the linker. (PLAN.md 11.5 #2)
log "libEGL stub (never called under -video none)"
echo 'static int _egl_stub;' > /tmp/egl_stub.c
gcc -shared -fPIC -o "$DEPS/lib/libEGL.so" /tmp/egl_stub.c
ln -sf "$DEPS/lib/libEGL.so" "$DEPS/lib/libEGL.so.1"

# ---------------------------------------------------------------- shims
log "pkg-config / sdl2-config shims"
cat > "$DEPS/bin/pkg-config" <<EOF
#!/bin/bash
DEPS=$DEPS
args="\$*"; have=0
for a in "\$@"; do case "\$a" in sdl2|SDL2_ttf|fontconfig|freetype2) have=1;; esac; done
case "\$args" in
  *--exists*)     [ \$have = 1 ] && exit 0 || exit 1 ;;
  *--modversion*) echo "2.32.10"; exit 0 ;;
esac
out=""
case "\$args" in *--cflags*) out="-I\$DEPS/include";; esac
case "\$args" in
  *--libs*)
    case "\$args" in
      *fontconfig*) out="\$out -L\$DEPS/lib -lfontconfig";;
      *SDL2_ttf*)   out="\$out -L\$DEPS/lib -lSDL2_ttf";;
      *sdl2*)       out="\$out -L\$DEPS/lib -lSDL2";;
      *)            out="\$out -L\$DEPS/lib";;
    esac;;
esac
echo \$out
EOF
cat > "$DEPS/bin/sdl2-config" <<EOF
#!/bin/bash
DEPS=$DEPS
for a in "\$@"; do case "\$a" in
  --cflags)             printf -- "-I\$DEPS/include/SDL2 -D_REENTRANT ";;
  --libs|--static-libs) printf -- "-L\$DEPS/lib -lSDL2 ";;
  --version)            printf "2.32.10";;
esac; done
echo
EOF
chmod +x "$DEPS/bin/pkg-config" "$DEPS/bin/sdl2-config"

# ---------------------------------------------------------------- env file
cat > "$DEPS/env.sh" <<EOF
export DEPS=$DEPS
export DLL=$DLL
export PATH=\$DEPS/bin:\$PATH
export LD_LIBRARY_PATH=\$DEPS/lib:\$DLL
export LIBRARY_PATH=\$DEPS/lib
export CPATH=\$DEPS/include
EOF
echo "    env: source $DEPS/env.sh"

# ---------------------------------------------------------------- swap
if [ "$(free -m | awk '/^Swap:/{print $2}')" = "0" ] && [ "$WANT_SWAP_GB" != "0" ]; then
  log "Adding ${WANT_SWAP_GB}G swap (GCC needs >2GB per TU on emumem_aspace.cpp)"
  sudo dd if=/dev/zero of=/swapfile bs=1M count=$((WANT_SWAP_GB*1024)) status=none
  sudo chmod 600 /swapfile && sudo mkswap -q /swapfile >/dev/null && sudo swapon /swapfile
  free -m | sed -n '3p'
fi

# ---------------------------------------------------------------- build
MAKE_ARGS=(
  SUBTARGET=tiny OSD=sdl
  NO_X11=1 NO_USE_XINPUT=1 NO_OPENGL=1 USE_QTDEBUG=0
  NO_USE_MIDI=1 NO_USE_PORTAUDIO=1 NO_USE_PULSEAUDIO=1 NO_USE_PIPEWIRE=1
  NOWERROR=1                                  # GCC12 -Werror=restrict false positives
  ARCHOPTS_CXX=-DUSE_OZONE=1                  # bypass bgfx EGL -> X11/Xlib.h
  ARCHOPTS_C=-DUSE_OZONE=1                    # (do NOT use ARCHOPTS: breaks -m64)
  PYTHON_EXECUTABLE=python3
)
log "Ready. Build with:"
echo "    source $DEPS/env.sh && make ${MAKE_ARGS[*]} -j$JOBS"

if [ "${DO_BUILD:-0}" = "1" ]; then
  log "Building (JOBS=$JOBS) ..."
  # shellcheck disable=SC1090
  source "$DEPS/env.sh"
  cd "$(dirname "$0")/.."
  exec make "${MAKE_ARGS[@]}" -j"$JOBS"
fi
