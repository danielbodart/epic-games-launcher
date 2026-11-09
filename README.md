# epic-games-launcher

A Nix flake for the **official** Epic Games Launcher for Linux.

Epic ships a native Linux launcher now, in preview: a Tauri application on
WebKitGTK, distributed as a single `.deb` for x86\_64, that installs and runs
Windows games through a GE-Proton it downloads itself. This flake repackages
that `.deb` for NixOS and Nix on other distributions, wraps it in the FHS
environment its games need, and keeps the pin current automatically.

```nix
{
  inputs.epic-games-launcher.url = "github:danielbodart/epic-games-launcher";
}
```

## Why another one

There are a handful of Epic Games Launcher flakes already, and this one
borrows from them openly: the split into a patched launcher and an FHS
wrapper is
[Hy4ri/epic-games-launcher-flake](https://github.com/Hy4ri/epic-games-launcher-flake)'s,
and the updater's refusal to land a `.deb` whose dependencies or layout have
changed is
[kjetteren/epic-games-launcher-flake](https://github.com/kjetteren/epic-games-launcher-flake)'s.
What this one adds is the same treatment as its sibling flakes,
[chatgpt-desktop](https://github.com/danielbodart/chatgpt-desktop) and
[claude-desktop](https://github.com/danielbodart/claude-desktop):

- **Packages what Epic ships.** The upstream `.deb`, patched only where
  running out of the Nix store needs it.
- **Pins versioned URLs, never the moving one.** Epic's download link always
  serves the newest build. `sources.json` records the build's own URL, so
  every pin stays buildable after Epic moves on.
- **Cross-checks every update** against two independent sources before
  writing anything. See [Provenance](#provenance).
- **Updates itself hourly**, and only lands a version that has been built
  and actually started first.
- **Tags every release**, so
  `github:danielbodart/epic-games-launcher/v0.113.0+g2164614` pins one
  exactly.
- **Keeps the launcher's own updater off**, which cannot work from a
  read-only store and would otherwise fail on every release. See
  [Things to know](#things-to-know).

## Install

### NixOS

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    epic-games-launcher.url = "github:danielbodart/epic-games-launcher";
  };

  outputs = { nixpkgs, epic-games-launcher, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      modules = [
        epic-games-launcher.nixosModules.default
        { programs.epic-games-launcher.enable = true; }
      ];
    };
  };
}
```

Besides installing the package, the module turns on 32-bit graphics drivers
(`hardware.graphics.enable32Bit`), which Proton needs as it does under Steam,
and GNOME Keyring as the Secret Service provider the launcher keeps its
sign-in in. Both are `mkDefault`, so a host that already has its own
arrangement keeps it.

### Home Manager, or any other profile

```nix
home.packages = [ inputs.epic-games-launcher.packages.${pkgs.system}.default ];
```

Outside the module, make sure 32-bit graphics drivers and a Secret Service
provider (GNOME Keyring, KeePassXC, KWallet) are there yourself.

The package is unfree, so `nixpkgs.config.allowUnfree` has to permit it.
This flake's own outputs set that for themselves; taking the overlay instead
uses your nixpkgs configuration.

### Try it without installing

```bash
nix run github:danielbodart/epic-games-launcher
```

## Provenance

This is weaker than the sibling flakes, and it is worth being plain about
why. OpenAI and Anthropic publish apt repositories with PGP-signed indexes,
so those flakes pin a hash the vendor signed, and never download the
package to learn it. Epic publishes no repository, no checksum and no
signature: the `.deb` sits on its CDN and the only thing vouching for it is
the TLS connection it comes over. There is nothing to verify a download
against except the download.

So the hash in `sources.json` is trust on first use: the hash of the bytes
Epic's CDN served when `scripts/update.sh` ran. What the script does is make
sure those bytes are the release Epic means, and the release this package
was written for, before it writes anything down:

| Step | Checked by `scripts/update.sh` |
| --- | --- |
| `Builds/EGLv2/stable-target.json` | The version the installed launcher itself polls for |
| The download link on Epic's site | Must redirect to that same version, or the update stops |
| `Builds/EGLv2/<version>/Linux/EpicGamesLauncher-x86_64.deb` | Downloaded over TLS; its control file must name package `epic-games-launcher` at that version |
| The `.deb`'s `Depends` and file list | Must be the ones `package.nix` provides for; no maintainer scripts may appear |
| The bytes Nix downloads later | The hash in `sources.json`, checked by `fetchurl` |

Once pinned, nothing can change underneath you: every later download of
that URL, by you or by CI, has to match the recorded hash. And continuous
integration downloads it again on every pull request, so a hand-edited
`sources.json`, or Epic replacing a published build in place, fails loudly
rather than slipping through.

## Channels

- **Nix**: take the flake as an input and enable `nixosModules.default`, or
  install `packages.x86_64-linux.default`. Built by nixpkgs (nixos-26.05)
  from Epic's `.deb` for x86\_64; CI pushes the packages to
  `https://danielbodart.cachix.org` (see [Binary cache](#binary-cache)). No
  `inputs.nixpkgs.follows`: the launcher is patched against this flake's
  nixpkgs and consumers take it prebuilt from Cachix, so following yours
  would only rebuild it.
- Not shipped: Docker — a desktop app, not a service.
- Not shipped: Tarball + systemd — Epic already ships the `.deb` this
  repackages; there is nothing of ours to compile, so no mise toolchain
  either.

Updated hourly for a new upstream release (`upstream.yml`, which tags and
releases it) and weekly, Sunday 21:23 UTC, for the flake's inputs
(`update.yml`, the Weekly update). A release is cut only when Epic's version
changed; the weekly update never releases.

## How updates work

An hourly job asks Epic for its current release. When it finds a newer
version it regenerates `sources.json`, then builds the package, runs
`nix flake check`, and starts the launcher (see
[Development](#development)) on an `x86_64-linux` runner. Only if that
succeeds does the commit reach `trunk`, followed by a `v<version>` tag and a
GitHub release.

If the new `.deb` depends on something new, drops a file the package uses,
grows a maintainer script, or Epic's two answers about the current version
disagree, the job fails instead, and the pin stays where it was until
someone has looked.

This pushes to `trunk` rather than opening a pull request on purpose. A pull
request raised with the default token does not trigger workflows, so an
auto-merged one would land without ever having been built.

Once a week, Sunday 21:23 UTC, a separate workflow, the Weekly update, moves
`flake.lock` (nixpkgs, on nixos-26.05), built and run the same way before it
lands as `Weekly update: <inputs>`. That is not a release, so it gets no tag.

Nothing about this changes when you pin a tag. `nix flake update` is still
the only thing that moves your version.

## What is packaged

Two packages, as the prior flakes worked out:

- **`epic-games-launcher-unwrapped`**: the `.deb` contents with the binary
  moved in beside the EOS SDK under `lib/epic-games-launcher`, where its
  `$ORIGIN` RUNPATH and Tauri's resource lookup both expect to find things.
  - `autoPatchelfHook` over the launcher and `libEOSSDK-Linux-Shipping.so`,
    against nixpkgs' WebKitGTK 4.1, libsoup 3 and GTK 3.
  - The libraries the launcher and the EOS SDK `dlopen()` rather than link,
    found with `strings` (the tray's libayatana-appindicator3, and ALSA,
    PulseAudio, GL, Vulkan, Wayland, X11 extensions and libudev for the
    SDK), appended to the RUNPATH of each. `nix flake check` resolves every
    one of those names.
  - glib-networking for TLS and the GStreamer plugins the store's trailers
    play with, through `wrapGAppsHook3`.
  - The desktop entry pointed at the wrapper's store path. It registers the
    `com.epicgames.launcher://` scheme Epic's website and sign-in hand back
    through.
  - `EGL_DISABLE_SELF_UPDATE=1` set by the wrapper.
- **`epic-games-launcher`**, the default: that, run inside a `buildFHSEnv`
  with 64- and 32-bit copies of the libraries Wine and GE-Proton expect
  under `/usr/lib`, the way nixpkgs' Steam is. The launcher itself does not
  need it; the games it starts do.

The `.deb` has no maintainer scripts, so nothing of Epic's is skipped by
unpacking it rather than installing it.

## Things to know

- **It is a preview.** Epic calls the Linux launcher a preview, and it
  changes quickly. The updater stops at the first change to its
  dependencies or layout rather than ship something half-working, so a
  release can take a manual look before it lands here.
- **Games run through GE-Proton, downloaded at runtime.** On first use the
  launcher fetches a pinned GE-Proton (GE-Proton10-34 in 0.113.0, checked
  against a SHA-512 inside the binary; `EGL_PROTON_PIN` overrides it) into
  `~/.local/share/com.epicgames.eglv2/compat`. Every game, as far as this
  release shows, goes through it; there is no native Linux launch path yet.
  That GE-Proton is built for a generic Linux, which is why the default
  package is the FHS environment. The unwrapped launcher signs in and
  browses fine, but cannot start a game. Neither GE-Proton nor any game is
  pinned or tested here: CI has no Epic account to sign in with.
- **Fortnite is Epic's call.** Whether Fortnite can be installed on Linux is
  decided by Epic's servers (the launcher has a `fortnite_gate`), not by
  anything this package can change.
- **It needs a Secret Service keyring.** The launcher keeps its session in
  the Secret Service over D-Bus. Without one it logs that the keyring is
  locked and asks you to sign in every time it starts. The NixOS module
  enables GNOME Keyring; elsewhere, any provider will do.
- **Self-update is switched off.** The launcher has its own updater, which
  downloads each release in the background and installs it over itself. It
  cannot write to the store, so it would fail on every release. The wrapper
  sets `EGL_DISABLE_SELF_UPDATE=1`, a switch the launcher reads itself: it
  logs `get_self_update_disabled called disabled=true` and skips
  downloading and applying updates. New versions come through this flake
  instead. CI checks for that log line on every build.
- **x86\_64 only.** Epic publishes no other architecture.

## Development

```bash
nix develop                    # curl, dbus, dpkg, jq, nixfmt, shellcheck, xvfb-run
nix flake check                # builds both packages, checks the pin, the dlopen paths and the module
./scripts/update.sh            # regenerate sources.json
./scripts/update.sh --check    # exit non-zero if a newer version exists
./scripts/update.sh --force    # re-download and rewrite even when already current
nix build && ./scripts/smoke-test.sh result/bin/epic-games-launcher
```

The smoke test is the one CI runs. The launcher has no `--version`, or any
mode that runs without a display, so the script starts it under Xvfb with a
private D-Bus session and a throwaway `HOME`, and waits for three log lines:
the EOS SDK initialised, the self-update switch read as disabled, and
startup completed with the window revealed. A loader error, the launcher
exiting, or a version other than the pinned one fails it. It waits on the
launcher, not on a clock.

## Binary cache

CI pushes both packages to `https://danielbodart.cachix.org`, so you can
substitute the build instead of downloading an 85 MB `.deb`, patching it,
and assembling the FHS environment yourself.

The flake offers the cache through `nixConfig`, which Nix applies only if
you are a trusted user and otherwise reports as ignored. On NixOS the
reliable place to put it is your own configuration:

```nix
nix.settings = {
  substituters = [ "https://danielbodart.cachix.org" ];
  trusted-public-keys = [
    "danielbodart.cachix.org-1:751qv4GxLFJCThWMEw1WL6kUqY0DpF6oqPqsLKnnEwU="
  ];
};
```

## License

The packaging in this repository is MIT. The Epic Games Launcher itself is
proprietary and covered by
[Epic's End User License Agreement](https://www.epicgames.com/site/eula).
This repository redistributes no Epic binaries; it records where to fetch
them and what they should hash to.
