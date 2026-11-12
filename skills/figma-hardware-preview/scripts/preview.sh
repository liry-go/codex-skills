#!/bin/sh
set -eu

scripts=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
system=$(uname -s)
python=$(command -v python3 || true)
if [ "$system" = Darwin ] && [ "$python" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1; then
    python=
fi
if [ -n "$python" ] && "$python" -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
    exec "$python" "$scripts/preview.py" "$@"
fi

host="$system-$(uname -m)"
read -r build checksum <<EOF
$(awk -v host="$host" '$1 == host {print $2, $3}' "$scripts/python-runtime.txt")
EOF
if [ -z "$build" ]; then
    printf 'Automatic Python setup is unavailable for %s. Install Python 3.10+ and retry.\n' "$host" >&2
    exit 1
fi

cache_dir=${FIGMA_PREVIEW_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/figma-hardware-preview}
target="$cache_dir/python-3.13.18-$host"
python="$target/bin/python3"
if [ ! -x "$python" ]; then
    mkdir -p -- "$cache_dir"
    staging=$(mktemp -d "$cache_dir/.python.XXXXXX")
    cleanup() { rm -r -- "$staging"; }
    trap cleanup EXIT

    version=20261110
    url="https://github.com/astral-sh/python-build-standalone/releases/download/$version/cpython-3.13.18%2B$version-$build-install_only_stripped.tar.gz"
    printf 'Downloading portable Python from Astral\n' >&2
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 240 --retry 1 --output "$staging/python.tar.gz" "$url"
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$staging/python.tar.gz")
    else
        actual=$(shasum -a 256 "$staging/python.tar.gz")
    fi
    if [ "${actual%% *}" != "$checksum" ]; then
        printf 'Python archive failed SHA-256 verification.\n' >&2
        exit 1
    fi
    tar -xzf "$staging/python.tar.gz" -C "$staging"
    "$staging/python/bin/python3" - "$staging/python" "$target" <<'PY'
import errno
from pathlib import Path
import sys

source, target = map(Path, sys.argv[1:])
try:
    source.rename(target)
except OSError as error:
    if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or not (target / "bin/python3").is_file():
        raise
PY
    cleanup
    trap - EXIT
fi
exec "$python" "$scripts/preview.py" "$@"
