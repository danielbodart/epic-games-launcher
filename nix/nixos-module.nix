self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.epic-games-launcher;
in
{
  options.programs.epic-games-launcher = {
    enable = lib.mkEnableOption "the Epic Games Launcher";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.epic-games-launcher;
      defaultText = lib.literalMD "`epic-games-launcher` from this flake, in its FHS environment";
      description = ''
        The epic-games-launcher package to install. The default is the
        launcher in the FHS environment its games need;
        `epic-games-launcher-unwrapped` is the launcher alone, which signs in
        and browses the store but cannot start a game.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Games run through GE-Proton, and Wine's 32-bit side needs 32-bit GL and
    # Vulkan drivers just as it does under Steam. mkDefault, so a host that
    # has its own reason to differ can say so without a conflict.
    hardware.graphics = {
      enable = lib.mkDefault true;
      enable32Bit = lib.mkDefault true;
    };

    # The launcher keeps its Epic session in a Secret Service keyring, which
    # it talks to over D-Bus. Any provider will do; this is the usual one.
    services.gnome.gnome-keyring.enable = lib.mkDefault true;
  };
}
