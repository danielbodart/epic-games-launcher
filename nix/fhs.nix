# The launcher inside an FHS environment, for the games it starts.
#
# The launcher itself needs none of this: package.nix patches it to run
# straight out of the store. But every game it starts today runs through a
# GE-Proton it downloads into ~/.local/share/com.epicgames.eglv2/compat,
# built for a generic Linux with /lib64/ld-linux-x86-64.so.2, the 32-bit
# /lib/ld-linux.so.2 and the libraries Wine expects under /usr/lib. That is
# what this provides, the same way nixpkgs' Steam does: a bubblewrap
# namespace with an FHS tree built out of store paths, 64- and 32-bit both.
#
# The shape follows Hy4ri/epic-games-launcher-flake, which got games running
# this way first. The library list is its, less the scanner, camera, Samba,
# LDAP, packet capture and OpenCL support Wine can use but games rarely do,
# and less its SDL rpath rewriting, which works around a GE-Proton library
# clash this package has not been able to reproduce without a game to run.
{
  lib,
  buildFHSEnv,
  epic-games-launcher-unwrapped,
}:

buildFHSEnv {
  pname = "epic-games-launcher";
  inherit (epic-games-launcher-unwrapped) version;

  # Wine and Proton need the 32-bit loader and libraries too.
  multiArch = true;

  # The launcher waits on the games it starts and talks to them over IPC,
  # and games and anti-cheat look at other processes, so the PID and IPC
  # namespaces stay shared with the host, as they do for Steam.
  unshareIpc = false;
  unsharePid = false;
  privateTmp = false;

  targetPkgs =
    pkgs: with pkgs; [
      epic-games-launcher-unwrapped

      # GE-Proton's `proton` is a Python script, and Wine prefix setup and
      # the launcher's own checks shell out to these.
      bash
      coreutils
      file
      findutils
      gawk
      gnugrep
      gnused
      gnutar
      gzip
      pciutils
      procps
      python3
      util-linux
      which
      xdg-utils
      xrandr
      xz
      zenity
      zstd

      # TLS roots for anything inside the environment that does its own HTTPS.
      cacert
    ];

  multiPkgs =
    pkgs:
    with pkgs;
    [
      # The C and C++ runtimes, and what Wine's DLLs load from the host.
      stdenv.cc.cc
      glibc
      alsa-lib
      alsa-plugins
      bzip2
      cups
      dbus
      expat
      fontconfig
      freetype
      fribidi
      gamemode
      giflib
      gnutls
      harfbuzz
      keyutils
      lcms2
      libcap
      libdrm
      libgbm
      libgcrypt
      libglvnd
      libgpg-error
      libjpeg_turbo
      libkrb5
      libogg
      libopus
      libpng
      libpulseaudio
      libsamplerate
      libsndfile
      libtheora
      libtiff
      libudev0-shim
      libunwind
      libusb1
      libva
      libvorbis
      libxkbcommon
      libxml2
      libxslt
      mpg123
      ncurses
      openal
      openssl
      p11-kit
      pipewire
      SDL2
      speex
      sqlite
      udev
      vulkan-loader
      wayland
      zlib

      # X11, which Wine still draws through by default.
      libice
      libsm
      libx11
      libxcb
      libxcomposite
      libxcursor
      libxdamage
      libxext
      libxfixes
      libxi
      libxinerama
      libxrandr
      libxrender
      libxscrnsaver
      libxt
      libxtst
      libxv
      libxxf86vm
    ]
    ++ (with gst_all_1; [
      gstreamer
      gst-plugins-base
      gst-plugins-good
    ]);

  runScript = lib.getExe epic-games-launcher-unwrapped;

  # The desktop entry and icons, with Exec= pointed at this wrapper rather
  # than at the unwrapped launcher inside it.
  extraInstallCommands = ''
    ln -s epic-games-launcher "$out/bin/EpicGamesLauncher"
    mkdir -p "$out/share/applications"
    ln -s ${epic-games-launcher-unwrapped}/share/icons "$out/share/icons"
    substitute ${epic-games-launcher-unwrapped}/share/applications/epic-games-launcher.desktop \
      "$out/share/applications/epic-games-launcher.desktop" \
      --replace-fail "${lib.getExe epic-games-launcher-unwrapped}" "$out/bin/epic-games-launcher"
  '';

  passthru.unwrapped = epic-games-launcher-unwrapped;

  meta = epic-games-launcher-unwrapped.meta // {
    description = "Epic Games Launcher for Linux (Preview), in an FHS environment for the games it runs through GE-Proton";
  };
}
