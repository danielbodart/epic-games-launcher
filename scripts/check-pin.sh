#!/usr/bin/env bash
#
# Download the .deb sources.json pins, from the URL it pins, and check it is
# what sources.json says: the hash, the size, and the package and version in
# its control file.
#
# This checks the pin, not Epic's current release, so it gives the same
# answer whether or not upstream has moved on, or is part-way through a
# rollout. update.sh is what follows upstream.
#
# The download is a fresh one. Given the expected hash, nix would answer
# from a store path it already has without fetching anything, so this asks
# it for the hash of what the URL serves now (--refresh bypasses its
# download cache) and compares.
#
set -euo pipefail

readonly PACKAGE="epic-games-launcher"
readonly SYSTEM="x86_64-linux"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly SOURCES_JSON="$ROOT/sources.json"

log() { printf '\033[0;32m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

for tool in jq nix dpkg-deb; do
  command -v "$tool" >/dev/null 2>&1 || die "missing $tool (try: nix develop)"
done

version="$(jq -er '.version | strings' "$SOURCES_JSON")"
url="$(jq -er --arg s "$SYSTEM" '.sources[$s].url | strings' "$SOURCES_JSON")"
hash="$(jq -er --arg s "$SYSTEM" '.sources[$s].hash | strings' "$SOURCES_JSON")"
size="$(jq -er --arg s "$SYSTEM" '.sources[$s].size | numbers' "$SOURCES_JSON")"

log "downloading $url"
prefetch="$(nix store prefetch-file --refresh --json "$url")"
deb="$(jq -er .storePath <<<"$prefetch")"
actual_hash="$(jq -er .hash <<<"$prefetch")"
[ "$actual_hash" = "$hash" ] ||
  die "$url now serves $actual_hash, sources.json pins $hash"

actual_size="$(stat --format %s "$deb")"
[ "$actual_size" = "$size" ] ||
  die "the .deb is $actual_size bytes, sources.json says $size"

package="$(dpkg-deb --field "$deb" Package)"
[ "$package" = "$PACKAGE" ] ||
  die "the .deb is package '$package', expected '$PACKAGE'"
deb_version="$(dpkg-deb --field "$deb" Version)"
[ "$deb_version" = "$version" ] ||
  die "the .deb is version $deb_version, sources.json says $version"

log "$version: $hash, $size bytes, matches what $url serves"
