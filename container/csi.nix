{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = {
    # Umbrella service for CSI
    services.csi = {
      type = "internal";
      depends-on = [
        "csi-daemon"
        "openssh"
      ];
    };
    services.csi-daemon = {
      command = "${lib.getExe pkgs.nix-csi} --loglevel DEBUG";
      options = [ "shares-console" ];
      depends-on = [
        "csi-setup"
        "nix-daemon"
        "gc"
      ];
    };
    services.csi-setup = {
      type = "scripted";
      options = [ "shares-console" ];
      depends-on = [ "shared-setup" ];
      command =
        pkgs.writeScriptBin "csi-setup" # bash
          ''
            #! ${pkgs.runtimeShell}
          '';
    };
  };
}
