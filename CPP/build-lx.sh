#!/bin/bash

set -eu

function build() {
  pushd 7zip/$2
  nproc=$(nproc)
  rm -rf "_o"

  case "$ARCH" in
    x86_64)
      make CC=$CC CXX=$CXX -j$((nproc-1)) -f makefile.gcc IS_X64=1 USE_ASM=1 MY_ASM=uasm || exit 1
      ;;
    i386)
      make CC=$CC CXX=$CXX -j$((nproc-1)) -f makefile.gcc IS_X86=1 USE_ASM=0
      ;;
    aarch64)
      make CC=$CC CXX=$CXX -j$((nproc-1)) -f makefile.gcc IS_ARM64=1 USE_ASM=0
      ;;
    *)
      echo "Unknown arch: $ARCH"
      exit 1
      ;;
  esac

  # strip down for releases
  strip _o/$1
  cp _o/$1 "$OUTDIR"
  popd
}

export ARCH=$(arch)
mkdir -p "$OUTDIR"

# standalone, minimalistic (flzma2, zstd)
build 7zr   Bundles/Alone7z

# standalone, small (flzma2, zstd, lz4, hashes)
build 7za   Bundles/Alone

# standalone, full featured
build 7zz   Bundles/Alone2

# full featured via plugin loading (7z.so)
build 7z    UI/Console
build 7z.so Bundles/Format7zF

function docker_build() {
  local DOCKER_IMAGE="${DOCKER_IMAGE:-alpine:3.23}"
  local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
  local DOCKER_OUTDIR="${1}"
  local BUILD_CC="${2:-gcc}"
  local BUILD_CXX="${3:-g++}"
  echo ""
  echo "=== Building in Docker container ==="
  echo "Image: $DOCKER_IMAGE"
  echo "Output: $DOCKER_OUTDIR"
  echo "CC: $BUILD_CC, CXX: $BUILD_CXX"
  mkdir -p "$DOCKER_OUTDIR"
  # Alpine packages for building
  local ALPINE_PKGS='build-base clang21-dev clang21 clang21-static llvm21-dev llvm21 llvm21-static pkgconf binutils file unzip'
  docker run --rm \
    -v "$PROJECT_ROOT:/src:ro" \
    -v "$DOCKER_OUTDIR:/output" \
    -e ARCH="$(arch)" \
    -e CC="$BUILD_CC" \
    -e CXX="$BUILD_CXX" \
    -e OUTDIR="/output" \
    -w /tmp/build \
    "$DOCKER_IMAGE" \
    sh -c "
      echo 'Installing packages...'
      apk update
      apk upgrade --no-cache
      apk add --no-cache $ALPINE_PKGS
      echo 'Copying source to writable directory...'
      cp -r /src/. /tmp/build/
      echo 'Building in container...'
      cd /tmp/build/
      if [ \"\$ARCH\" = \"x86_64\" ]; then apk add --no-cache gcompat; install -v -m 0755 uasm /usr/bin/; fi
      cd CPP/
      build() {
        local OLDWD=\$PWD
        cd 7zip/\$2
        local NPROC=\$(nproc)
        rm -rf '_o'
        # Set LDFLAGS based on compiler
        local LDFLAGS_VAL=\"\"
        case \"\$CC\" in
          *gcc*)
            LDFLAGS_VAL=\"-static -no-pie\"
            ;;
          *clang*)
            LDFLAGS_VAL=\"-static\"
            ;;
        esac
        case \"\$ARCH\" in
          x86_64)
            make CC=\"\$CC\" CXX=\"\$CXX\" LDFLAGS=\"\$LDFLAGS_VAL\" -j\$((NPROC-1)) -f makefile.gcc IS_X64=1 USE_ASM=1 MY_ASM=uasm
            ;;
          i386)
            make CC=\"\$CC\" CXX=\"\$CXX\" LDFLAGS=\"\$LDFLAGS_VAL\" -j\$((NPROC-1)) -f makefile.gcc IS_X86=1 USE_ASM=0
            ;;
          aarch64)
            make CC=\"\$CC\" CXX=\"\$CXX\" LDFLAGS=\"\$LDFLAGS_VAL\" -j\$((NPROC-1)) -f makefile.gcc IS_ARM64=1 USE_ASM=0
            ;;
          *)
            echo \"Unknown arch: \$ARCH\"
            exit 1
            ;;
        esac
        file _o/\$1 | sed -n -E 's/^(.*):[[:space:]]*ELF.*, not stripped.*/\1/p' | xargs --no-run-if-empty -I '{}' strip '{}'
        file _o/\$1
        cp -v _o/\$1 \"\$OUTDIR\"/\${1}s
        cd \"\$OLDWD\"
      }
      mkdir -p \"\$OUTDIR\"
      build 7zz   Bundles/Alone2
    "
  echo "Docker build completed: $DOCKER_OUTDIR"
}

# standalone, full featured, statically linked
if [ -z "${SKIP_DOCKER:-}" ] && [ -n "${CI:-}" ] && command -v docker &> /dev/null; then
  sudo systemctl start docker
  DOCKER_OUTDIR="${OUTDIR}"
  docker_build "$DOCKER_OUTDIR" "$CC" "$CXX"
fi
exit
