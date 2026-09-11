#!/usr/bin/env bash
# A same-workflow-run package snapshot; never reuse indexes indefinitely.
set -euo pipefail
mode=${1:?Expected seed or measure}
root=${RUNNER_TEMP:?}/ubuntu-package-cache
packages=(libssl-dev libasound2-dev libdbus-1-dev libxcb-shape0-dev libxcb-xfixes0-dev)
opts=(-o "Dir::State::lists=$root/lists" -o "Dir::Cache::archives=$root/archives")

case "$mode" in
  seed)
    mkdir -p "$root/lists/partial" "$root/archives/partial"
    # A new index directory forces a fresh, signature-checked index download.
    sudo apt-get "${opts[@]}" -o APT::Update::Error-Mode=any update
    sudo apt-get "${opts[@]}" --download-only -y install "${packages[@]}"
    # Cache ordinary files only, not apt locks or partial transfers.
    sudo rm -f "$root/lists/lock" "$root/archives/lock"
    sudo chown -R "$(id -u):$(id -g)" "$root"
    (
      cd "$root"
      find lists archives -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
      test -s SHA256SUMS
    )
    date -u +%FT%TZ > "$root/seeded-at.txt"
    ;;
  measure)
    test -s "$root/SHA256SUMS"
    ;;
  *) echo "Unknown mode: $mode" >&2; exit 2 ;;
esac

(cd "$root" && sha256sum --check --quiet SHA256SUMS)
echo "Package snapshot created at $(cat "$root/seeded-at.txt")"
echo "Cached package bytes: $(du -sb "$root/archives" | cut -f1)"
# Fail on missing archives rather than silently falling back to the network.
sudo apt-get "${opts[@]}" --no-download -y install "${packages[@]}"
sudo apt-get check
# Restore user ownership for the cache-save action after apt has run.
sudo chown -R "$(id -u):$(id -g)" "$root"
