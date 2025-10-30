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
        "cache-gc"
        "openssh"
      ];
    };
    services.cache-daemon = {
      command = "${lib.getExe pkgs.nix-cache} --loglevel DEBUG";
      options = [ "shares-console" ];
      depends-on = [ "cache-setup" ];
      depends-ms = [ "nix-daemon" ];
    };
    # Make OpenSSH depend on cache-daemon so it can create the secret that'll
    # be mounted into /etc/ssh-mount when it's crashed once.
    services.openssh.waits-for = [ "cache-daemon" ];
    services.cache-setup = {
      type = "scripted";
      options = [ "shares-console" ];
      depends-on = [ "shared-setup" ];
      command =
        pkgs.writeScriptBin "cache-setup" # bash
          ''
            #! ${pkgs.runtimeShell}
            rsync --archive --mkpath --copy-links --chmod=D755,F644 --chown=root:root /etc/nix-mount/ /etc/nix/
          '';
    };
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
      options = [ "shares-console" ];
      depends-on = [
        "nix-daemon"
        "shared-setup"
      ];
    };
  };
}
