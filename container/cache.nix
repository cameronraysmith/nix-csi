{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = {
    # Umbrella service for CSI
    services.cache = {
      type = "internal";
      depends-on = [
        "cache-daemon"
        "openssh"
      ];
    };
    services.cache-daemon = {
      command = "${lib.getExe pkgs.nix-cache} --loglevel DEBUG";
      options = [ "shares-console" ];
      depends-on = [ "cache-setup" ];
      depends-ms = [ "nix-daemon" ];
    };
    services.cache-setup = {
      type = "scripted";
      options = [ "shares-console" ];
      depends-on = [ "shared-setup" ];
      command =
        pkgs.writeScriptBin "cache-setup" # bash
          ''
            #! ${pkgs.runtimeShell}
            rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=root:root /etc/nix-mount/ /etc/nix/
          '';
    };
  };
}
