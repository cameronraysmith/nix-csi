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
        export PATH=${lib.makeBinPath [ pkgs.rsync ]}:$PATH
        mkdir --parents $HOME
        rsync --archive ${pkgs.dockerTools.binSh}/ /
        rsync --archive ${pkgs.dockerTools.caCertificates}/ /
        rsync --archive ${pkgs.dockerTools.fakeNss}/ /
        rsync --archive ${pkgs.dockerTools.usrBinEnv}/ /
        source /buildscript/run
      '';

  dinixEval = import dinix {
    inherit pkgs;
    modules = [
      {
        config = {
          # services.boot.depends-on = [ "nix-csi" ];
          services.boot.waits-for = [
            "nix-csi"
            "nix-daemon"
          ];
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
            command = "${lib.getExe pkgs.lix} store gc";
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
                  mkdir --parents /run
                  mkdir --parents ''${HOME}
                  rsync --archive ${pkgs.dockerTools.fakeNss}/ /
                  rsync --archive ${pkgs.dockerTools.binSh}/ /
                  rsync --archive ${pkgs.dockerTools.caCertificates}/ /
                  rsync --archive ${pkgs.dockerTools.usrBinEnv}/ /
                  # Tricking OpenSSH's security policies, allow this to fail, sshc might not exist
                  rsync --archive --copy-links --chmod=600 /etc/sshc/ $HOME/.ssh/ || true
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
        rsync --archive ${pkgs.dockerTools.fakeNss}/ /
        nix copy --store local --to /nix-volume --no-check-sigs $(nix path-info --store local --all)
        nix build --store /nix-volume --out-link /nix-volume/nix/var/result ${rootEnv}
      '';

  rootEnv = pkgs.buildEnv {
    name = "rootEnv";
    paths = with pkgs; [
      dinixEval.config.containerWrapper
      fishMinimal
      coreutils
      lix
      build
      util-linuxMinimal
    ];
  };
in
nix2container.buildImage {
  name = "nix-csi";
  initializeNixDatabase = true;
  maxLayers = 120;
  config = {
    Entrypoint = [ (lib.getExe dinixEval.config.containerWrapper) ];
    Env = [
      "PATH=${
        lib.makeBinPath [
          initcopy
          rootEnv
        ]
      }"
    ];
  };
  # So we can peek into eval
  meta.dinixEval = dinixEval;
}
