#!/bin/sh
# v-BAZ :: off-grid artifact cache builder
#
# Assembles a cache of the DEFAULT versions of the published artifacts the
# v-BAZ mini-cloud needs, so the whole thing installs and RUNS with no network
# (off the grid). Output goes under <out>/rebekah/ and is picked up by the
# Windows installer (RebekahImageTarball / -Offline) and/or staged straight onto
# the ESP, where the rebekah OpenRC service loads it at first boot.
#
# What it caches (default versions from tools/artifacts.defaults, overridable in
# the environment):
#   * the Rebekah OCI image  (bundles OpenCode + Ollama + Sylvae + WeftMark)
#   * a default Ollama model (Ollama ships NO weights, so offline inference
#     needs this) -- pulled THROUGH the rebekah image itself so the store layout
#     and ollama version match exactly what runs on the host.
#
# Needs Docker + network on the BUILD host (not the target). Example:
#   sh tools/build-artifact-cache.sh ./offline/rebekah
#   REBEKAH_OLLAMA_MODEL=llama3.2:1b sh tools/build-artifact-cache.sh ./out
#   REBEKAH_OLLAMA_MODEL='' sh tools/build-artifact-cache.sh ./out   # image only
set -eu

OUT=${1:?usage: build-artifact-cache.sh <output-dir>}
# shellcheck disable=SC1007  # CDPATH= is a deliberate prefix for this cd
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEFAULTS="$REPO/tools/artifacts.defaults"

# Load pinned defaults, then let the environment override them.
[ -f "$DEFAULTS" ] && . "$DEFAULTS"
IMAGE=${REBEKAH_IMAGE:?REBEKAH_IMAGE unset and tools/artifacts.defaults missing}
MODEL=${REBEKAH_OLLAMA_MODEL:-}
DOCKER=${DOCKER:-docker}

command -v "$DOCKER" >/dev/null 2>&1 || { echo "need $DOCKER on the build host" >&2; exit 1; }

mkdir -p "$OUT"
echo "== v-BAZ artifact cache -> $OUT =="
echo "   image: $IMAGE"
echo "   model: ${MODEL:-<none>}"

# --- 1. Rebekah image ------------------------------------------------------
echo "  pulling $IMAGE"
"$DOCKER" pull "$IMAGE"
echo "  saving image tarball"
"$DOCKER" save "$IMAGE" | gzip -c > "$OUT/rebekah-image.tar.gz"

# --- 2. Default Ollama model (pulled through the rebekah image) ------------
if [ -n "$MODEL" ]; then
    echo "  caching Ollama model '$MODEL' (via the rebekah image)"
    cname="vbaz-model-cache-$$"
    mdir=$(mktemp -d)
    # Run rebekah so its bundled ollama serve is live, with the models dir bound
    # to a host directory we can tar afterwards. A throwaway git workspace keeps
    # WeftMark happy on boot; we only need ollama here.
    wdir=$(mktemp -d); ( cd "$wdir" && git init -q && git commit -q --allow-empty -m seed ) 2>/dev/null || true
    "$DOCKER" run -d --name "$cname" \
        -v "$mdir:/var/lib/rebekah/ollama/models" \
        -v "$wdir:/workspace" \
        "$IMAGE" >/dev/null
    ok=0
    i=0
    while [ "$i" -lt 60 ]; do
        if "$DOCKER" exec "$cname" curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then ok=1; break; fi
        i=$((i + 1)); sleep 1
    done
    if [ "$ok" = 1 ] && "$DOCKER" exec "$cname" ollama pull "$MODEL"; then
        echo "  packing model tarball"
        tar -C "$mdir" -czf "$OUT/ollama-model.tar.gz" .
    else
        echo "  WARN: model pull failed (ollama not healthy or model missing); skipping" >&2
        "$DOCKER" logs "$cname" 2>&1 | tail -5 >&2 || true
    fi
    "$DOCKER" rm -f "$cname" >/dev/null 2>&1 || true
    rm -rf "$mdir" "$wdir"
fi

# --- 3. Manifest of what was actually cached -------------------------------
{
    echo "# v-BAZ off-grid artifact cache (default versions)"
    echo "REBEKAH_IMAGE='$IMAGE'"
    [ -f "$OUT/rebekah-image.tar.gz" ] && echo "CACHED_IMAGE='rebekah-image.tar.gz'"
    if [ -n "$MODEL" ] && [ -f "$OUT/ollama-model.tar.gz" ]; then
        echo "REBEKAH_OLLAMA_MODEL='$MODEL'"
        echo "CACHED_MODEL='ollama-model.tar.gz'"
    fi
} > "$OUT/manifest.env"

echo "== done. Cache at $OUT =="
ls -lh "$OUT" 2>/dev/null || true
echo "Stage it: set RebekahImageTarball to $OUT/rebekah-image.tar.gz (and drop the"
echo "whole $OUT dir under the offline bundle's rebekah/ for the model), then run"
echo "Install-VBaz.ps1 -Offline <bundle>."
