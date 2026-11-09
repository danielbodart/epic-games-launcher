{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  dpkg,
  makeShellWrapper,
  wrapGAppsHook3,
  alsa-lib,
  cairo,
  dbus,
  gdk-pixbuf,
  glib,
  glib-networking,
  gst_all_1,
  gtk3,
  libayatana-appindicator,
  libglvnd,
  libpulseaudio,
  libsoup_3,
  libx11,
  libxcursor,
  libxext,
  libxi,
  libxinerama,
  libxkbcommon,
  libxrandr,
  libxscrnsaver,
  libxxf86vm,
  systemdLibs,
  vulkan-loader,
  wayland,
  webkitgtk_4_1,
  sources ? lib.importJSON ./sources.json,
}:

let
  source =
    sources.sources.${stdenv.hostPlatform.system}
      or (throw "epic-games-launcher has no Linux package for ${stdenv.hostPlatform.system}; Epic publishes x86_64 only");

  # Where the binary and the EOS SDK live together. The .deb puts the binary
  # in usr/bin and the SDK in usr/lib/epic-games-launcher, and the binary's
  # RUNPATH covers both ($ORIGIN and $ORIGIN/../lib/epic-games-launcher).
  # Here the binary moves in beside the SDK, so that $out/bin is free for
  # the wrapper and Tauri's resource directory, which falls back to the
  # executable's own directory, still holds resources/.
  appDir = "lib/epic-games-launcher";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "epic-games-launcher-unwrapped";
  version = sources.version;

  src = fetchurl {
    inherit (source) url hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
    makeShellWrapper
    wrapGAppsHook3
  ];

  # What the binary links, read off its DT_NEEDED entries: WebKitGTK 4.1 and
  # its JavaScriptCore, libsoup 3, GTK 3, GDK, cairo, GLib, X11 and D-Bus.
  # glib-networking is not linked but is how libsoup speaks TLS, and
  # wrapGAppsHook3 puts it on GIO_EXTRA_MODULES. The GStreamer plugins are
  # what WebKit plays the store's trailers with; wrapGAppsHook3 puts them on
  # the plugin path. There is no libsecret: the login keyring is reached
  # over D-Bus by a pure Rust Secret Service client compiled into the binary.
  buildInputs = [
    cairo
    dbus
    gdk-pixbuf
    glib
    glib-networking
    gtk3
    libsoup_3
    libx11
    webkitgtk_4_1
  ]
  ++ (with gst_all_1; [
    gst-plugins-base
    gst-plugins-good
    gst-plugins-bad
    gst-libav
  ]);

  # Loaded with dlopen at runtime rather than linked, so autoPatchelfHook
  # cannot see the need for them from the ELF headers. The tray icon is
  # libayatana-appindicator3, which is also why the .deb depends on it. The
  # rest is the EOS SDK reaching for audio, GL, Vulkan, Wayland, the X11
  # extensions and libudev, all found by running `strings` over
  # libEOSSDK-Linux-Shipping.so.
  #
  # appendRunpaths rather than runtimeDependencies, which autoPatchelfHook
  # adds to executables only. A dlopen() made from inside a library searches
  # that library's own RUNPATH, never the executable's, so the EOS SDK has
  # to carry these paths itself.
  appendRunpaths = map (pkg: "${lib.getLib pkg}/lib") [
    alsa-lib
    libayatana-appindicator
    libglvnd
    libpulseaudio
    libx11
    libxcursor
    libxext
    libxi
    libxinerama
    libxkbcommon
    libxrandr
    libxscrnsaver
    libxxf86vm
    # libudev only; `lib.getLib systemd` is the whole of systemd, since it
    # has no separate lib output.
    systemdLibs
    vulkan-loader
    wayland
  ];

  # The .deb has no maintainer scripts, so there is nothing of Epic's being
  # skipped by unpacking it rather than installing it.
  unpackPhase = ''
    runHook preUnpack

    dpkg-deb --fsys-tarfile "$src" |
      tar --extract --no-same-permissions --no-same-owner --wildcards 'usr/*'

    runHook postUnpack
  '';

  # A Rust binary with its web front end embedded in it. Stripping buys
  # little and loses the symbols Epic's crash reporting would want.
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/${appDir}" "$out/bin" "$out/share"
    cp -r usr/${appDir}/. "$out/${appDir}/"
    install -Dm755 usr/bin/EpicGamesLauncher "$out/${appDir}/EpicGamesLauncher"
    cp -r usr/share/icons "$out/share/"

    # The bare `EpicGamesLauncher` in Exec= resolves against a Debian $PATH.
    # Point it at the wrapper instead, so a launcher finds the app without
    # the profile having to be on PATH. The entry also registers the
    # com.epicgames.launcher:// scheme the website's "open in launcher" and
    # the login flow come back through.
    install -Dm644 usr/share/applications/epic-games-launcher.desktop \
      "$out/share/applications/epic-games-launcher.desktop"
    substituteInPlace "$out/share/applications/epic-games-launcher.desktop" \
      --replace-fail "Exec=EpicGamesLauncher" "Exec=$out/bin/epic-games-launcher"

    runHook postInstall
  '';

  # EGL_DISABLE_SELF_UPDATE turns off the launcher's own updater, a switch
  # it honours itself ("Skipping apply (dev build or EGL_DISABLE_SELF_UPDATE
  # set)"). Left on, it downloads each new release and tries to install it
  # over a read-only store path, and fails. Updates come through this flake.
  # --set, not --set-default: there is no value of it that works here.
  #
  # No LD_LIBRARY_PATH: the dlopen()ed libraries are in the RUNPATH of the
  # binary and of the EOS SDK, which is where dlopen looks first, and an
  # LD_LIBRARY_PATH would leak into every game and Proton process the
  # launcher starts.
  postFixup = ''
    makeShellWrapper "$out/${appDir}/EpicGamesLauncher" "$out/bin/epic-games-launcher" \
      "''${gappsWrapperArgs[@]}" \
      --set EGL_DISABLE_SELF_UPDATE 1
    ln -s epic-games-launcher "$out/bin/EpicGamesLauncher"
  '';

  # wrapGAppsHook3 would otherwise wrap the binary in place, under lib/,
  # where nothing on PATH would find it. The wrapper above takes its
  # arguments instead.
  dontWrapGApps = true;

  passthru = {
    inherit (source) url;
    updateScript = ./scripts/update.sh;
  };

  meta = {
    description = "Epic Games Launcher for Linux (Preview), packaged from Epic's .deb";
    longDescription = ''
      The official Epic Games Launcher for Linux, currently in preview: a
      Tauri application on WebKitGTK that runs Windows games through a
      GE-Proton it downloads itself.

      This is the launcher on its own, patched for Nix. The games it starts
      need an FHS environment; the epic-games-launcher package wraps this
      one in it.
    '';
    homepage = "https://store.epicgames.com/download";
    license = {
      fullName = "Epic Games Launcher End User License Agreement";
      url = "https://www.epicgames.com/site/eula";
      free = false;
      redistributable = false;
    };
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "epic-games-launcher";
  };
})
