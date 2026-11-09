# Older libraries that GE-Proton links by soname and does not bundle, built
# for whichever nixpkgs buildFHSEnv hands this: the 64-bit one, and
# pkgsi686Linux for the 32-bit tree.
#
# GE-Proton's FFmpeg was built against Ubuntu 20.04-era libraries, and
# nixpkgs has since moved every one of these to a new soname, so its own
# packages do not satisfy them:
#
#   libvpx.so.6        libvpx 1.8 to 1.10. libavcodec.so.58 needs it, and
#                      with it Wine's FFmpeg media backend (winedmo.so) and
#                      GStreamer's gst-libav, which decode games' H.264 and
#                      other video. nixpkgs has 1.16, libvpx.so.9.
#   libtheoradec.so.1  libtheora 1.1, for GStreamer's Theora plugin and so
#   libtheoraenc.so.1  Ogg Theora cutscenes. nixpkgs has 1.2, .so.2.
#
# Both are built with only the libraries: no examples or command-line tools,
# which also keeps them free of anything else old.
pkgs:

let
  libvpx =
    (pkgs.libvpx.override {
      examplesSupport = false;
      webmIOSupport = false;
      libyuvSupport = false;
    }).overrideAttrs
      (old: {
        version = "1.10.0";
        src = pkgs.fetchFromGitHub {
          owner = "webmproject";
          repo = "libvpx";
          rev = "v1.10.0";
          hash = "sha256-EZP33U10fchyqy7Jr26vHgUUfWR6xtG3fcMWUII0m9w=";
        };
        # 1.10's configure links with $LD and passes it the compiler's -m64
        # or -m32, which only the compiler driver understands; later releases
        # link through the compiler themselves.
        preConfigure = (old.preConfigure or "") + ''
          export LD="$CC"
        '';
        outputs = [
          "out"
          "dev"
        ];
        postInstall = "";
        passthru = { };
      });

  libtheora = pkgs.libtheora.overrideAttrs (old: {
    version = "1.1.1";
    # The release tarball rather than the git tag: its configure script is
    # already generated, and 1.1.1's configure.ac no longer goes through a
    # current autoconf.
    src = pkgs.fetchurl {
      url = "https://downloads.xiph.org/releases/theora/libtheora-1.1.1.tar.xz";
      hash = "sha256-822kCZR6orPcxq8KjC4xRLwZ2y7VR9ZOkXHFnGZWHGE=";
    };
    nativeBuildInputs = [ pkgs.pkg-config ];
    outputs = [
      "out"
      "dev"
    ];
    outputDoc = "out";
    passthru = { };
  });
in
[
  libvpx
  libtheora
]
