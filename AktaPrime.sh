#! /bin/bash
# Starts AktaPrime from this folder (Linux/macOS). The serial port and all other
# options are set in the program's Settings page.
#
# Uses the prebuilt system image (see sysimage/build.jl) when it exists and is
# newer than the code; otherwise starts normally — slower to start, but code
# changes are never silently ignored.
# --threads=3,1: the serial link has a worker thread to itself, so further ones
# are needed for background work such as reading opened runs.

cd "$(dirname "$0")"
IMAGE=sysimage/AktaPrime.so

if [ -f "$IMAGE" ]; then
    NEWER=$(find src Project.toml Manifest.toml -newer "$IMAGE" -type f | head -1)
    if [ -z "$NEWER" ]; then
        exec julia --threads=3,1 --sysimage "$IMAGE" --project=. -m AktaPrime "$@"
    fi
    echo "Note: the system image is older than $NEWER — starting without it."
    echo "      Rebuild it with:  julia --project=sysimage sysimage/build.jl"
fi
exec julia --threads=3,1 --project=. -m AktaPrime "$@"
