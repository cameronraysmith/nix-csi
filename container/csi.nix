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
        "csi-gc"
        "nix-daemon"
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
    services.csi-gc = {
      type = "scripted";
      command =
        pkgs.writeScriptBin "csi-gc" # bash
          ''
            #! ${pkgs.runtimeShell}
            # Fix gcroots for /nix/var/result
            nix build --out-link /nix/var/result /nix/var/result
            # Collect old shit
            ${lib.getExe pkgs.nix-timegc} 3600
          '';
      options = [ "shares-console" ];
      depends-on = [
        "nix-daemon"
        "shared-setup"
      ];
    };
  };
}
