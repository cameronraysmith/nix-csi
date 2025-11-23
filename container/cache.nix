{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = {
    # Umbrella service for cache
    services.cache = {
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
        "cache-daemon"
        "cache-logger"
        "cache-gc"
        "openssh"
      ];
    };
    services.cache-daemon = {
      command = "${lib.getExe pkgs.nix-cache} --loglevel DEBUG";
      log-type = "file";
      logfile = "/var/log/cache-daemon.log";
      depends-on = [ "shared-setup" ];
      depends-ms = [ "nix-daemon" ];
    };
    services.cache-logger = {
      command = "${lib.getExe' pkgs.coreutils "tail"} --follow /var/log/cache-daemon.log /var/log/dinit.log";
      options = [ "shares-console" ];
      depends-on = [ "cache-daemon" ];
    };
    # Make OpenSSH depend on cache-daemon so it can create the secret that'll
    # be mounted into /etc/ssh-mount when it's crashed once.
    # services.openssh.waits-for = [ "cache-daemon" ];
    services.cache-gc = {
      type = "scripted";
      command =
        pkgs.writeScriptBin "cache-gc" # bash
          ''
            #! ${pkgs.runtimeShell}
            # Fix gcroots for /nix/var/result
            nix build --out-link /nix/var/result /nix/var/result
            # Collect old shit
            ${lib.getExe pkgs.nix-timegc} 86400
          '';
      log-type = "file";
      logfile = "/var/log/cache-gc.log";
      depends-on = [
        "nix-daemon"
        "shared-setup"
      ];
    };
  };
}
