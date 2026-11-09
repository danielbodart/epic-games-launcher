{
  description = "Epic Games Launcher for Linux (Preview), pinned to versioned builds from Epic's CDN";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  # Offered, not imposed. Nix applies these only for a trusted user, and
  # otherwise says it is ignoring them. See the README for setting the
  # substituter in a NixOS configuration instead, which is what most people
  # actually want.
  nixConfig = {
    extra-substituters = [ "https://danielbodart.cachix.org" ];
    extra-trusted-public-keys = [
      "danielbodart.cachix.org-1:751qv4GxLFJCThWMEw1WL6kUqY0DpF6oqPqsLKnnEwU="
    ];
  };

  outputs =
    { self, nixpkgs }:
    let
      # Epic publishes the Linux launcher for x86_64 only.
      systems = [ "x86_64-linux" ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      # The upstream binary is proprietary, so the flake enables unfree for its
      # own outputs. Consumers who take the overlay instead get their own
      # nixpkgs config, and will need allowUnfree set there.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      packagesFor = pkgs: rec {
        epic-games-launcher-unwrapped = pkgs.callPackage ./package.nix { };
        epic-games-launcher = pkgs.callPackage ./nix/fhs.nix { inherit epic-games-launcher-unwrapped; };
      };

      overlay = final: prev: packagesFor final;
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (
        system:
        let
          packages = packagesFor (pkgsFor system);
        in
        packages // { default = packages.epic-games-launcher; }
      );

      apps = forAllSystems (system: {
        default = self.apps.${system}.epic-games-launcher;
        epic-games-launcher = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${system}.epic-games-launcher;
          meta.description = "Launch the Epic Games Launcher";
        };
      });

      nixosModules.default = import ./nix/nixos-module.nix self;

      # `nix flake check` builds these. The package build is the real test:
      # autoPatchelfHook fails the build on any unresolved shared library, so
      # a green check means every library the launcher links is present.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          inherit (self.packages.${system}) epic-games-launcher epic-games-launcher-unwrapped;
          sources = nixpkgs.lib.importJSON ./sources.json;
        in
        {
          inherit epic-games-launcher epic-games-launcher-unwrapped;

          # The version in sources.json has to be the version inside the
          # binary, otherwise the flake is pinning a label rather than a
          # release. The launcher identifies itself to Epic's services as
          # EpicGamesLauncher/<version>, the same string as the .deb's
          # control file, which scripts/update.sh has already compared.
          version-matches-package = pkgs.runCommand "epic-games-launcher-version-matches-package" { } ''
            expected="EpicGamesLauncher/${epic-games-launcher-unwrapped.version}"
            if ! grep -qaF "$expected" ${epic-games-launcher-unwrapped}/lib/epic-games-launcher/EpicGamesLauncher; then
              echo "sources.json says ${epic-games-launcher-unwrapped.version}, but the binary does not contain $expected" >&2
              exit 1
            fi
            echo "$expected" >$out
          '';

          # sources.json is machine-written; this catches a hand edit that
          # left it disagreeing with itself. The URL has to be the versioned
          # one, never the moving "latest" link, or the pin would rot the
          # moment Epic released.
          sources-are-consistent =
            let
              src = sources.sources.${system};
              expectedUrl = "https://content-download-egs.distro.on.epicgames.com/Builds/EGLv2/${
                builtins.replaceStrings [ "+" ] [ "%2B" ] sources.version
              }/Linux/EpicGamesLauncher-x86_64.deb";
            in
            assert nixpkgs.lib.assertMsg (
              src.url == expectedUrl
            ) "sources.json url ${src.url} is not the versioned URL for ${sources.version}";
            assert nixpkgs.lib.assertMsg (
              builtins.match "sha256-[A-Za-z0-9+/]{43}=" src.hash != null
            ) "sources.json hash ${src.hash} is not an SRI sha256";
            assert nixpkgs.lib.assertMsg (src.debianArch == "amd64") "sources.json debianArch is not amd64";
            pkgs.runCommand "epic-games-launcher-sources-are-consistent" { } ''
              size=$(stat --format %s ${epic-games-launcher-unwrapped.src})
              if [ "$size" != "${toString src.size}" ]; then
                echo "sources.json says ${toString src.size} bytes, the .deb is $size" >&2
                exit 1
              fi
              echo "${sources.version} ${src.hash} $size" >$out
            '';

          # autoPatchelfHook checks only what the ELF headers name. The tray
          # icon and most of what the EOS SDK uses are dlopen()ed by name, so
          # this resolves each of those names against the RUNPATH of the
          # object that opens it, which is the only place dlopen will look.
          dlopen-targets =
            pkgs.runCommand "epic-games-launcher-dlopen-targets" { nativeBuildInputs = [ pkgs.patchelf ]; }
              ''
                dir=${epic-games-launcher-unwrapped}/lib/epic-games-launcher
                resolve() {
                  local object="$1" name="$2" path
                  IFS=: read -ra paths <<<"$(patchelf --print-rpath "$object")"
                  for path in "''${paths[@]}"; do
                    [ -e "$path/$name" ] && { echo "$name: $path"; return 0; }
                  done
                  echo "$name is not on the RUNPATH of $object" >&2
                  return 1
                }
                {
                  resolve "$dir/EpicGamesLauncher" libayatana-appindicator3.so.1
                  for name in libasound.so.2 libpulse-simple.so.0 libudev.so.1 \
                    libGL.so.1 libEGL.so.1 libGLESv2.so.2 libvulkan.so.1 \
                    libwayland-client.so.0 libwayland-cursor.so.0 libwayland-egl.so.1 \
                    libX11.so.6 libXcursor.so.1 libXext.so.6 libXi.so.6 libXinerama.so.1 \
                    libXrandr.so.2 libXss.so.1 libXxf86vm.so.1 libxkbcommon.so.0; do
                    resolve "$dir/libEOSSDK-Linux-Shipping.so" "$name"
                  done
                } >$out
              '';

          # GE-Proton brings its own Wine, GStreamer and FFmpeg but not the
          # GLib, libvpx.so.6 and libtheora 1.1 they link, expecting the host
          # to have them in both its 64- and 32-bit library directories. This
          # looks in the FHS tree the games run in, at the ELF class too, so
          # dropping one from nix/fhs.nix, or nixpkgs moving a soname on,
          # fails here rather than silently in a game's cutscene.
          fhs-libraries = pkgs.runCommand "epic-games-launcher-fhs-libraries" { } ''
            root=${epic-games-launcher.fhsenv}
            for lib in libglib-2.0.so.0 libgobject-2.0.so.0 libgmodule-2.0.so.0 libgio-2.0.so.0 \
              libvpx.so.6 libtheoradec.so.1 libtheoraenc.so.1; do
              for entry in usr/lib64:2 usr/lib32:1; do
                dir="''${entry%:*}"
                [ -e "$root/$dir/$lib" ] || { echo "$dir/$lib is missing from the FHS environment" >&2; exit 1; }
                # EI_CLASS, the fifth byte of the ELF header: 1 is 32-bit, 2 is 64-bit.
                class="$(od -An -tu1 -j4 -N1 "$root/$dir/$lib" | tr -d ' ')"
                [ "$class" = "''${entry#*:}" ] || { echo "$dir/$lib is the wrong ELF class ($class)" >&2; exit 1; }
                echo "$dir/$lib" >>$out
              done
            done
          '';

          # The launcher's own updater cannot write to the store and must stay
          # off. If the wrapper loses the switch, this fails.
          self-update-disabled = pkgs.runCommand "epic-games-launcher-self-update-disabled" { } ''
            grep -q 'EGL_DISABLE_SELF_UPDATE.*1' ${epic-games-launcher-unwrapped}/bin/epic-games-launcher ||
              { echo "the wrapper does not set EGL_DISABLE_SELF_UPDATE" >&2; exit 1; }
            grep -qaF EGL_DISABLE_SELF_UPDATE ${epic-games-launcher-unwrapped}/lib/epic-games-launcher/EpicGamesLauncher ||
              { echo "the launcher no longer reads EGL_DISABLE_SELF_UPDATE" >&2; exit 1; }
            touch $out
          '';

          # Evaluation only, not a build: enough to catch an option this module
          # sets that nixpkgs has since renamed or removed, without standing up
          # a whole system. It evaluates the module on the hosts it has to
          # leave alone as well as a bare one: one running OpenSSH's agent,
          # which GNOME Keyring's GCR agent cannot sit beside, one on Plasma 6,
          # whose KWallet is already the Secret Service, and one on GNOME,
          # whose own keyring and SSH agent the module must not touch.
          #
          # unsafeDiscardStringContext is what keeps it that way. Interpolating
          # a drvPath with its context intact makes the toplevel an input of
          # this derivation, and `nix flake check` would go and build a NixOS
          # system.
          nixos-module =
            let
              host =
                name: extra: expected:
                let
                  config =
                    (nixpkgs.lib.nixosSystem {
                      modules = [
                        self.nixosModules.default
                        {
                          nixpkgs.hostPlatform = system;
                          boot.loader.grub.devices = [ "/dev/null" ];
                          fileSystems."/" = {
                            device = "/dev/null";
                            fsType = "ext4";
                          };
                          system.stateVersion = "26.05";
                          programs.epic-games-launcher.enable = true;
                        }
                        extra
                      ];
                    }).config;
                  actual = {
                    gnomeKeyring = config.services.gnome.gnome-keyring.enable;
                    gcrSshAgent = config.services.gnome.gcr-ssh-agent.enable;
                  };
                in
                assert nixpkgs.lib.assertMsg (actual == expected)
                  "on the ${name} host the module gives ${builtins.toJSON actual}, expected ${builtins.toJSON expected}";
                "${name} ${builtins.unsafeDiscardStringContext config.system.build.toplevel.drvPath}";
            in
            pkgs.runCommand "epic-games-launcher-nixos-module" { } ''
              cat >$out <<'EOF'
              ${host "bare" { } {
                gnomeKeyring = true;
                gcrSshAgent = false;
              }}
              ${host "ssh-agent" { programs.ssh.startAgent = true; } {
                gnomeKeyring = true;
                gcrSshAgent = false;
              }}
              ${host "plasma6" { services.desktopManager.plasma6.enable = true; } {
                gnomeKeyring = false;
                gcrSshAgent = false;
              }}
              ${host "gnome" { services.desktopManager.gnome.enable = true; } {
                gnomeKeyring = true;
                gcrSshAgent = true;
              }}
              EOF
            '';

          shellcheck =
            pkgs.runCommand "epic-games-launcher-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; }
              ''
                shellcheck ${./scripts/update.sh} ${./scripts/smoke-test.sh} ${./scripts/check-pin.sh}
                touch $out
              '';

          formatting =
            pkgs.runCommand "epic-games-launcher-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; }
              ''
                nixfmt --check ${./flake.nix} ${./package.nix} ${./nix}/*.nix
                touch $out
              '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              curl
              dbus
              dpkg
              jq
              nixfmt
              shellcheck
              xvfb-run
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
