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
      type = "scripted";
      options = [ "starts-rwfs" ];
      command =
        pkgs.writeScriptBin "csi" # bash
          ''
            #! ${pkgs.runtimeShell}
            mkdir --parents /run
            mkdir --parents /var/log
          '';
      depends-on = [
        "csi-daemon"
        "csi-logger"
        "openssh"
      ];
    };
    services.csi-daemon = {
      command = "${lib.getExe pkgs.nix-csi} --loglevel DEBUG";
      log-type = "file";
      logfile = "/var/log/csi-daemon.log";
      depends-on = [
        "shared-setup"
        "csi-gc"
        "nix-daemon"
      ];
    };
    services.csi-logger = {
      command = "${lib.getExe' pkgs.coreutils "tail"} --follow /var/log/csi-daemon.log /var/log/dinit.log";
      options = [ "shares-console" ];
      depends-on = [ "csi-daemon" ];
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
      log-type = "file";
      logfile = "/var/log/csi-gc.log";
      depends-on = [
        "nix-daemon"
        "shared-setup"
      ];
    };
  };
}
