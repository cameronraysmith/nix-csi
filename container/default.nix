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
  dinixEval = import dinix {
    inherit pkgs;
    modules = [
      ./csi.nix
      ./cache.nix
      {
        config = {
          users = {
            enable = true;
            users.root = {
              shell = pkgs.runtimeShell;
              homeDir = "/nix/var/nix-csi/root";
            };
            users.nix = {
              uid = 1000;
              gid = 1000;
              comment = "Nix worker user";
            };
            groups.nix.gid = 1000;
            groups.nixbld.gid = 30000;
            users.sshd = {
              uid = 993;
              gid = 992;
              comment = "SSH privilege separation user";
            };
            groups.sshd.gid = 992;
          };
          services.openssh = {
            type = "process";
            command = "${lib.getExe' pkgs.openssh "sshd"} -D -f /etc/ssh/sshd_config -e";
            options = [ "shares-console" ];
            depends-on = [ "shared-setup" ];
          };
          services.nix-daemon = {
            command = "${lib.getExe' pkgs.lix "nix-daemon"} --daemon --store local";
            depends-on = [ "shared-setup" ];
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
              "shared-setup"
            ];
          };
          services.shared-setup = {
            type = "scripted";
            options = [ "shares-console" ];
            command = lib.getExe (
              pkgs.writeScriptBin "shared-setup" # bash
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
                  mkdir --parents /var/log
                  rsync --archive ${pkgs.dockerTools.binSh}/ /
                  rsync --archive ${pkgs.dockerTools.caCertificates}/ /
                  rsync --archive ${pkgs.dockerTools.usrBinEnv}/ /
                  # Tricking OpenSSH's security policies, allow this to fail, sshc might not exist
                  rsync --archive --copy-links --chmod=D700,F600 /etc/sshc/ $HOME/.ssh/ || true
                  rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=root:root /etc/ssh-mount/ /etc/ssh/
                  rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=nix:nix /etc/ssh-mount/ /home/nix/.ssh/
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
      coreutils
      fishMinimal
      lix
      openssh
      util-linuxMinimal
      gnugrep
      getent
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
