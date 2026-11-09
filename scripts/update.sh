#!/usr/bin/env bash
#
# Regenerate sources.json from Epic's download service.
#
# Epic publishes the Linux launcher as a single .deb with no apt repository,
# no published checksum and no signature, so unlike the sibling repositories
# there is no signed index to read a hash out of. What this script can do is
# refuse to write anything it cannot cross-check:
#
#   Builds/EGLv2/stable-target.json   the version the launcher itself updates to
#     == the version the fixed download link redirects to
#          -> Builds/EGLv2/<version>/Linux/EpicGamesLauncher-x86_64.deb
#               downloaded here, hashed, and its control file checked:
#               Package and Version must match, Depends and the file list
#               must be the ones package.nix was written for.
#
# The hash is therefore trust on first use: the bytes Epic's CDN served over
# TLS when the updater ran. Nix checks every later download against it, so a
# pin never silently changes underneath anyone, but nothing upstream vouches
# for it beyond the connection. See Provenance in the README.
#
set -euo pipefail

readonly CDN_URL="https://content-download-egs.distro.on.epicgames.com/Builds/EGLv2"
readonly MANIFEST_URL="$CDN_URL/stable-target.json"
readonly LATEST_URL="https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncher-x86_64.deb"
readonly DEB_NAME="EpicGamesLauncher-x86_64.deb"
readonly PACKAGE="epic-games-launcher"

# Debian architecture -> Nix system. Epic publishes no others: the arm64
# equivalents of these URLs are 404.
readonly ARCH="amd64"
readonly SYSTEM="x86_64-linux"

# The .deb's Depends, deduplicated and sorted, which package.nix provides
# for. A new entry needs a matching nixpkgs package there before this list
# is changed to accept it.
readonly EXPECTED_DEPENDS="libayatana-appindicator3-1 libgtk-3-0 libwebkit2gtk-4.1-0"

# The paths package.nix copies or patches. One going missing still builds,
# but ships a launcher with a hole in it.
readonly REQUIRED_FILES=(
  usr/bin/EpicGamesLauncher
  usr/lib/epic-games-launcher/libEOSSDK-Linux-Shipping.so
  usr/lib/epic-games-launcher/resources/ThirdPartyNotices.txt
  usr/share/applications/epic-games-launcher.desktop
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly SOURCES_JSON="$ROOT/sources.json"

log() { printf '\033[0;32m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_tools() {
  local missing=()
  for tool in curl jq nix dpkg-deb; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing required tools: ${missing[*]} (try: nix develop)"
}

fetch() {
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --max-time 120 "$1"
}

# Where the fixed "latest" link points, without following it: the versioned
# URL, query string (a download file name hint) removed, and the + in the
# version decoded, whether Epic encoded it once (%2B) or twice (%252B).
redirect_target() {
  local target
  target="$(curl --fail --silent --show-error --retry 3 --retry-delay 2 --max-time 120 \
    --output /dev/null --write-out '%{redirect_url}' "$LATEST_URL")"
  [ -n "$target" ] || die "$LATEST_URL did not redirect"
  target="${target%%\?*}"
  target="${target//%252B/+}"
  target="${target//%2B/+}"
  printf '%s' "$target"
}

main() {
  local check_only=false force=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check_only=true; shift ;;
      --force) force=true; shift ;;
      --help)
        cat <<'USAGE'
Usage: scripts/update.sh [--check] [--force]

Rewrites sources.json from Epic's download service.

  --check   Report whether an update is available and exit non-zero if one
            is, without downloading or writing anything.
  --force   Rewrite sources.json even when the pinned version is already the
            newest one, so that its contents can be compared against a fresh
            download, or when Epic's current version is older than the
            pinned one.
