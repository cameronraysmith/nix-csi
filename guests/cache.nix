{
  pkgs ? import <nixpkgs> { },
  dinix ? import <dinix>,
}:
let
  lib = pkgs.lib;
  fakeNss = pkgs.dockerTools.fakeNss.override {
    extraPasswdLines = [
      # passwd
      ''sshd:x:993:992:SSH privilege separation user:/var/empty:/bin/sh''
      # passwd
      ''nix:x:1000:1000:Nix binary cache user:/home/nix:/bin/sh''
    ];
    extraGroupLines = [
      # groups
      ''nix:x:1000:''
    ];
  };

  dinixEval = dinix {
    inherit pkgs;
    modules = [
      {
        config = {
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
            command = "${lib.getExe' pkgs.lix "nix-daemon"} --daemon --store /content";
            depends-on = [ "setup" ];
          };
          services.harmonia = {
            type = "process";
            command = "${lib.getExe pkgs.harmonia}";
            options = [ "shares-console" ];
            run-as = "nobody";
            depends-on = [
              "setup"
              "nix-daemon"
            ];
          };
          # set up root filesystem with paths required for a Linux system to function normally
          services.setup = {
            type = "scripted";
            command = lib.getExe (
              pkgs.writeScriptBin "setup" # bash
                ''
                  #! ${pkgs.runtimeShell}
                  # It's good to have a $HOME
                  mkdir --parents ''${HOME}
                  mkdir --parents /home/nix
                  # Stuff requred for $most things
                  mkdir --parents /run
                  rsync --archive ${fakeNss}/ /
                  rsync --archive ${pkgs.dockerTools.binSh}/ /
                  rsync --archive ${pkgs.dockerTools.caCertificates}/ /
                  rsync --archive ${pkgs.dockerTools.usrBinEnv}/ /
                  # Tricking OpenSSH's security policies
                  rsync --archive --copy-links --chmod=600 /etc/ssh-mount/ /etc/ssh/
                  rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=nix:nix /etc/ssh-mount/ /home/nix/.ssh/
                  chown -R nix:nix /home/nix
                  # Init nix2 store
                  nix store ping --store /content
                ''
            );
          };
        };
      }
    ];
  };
  dinitWrapper =
    pkgs.writeScriptBin "dinit" # bash
      ''
        #! ${pkgs.runtimeShell}
        rsync --archive ${fakeNss}/ /
        exec ${dinixEval.config.containerWrapper}/bin/dinit
      '';
in
pkgs.buildEnv {
  name = "binary-cache-env";
  paths = with pkgs; [
    rsync
    coreutils
    fishMinimal
    gitMinimal
    lix
    ncdu
    openssh
    curl
    sqlite
    dinitWrapper
  ];
}
