#!/usr/bin/env bash
#
# Start the packaged launcher on a virtual display and wait until it has
# come all the way up, then stop it.
#
# The launcher has no mode that does anything without a display: --version
# and --help are not flags it knows, and with neither DISPLAY nor
# WAYLAND_DISPLAY set it logs "no GTK-capable display server reachable" and
# exits 1. So this runs it the way a user would, under Xvfb and a private
# D-Bus session, with a throwaway HOME so nothing touches a real profile,
# and reads its log, which it writes to stdout as well as to disk.
#
# Passing means these lines were logged, by a launcher still running:
#
#   category=EosClient.Initialized   the EOS SDK loaded and started
#   disabled=true category=SelfUpdate.DisabledRead
#                                    the wrapper's EGL_DISABLE_SELF_UPDATE
#                                    reached the updater
#   category=Startup.Completed       the web front end loaded in WebKit and
#                                    revealed the window
#
# That covers the patched interpreter, every RUNPATH and the dlopen()ed
# libraries the startup path touches. A loader error fails it at once,
# however far startup got. There is no clock in here: it waits for the
# lines or for the launcher to exit, and the CI job's own time limit is
# what stops a launcher that hangs.
#
# Usage: scripts/smoke-test.sh <path to bin/epic-games-launcher>
#
set -euo pipefail

log() { printf '\033[0;32m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: $0 <path to bin/epic-games-launcher>"
launcher="$(realpath --no-symlinks "$1")"
[ -x "$launcher" ] || die "$launcher is not executable"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT

for tool in xvfb-run dbus-run-session setsid jq; do
  command -v "$tool" >/dev/null 2>&1 || die "missing $tool (try: nix develop)"
done

workdir="$(mktemp -d)"
pgid=""
cleanup() {
  # The launcher, Xvfb, the D-Bus daemon and bubblewrap's children are one
  # process group, started by setsid below.
  if [ -n "$pgid" ]; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
    wait "$pgid" 2>/dev/null || true
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT

home="$workdir/home"
output="$workdir/launcher.log"
mkdir -p "$home"
# tail below opens the log before the launcher's redirect may have created
# it, and without --retry would give up on a missing file. The redirect
# truncates this same file, and tail follows it from the first line.
: >"$output"

# A desktop session's WAYLAND_DISPLAY would put the window on the real
# screen instead of Xvfb's, and its D-Bus and keyring would hand the
# launcher a real account's secrets. Neither belongs in a smoke test.
log "starting $launcher under Xvfb"
setsid env \
  -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
  HOME="$home" \
  XDG_CONFIG_HOME="$home/.config" \
  XDG_DATA_HOME="$home/.local/share" \
  XDG_CACHE_HOME="$home/.cache" \
  XDG_STATE_HOME="$home/.local/state" \
  GDK_BACKEND=x11 \
  xvfb-run --auto-servernum --server-args="-screen 0 1600x900x24" \
  dbus-run-session -- "$launcher" >"$output" 2>&1 &
pgid=$!

# tail stops when the launcher's group leader exits, and awk then reports
# whichever lines never came.
set +e
tail --lines=+1 --follow --pid="$pgid" "$output" 2>/dev/null | awk '
  /error while loading shared libraries|cannot open shared object file|symbol lookup error/ {
    print "loader error: " $0 > "/dev/stderr"; failed = 1; exit
  }
  /category=EosClient\.Initialized/                     { eos = 1 }
  /disabled=true category=SelfUpdate\.DisabledRead/     { updater = 1 }
  /category=Startup\.Completed/                         { started = 1 }
  eos && updater && started                             { exit }
  END {
    if (failed) exit 1
    if (!eos)     print "never logged EosClient.Initialized" > "/dev/stderr"
    if (!updater) print "never logged SelfUpdate.DisabledRead with disabled=true" > "/dev/stderr"
    if (!started) print "never logged Startup.Completed" > "/dev/stderr"
    exit !(eos && updater && started)
  }'
status=("${PIPESTATUS[@]}")
set -e

if [ "${status[1]}" -ne 0 ]; then
  echo "---- launcher output ----" >&2
  cat "$output" >&2
  die "the launcher did not start up"
fi

# The launcher reports its own version as it starts, which has to be the
# one sources.json pins.
version="$(grep -oE 'Sentry initialized release=[^ ]+' "$output" | head -n1 | cut -d= -f2)"
expected="$(jq -r .version "$ROOT/sources.json")"
[ "$version" = "$expected" ] ||
  die "the launcher reports version '$version', sources.json pins $expected"

log "launcher $version started: EOS SDK up, self-update off, window revealed"
