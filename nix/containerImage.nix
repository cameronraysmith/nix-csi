# You could easily get tempted to create folders that go into container root
# using copyToRoot but it's easy to shoot yourself in the foot with Kubernetes
# mounting it's own shit over those paths making a mess out of your life.
{
  pkgs,
  dinix,
  nix2container,
}:
let
  lib = pkgs.lib;
  build =
    pkgs.writeScriptBin "build" # bash
      ''
        #! ${pkgs.runtimeShell}
        set -x
        export PATH=${
          lib.makeBinPath [
            pkgs.rsync
            pkgs.lix
            pkgs.coreutils
            pkgs.gnugrep
          ]
        }:$PATH
        ${lib.getExe dinixEval.config.internal.usersInstallScript}
        mkdir --parents /tmp
        rsync --archive ${pkgs.dockerTools.binSh}/ /
        rsync --archive ${pkgs.dockerTools.caCertificates}/ /
        rsync --archive ${pkgs.dockerTools.usrBinEnv}/ /
        rsync --archive --copy-links --chmod=D700,F600 /etc/sshc/ $HOME/.ssh/ || true
        /scripts/build
        /scripts/upload
      '';
  dinixEval = import dinix {
    inherit pkgs;
    modules = [
      {
        config = {
          users = {
            enable = true;
            users.root = {
              shell = pkgs.runtimeShell;
              homeDir = "/nix/var/nix-csi/root";
            };
          };
          services.boot.depends-on = [ "nix-csi" ];
          services.nix-csi = {
            command = "${lib.getExe pkgs.nix-csi} --loglevel DEBUG";
            options = [ "shares-console" ];
            depends-on = [
              "nix-daemon"
              "setup"
              "gc"
            ];
          };
          services.nix-daemon = {
            command = "${lib.getExe' pkgs.lix "nix-daemon"} --daemon --store local";
            depends-on = [ "setup" ];
          };
          services.gc = {
            type = "scripted";
            command =
              pkgs.writeScriptBin "gc" # bash
                ''
                  # Fix gcroots for /nix/var/result
                  nix build --out-link /nix/var/result /nix/var/result
                  nix store gc
                '';
            options = [ "shares-console" ];
            depends-on = [
              "nix-daemon"
              "setup"
            ];
          };
          services.setup = {
            type = "scripted";
            options = [ "shares-console" ];
            command = lib.getExe (
              pkgs.writeScriptBin "setup" # bash
                ''
                  #! ${pkgs.runtimeShell}
                  set -euo pipefail
                  set -x
                  export PATH=${
                    lib.makeBinPath (
                      with pkgs;
                      [
                        rsync
                        coreutils
                        lix
                      ]
                    )
                  }
                  mkdir --parents /tmp
                  rsync --archive ${pkgs.dockerTools.binSh}/ /
                  rsync --archive ${pkgs.dockerTools.caCertificates}/ /
                  rsync --archive ${pkgs.dockerTools.usrBinEnv}/ /
                  # Tricking OpenSSH's security policies, allow this to fail, sshc might not exist
                  rsync --archive --copy-links --chmod=D700,F600 /etc/sshc/ $HOME/.ssh/ || true
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
        nix build --store /nix-volume --out-link /nix-volume/nix/var/result ${pathEnv}
      '';
  pathEnv = pkgs.buildEnv {
    name = "rootEnv";
    paths = with pkgs; [
      dinixEval.config.containerWrapper
      bash # Used for build and upload scripts
      build
      coreutils
      fishMinimal
      lix
      openssh
      util-linuxMinimal
    ];
  };
in
nix2container.buildImage {
  name = "nix-csi";
  initializeNixDatabase = true;
  maxLayers = 120;
  config.Env = [
    "PATH=${
      lib.makeBinPath [
        initcopy
        pathEnv
      ]
    }"
  ];
  # So we can peek into eval
  meta.dinixEval = dinixEval;
}
