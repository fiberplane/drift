#!/usr/bin/env bash
# Benchmark drift's async speedup: download two release binaries and compare
# them on the current repo with hyperfine. Must be run from a repo that has
# `drift.lock` at its root.
#
# Usage:
#   tools/benchmark-speedup.sh                    # fresh-state benchmark
#   tools/benchmark-speedup.sh --stale            # also run all-sigs-stale variant
#   OLD=v0.8.1 NEW=v0.9.1 tools/benchmark-speedup.sh
#
# Requirements: hyperfine, curl, tar, awk, sed.

set -euo pipefail

OLD_VERSION="${OLD:-v0.8.1}"
NEW_VERSION="${NEW:-v0.9.1}"
RUNS="${RUNS:-20}"
WARMUP="${WARMUP:-3}"

if [[ ! -f drift.lock ]]; then
    echo "error: no drift.lock in $(pwd) — run this from a drift-enabled repo root" >&2
    exit 1
fi
if ! command -v hyperfine >/dev/null; then
    echo "error: hyperfine not installed (brew install hyperfine, or 'mise use hyperfine@latest')" >&2
    exit 1
fi

# Detect platform for release asset name.
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)   ASSET="drift-x86_64-linux.tar.gz" ;;
    Linux-aarch64)  ASSET="drift-aarch64-linux.tar.gz" ;;
    Darwin-x86_64)  ASSET="drift-x86_64-macos.tar.gz" ;;
    Darwin-arm64)   ASSET="drift-aarch64-macos.tar.gz" ;;
    *) echo "error: unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

BIN_DIR="$(mktemp -d -t drift-bench.XXXXXX)"
trap "rm -rf '$BIN_DIR'" EXIT

fetch() {
    local version="$1"
    local out="$2"
    local url="https://github.com/fiberplane/drift/releases/download/${version}/${ASSET}"
    echo "  fetching ${version} from ${url}..."
    curl -fsSL "$url" | tar -xzf - -C "$BIN_DIR"
    mv "$BIN_DIR/drift" "$out"
    chmod +x "$out"
}

echo "==> staging binaries"
fetch "$OLD_VERSION" "$BIN_DIR/drift-old"
fetch "$NEW_VERSION" "$BIN_DIR/drift-new"

echo
echo "==> smoke: verify both binaries produce clean output on this repo"
"$BIN_DIR/drift-old" check > /dev/null || {
    echo "warning: $OLD_VERSION exited non-zero (stale anchors or errors)" >&2
}
"$BIN_DIR/drift-new" check > /dev/null || {
    echo "warning: $NEW_VERSION exited non-zero (stale anchors or errors)" >&2
}

anchors=$(wc -l < drift.lock | tr -d ' ')
echo
echo "==> fresh-state benchmark (${anchors} anchors)"
hyperfine --warmup "$WARMUP" --runs "$RUNS" \
    --command-name "drift ${OLD_VERSION} (sequential)" "$BIN_DIR/drift-old check > /dev/null 2>&1" \
    --command-name "drift ${NEW_VERSION} (async)"      "$BIN_DIR/drift-new check > /dev/null 2>&1"

if [[ "${1:-}" == "--stale" ]]; then
    echo
    echo "==> all-stale benchmark (forces every sig to trigger a blame fetch)"
    cp drift.lock drift.lock.bench-bak
    # Rewrite every sig to all-zeros so every anchor is flagged stale.
    sed -i.tmp 's|sig:[a-f0-9]*|sig:0000000000000000|g' drift.lock
    rm -f drift.lock.tmp

    # Exit codes will be 1 (stale). Wrap with `|| true` so hyperfine doesn't abort.
    hyperfine --warmup 2 --runs 10 \
        --command-name "drift ${OLD_VERSION} (sequential blame)" "$BIN_DIR/drift-old check > /dev/null 2>&1 || true" \
        --command-name "drift ${NEW_VERSION} (parallel blame)"   "$BIN_DIR/drift-new check > /dev/null 2>&1 || true"

    mv drift.lock.bench-bak drift.lock
    echo "==> drift.lock restored"
fi

echo
echo "done."
