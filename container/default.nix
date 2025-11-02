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
          env-file.variables = {
            PYTHONUNBUFFERED = "1"; # If something ends up print logging
            NIXPKGS_ALLOW_UNFREE = "1"; # Allow building anything
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
          services.config-reconciler = {
            type = "process";
            options = [ "shares-console" ];
            command =
              pkgs.writeScriptBin "config-reconciler" # bash
                ''
                  #! ${pkgs.runtimeShell}
                  set -euo pipefail
                  set -x
                  export PATH=${
                    lib.makeBinPath [
                      pkgs.rsync
                      pkgs.coreutils
                    ]
                  }
                  while true
                  do
                    # Tricking OpenSSH's security policies like a pro!
                    #
                    # Exclude authorized_keys from root, we don't want anyone
                    # logging in as root in our containers.
                    rsync --archive --mkpath --copy-links --chmod=D700,F600 --exclude='authorized_keys' /etc/ssh-mount/ $HOME/.ssh/
                    # Here authorized_keys don't matter since we only check %h
                    # for authorized_keys in sshd config
                    rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=root:root /etc/ssh-mount/ /etc/ssh/
                    # Everyone should log in as Nix to build or substitute
                    rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=nix:nix /etc/ssh-mount/ /home/nix/.ssh/
                    # Copy mounted Nix config to nix config dir
                    rsync --archive --mkpath --copy-links --chmod=D755,F644 --chown=root:root /etc/nix-mount/ /etc/nix/
                    # 60s reconciliation is good enough
                    sleep 60
                  done
                '';
          };
          services.shared-setup = {
            type = "scripted";
            options = [ "shares-console" ];
            depends-on = [ "config-reconciler" ];
            command =
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
                  mkdir --parents {/tmp,/var/tmp}
                  chmod -R 1777 {/tmp,/var/tmp}
                  mkdir --parents {/var/log}
                  chmod -R 0755 {/var/log}
                  rsync --archive ${pkgs.dockerTools.binSh}/ /
                  rsync --archive ${pkgs.dockerTools.caCertificates}/ /
                  rsync --archive ${pkgs.dockerTools.usrBinEnv}/ /
                  rsync --archive --mkpath --copy-links --chmod=D700,F600 --exclude='authorized_keys' /etc/ssh-mount/ $HOME/.ssh/
                  rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=root:root /etc/ssh-mount/ /etc/ssh/
                  rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=nix:nix /etc/ssh-mount/ /home/nix/.ssh/
                  # Fix gcroots for /nix/var/result. The ones created by initCopy
                  # points to invalid symlinks in the chain
                  # (auto -> /nix-volume/var/result) rather than
                  # auto -> /nix/var/result. The link back to store works though
                  # so this will just fix gcroots.
                  nix build --store local --out-link /nix/var/result /nix/var/result
                '';
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
        # Copy entire entire container image into volume
        nix path-info --store local --all | nix copy --store local --to /nix-volume --no-check-sigs --stdin
        # Link /nix/var/result properly so it doesn't get GC'd
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
      doggo
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
