self:
{
  config,
  options,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.epic-games-launcher;

  # Weaker than mkDefault, so that anything else on the host with an opinion
  # on GNOME Keyring, from a desktop module to the host's own config, wins.
  weak = lib.mkOverride 1100;
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
        `epic-games-launcher-unwrapped` is the launcher alone, which starts
        and shows the store but cannot start a game.
      '';
    };

    gnomeKeyring.enable = lib.mkOption {
      type = lib.types.bool;
      default = !config.services.desktopManager.plasma6.enable;
      defaultText = lib.literalExpression "!config.services.desktopManager.plasma6.enable";
      description = ''
        Whether to turn on GNOME Keyring as the Secret Service provider the
        launcher keeps its Epic refresh token in. Without one it keeps the
        token in a plaintext auth.json instead.

        Plasma 6's KWallet already answers as the Secret Service, so this is
        off there by default. Turn it off too if another provider, such as
        KeePassXC, does the job.

        When this module is the only thing turning GNOME Keyring on, it keeps
        the GCR SSH agent that comes with it off, so the host's SSH agent,
        and `programs.ssh.startAgent`, are left as they were.
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

    # The launcher keeps its Epic refresh token in a Secret Service keyring,
    # which it talks to over D-Bus, and falls back to a plaintext auth.json
    # when none answers. Any provider will do; this is the usual one.
    services.gnome.gnome-keyring.enable = lib.mkIf cfg.gnomeKeyring.enable (weak true);

    # Turning GNOME Keyring on also turns on, by default, its GCR SSH agent,
    # which takes over SSH_AUTH_SOCK and fails evaluation outright next to
    # programs.ssh.startAgent. A launcher has no business changing the SSH
    # agent, so when the definition above is the only one there is, the agent
    # stays off. When anything else defines GNOME Keyring, a desktop module
    # or the host itself, the agent is left to its default and to them.
    services.gnome.gcr-ssh-agent.enable = lib.mkIf (
      cfg.gnomeKeyring.enable && options.services.gnome.gnome-keyring.enable.highestPrio == 1100
    ) (weak false);
  };
}
