{
  pkgs ? import <nixpkgs> { },
  dinix ? import <dinix>,
}:
let
  lib = pkgs.lib;
  dinixEval = dinix {
    inherit pkgs;
    modules = [
      {
        config = {
          users = {
            enable = true;
            users.nix = {
              uid = 1000;
              gid = 1000;
              comment = "Nix binary cache user";
            };
            groups.nix.gid = 1000;
            users.sshd = {
              uid = 993;
              gid = 992;
              comment = "SSH privilege separation user";
            };
            groups.sshd.gid = 992;
          };
          services.boot = {
            depends-on = [
              "openssh"
              "nix-daemon"
            ];
          };
          services.openssh = {
            type = "process";
            command = "${lib.getExe' pkgs.openssh "sshd"} -D -f /etc/ssh/sshd_config -e";
            options = [ "shares-console" ];
            depends-on = [ "setup" ];
          };
          services.nix-daemon = {
            command = "${lib.getExe' pkgs.lix "nix-daemon"} --daemon --store local";
            depends-on = [
              "setup"
            ];
          };
          services.nix-cache = {
            command = "${lib.getExe' pkgs.lix "nix-daemon"} --daemon --store local";
            depends-on = [
              "setup"
            ];
          };
          # set up root filesystem with paths required for a Linux system to function normally
          services.setup = {
            type = "scripted";
            command = lib.getExe (
              pkgs.writeScriptBin "setup" # bash
                ''
                  #! ${pkgs.runtimeShell}
                  # Stuff requred for $most things
                  mkdir --parents /run
                  mkdir --parents /var/log
                  rsync --archive ${pkgs.dockerTools.binSh}/ /
                  rsync --archive ${pkgs.dockerTools.caCertificates}/ /
                  rsync --archive ${pkgs.dockerTools.usrBinEnv}/ /
                  # Tricking OpenSSH's security policies
                  rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=root:root /etc/ssh-mount/ /etc/ssh/
                  rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=root:root /etc/nix-mount/ /etc/nix/
                  rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=nix:nix /etc/ssh-mount/ /home/nix/.ssh/
                  chown -R nix:nix /home/nix
                ''
            );
          };
        };
      }
    ];
  };
  initcopy =
    pkgs.writeScriptBin "initcopy" # bash
      ''
        #! ${pkgs.runtimeShell}
        set -euo pipefail
        export PATH=${
          lib.makeBinPath [
            pkgs.rsync
            pkgs.lix
          ]
        }:$PATH
        nix copy --store local --to /nix-volume --no-check-sigs $(nix path-info --store local --all)
        nix build --store /nix-volume --out-link /nix-volume/nix/var/result /nix/var/result
      '';
  pathEnv = pkgs.buildEnv {
    name = "pathEnv";
    paths = with pkgs; [
      dinixEval.config.containerWrapper
      initcopy
      rsync
      coreutils
      fishMinimal
      gitMinimal
      lix
      ncdu
      openssh
      curl
      sqlite
    ];
  };
in
pathEnv