USAGE
        exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  require_tools

  log "fetching $MANIFEST_URL"
  local manifest latest_version
  manifest="$(fetch "$MANIFEST_URL")"
  latest_version="$(jq -er '.version | strings' <<<"$manifest")" ||
    die "no version in stable-target.json: $manifest"

  # The version goes into a URL and a store path name, so allow only what
  # Epic has used so far: 0.113.0+g2164614.
  [[ $latest_version =~ ^[0-9]+(\.[0-9]+)*\+g[0-9a-f]+$ ]] ||
    die "unexpected version format in stable-target.json: '$latest_version'"

  # Two independent answers to "what is the current release": the manifest
  # the installed launcher polls, and the link Epic's website hands out. A
  # disagreement means a release is half rolled out, and pinning either one
  # would be a guess.
  local url redirected
  url="$CDN_URL/${latest_version//+/%2B}/Linux/$DEB_NAME"
  redirected="$(redirect_target)"
  [ "$redirected" = "$CDN_URL/$latest_version/Linux/$DEB_NAME" ] ||
    die "stable-target.json says $latest_version, but the download link points at $redirected"

  local current_version
  current_version="$(jq -r '.version' "$SOURCES_JSON" 2>/dev/null || echo "none")"
  log "current: $current_version, latest: $latest_version"

  if [ "$current_version" = "$latest_version" ] && [ "$force" = false ]; then
    log "already up to date"
    exit 0
  fi

  # stable-target.json is a pointer Epic can move either way (it carries a
  # mode and an emergencyOverride), so a different version is not always a
  # newer one. A rollback is for a human to look at, not to land and
  # release; --force takes it on purpose. Ordered on the numbers before
  # "+g<commit>", which the format check above has already made plain.
  if [ "$current_version" != "none" ] && [ "$force" = false ]; then
    local current_number="${current_version%%+*}" latest_number="${latest_version%%+*}" newest
    [ "$current_number" != "$latest_number" ] ||
      die "stable-target.json names a different build of $current_number: $current_version -> $latest_version; not pinning it (use --force to)"
    newest="$(printf '%s\n' "$current_number" "$latest_number" | sort -V | tail -n1)"
    [ "$newest" = "$latest_number" ] ||
      die "stable-target.json went back from $current_version to $latest_version; not pinning a rollback (use --force to)"
  fi

  if [ "$check_only" = true ]; then
    log "update available: $current_version -> $latest_version"
    exit 1
  fi

  # There is no published hash to read, so the only way to learn one is to
  # download the file. Into the store, where `nix build` will find it again.
  log "downloading $url"
  local prefetch deb hash
  prefetch="$(nix store prefetch-file --json "$url")"
  deb="$(jq -er .storePath <<<"$prefetch")"
  hash="$(jq -er .hash <<<"$prefetch")"

  local package version size
  package="$(dpkg-deb --field "$deb" Package)"
  version="$(dpkg-deb --field "$deb" Version)"
  size="$(stat --format %s "$deb")"

  [ "$package" = "$PACKAGE" ] ||
    die "the .deb is package '$package', expected '$PACKAGE'"
  [ "$version" = "$latest_version" ] ||
    die "the .deb at $url is version $version, expected $latest_version"

  local depends
  depends="$(dpkg-deb --field "$deb" Depends |
    tr ',' '\n' |
    sed -E 's/\(.*\)//; s/^ +//; s/ +$//; /^$/d' |
    sort -u |
    paste -sd ' ')"
  [ "$depends" = "$EXPECTED_DEPENDS" ] ||
    die "the .deb's Depends changed: expected '$EXPECTED_DEPENDS', now '$depends'"

  # The control archive has only control and md5sums today. A maintainer
  # script would be setup the .deb expects that this package does not do.
  local scripts
  scripts="$(dpkg-deb --ctrl-tarfile "$deb" | tar --list |
    sed 's|^\./||; /^$/d' | grep -vxE 'control|md5sums' || true)"
  [ -z "$scripts" ] ||
    die "the .deb now has maintainer scripts this package does not run: $scripts"

  local contents path
  contents="$(dpkg-deb --contents "$deb" | awk '{print $6}' | sed 's|^\./||')"
  for path in "${REQUIRED_FILES[@]}"; do
    grep -qxF "$path" <<<"$contents" ||
      die "the .deb no longer contains $path"
  done

  log "$ARCH: $version, $size bytes, $hash"

  jq -n \
    --arg version "$latest_version" \
    --arg system "$SYSTEM" \
    --arg debianArch "$ARCH" \
    --arg url "$url" \
    --arg hash "$hash" \
    --argjson size "$size" \
    '{version: $version, sources: {($system): {debianArch: $debianArch, url: $url, hash: $hash, size: $size}}}' \
    >"$SOURCES_JSON"
  log "wrote $SOURCES_JSON at $latest_version"
}

main "$@"
