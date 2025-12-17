let
  inputs =
    (
      let
        lockFile = builtins.readFile ./flake.lock;
        lockAttrs = builtins.fromJSON lockFile;
        fcLockInfo = lockAttrs.nodes.flake-compatish.locked;
        fcSrc = builtins.fetchTree fcLockInfo;
        flake-compatish = import fcSrc;
      in
      flake-compatish ./.
    ).inputs;
in
{
  pkgs ? import inputs.nixpkgs { inherit system; },
  system ? builtins.currentSystem,
  local ? null,
}:
let
  pkgs' = pkgs.extend (import ./pkgs);
in
let
  pkgs = pkgs';
  lib = pkgs.lib;

  crossAttrs = {
    "x86_64-linux" = "aarch64-linux";
    "aarch64-linux" = "x86_64-linux";
  };
  pkgsCross = import pkgs.path {
    system = crossAttrs.${system};
    overlays = [ (import ./pkgs) ];
  };
  easykubenix = import inputs.easykubenix;
  kubenixApply = kubenixInstance {
    specialArgs = {
      nix-csi = {
        ${pkgs.stdenv.hostPlatform.system} = builtins.unsafeDiscardStringContext (
          import ./container {
            inherit pkgs;
            inherit (inputs) dinix;
          }
        );
        ${pkgsCross.stdenv.hostPlaform.system} = builtins.unsafeDiscardStringContext (
          import ./container {
            pkgs = pkgsCross;
            inherit (inputs) dinix;
          }
        );
      };
    };
  };
  kubenixPush = kubenixInstance {
    specialArgs = {
      nix-csi = {
        ${pkgs.stdenv.hostPlatform.system} = (
          import ./container {
            inherit pkgs;
            inherit (inputs) dinix;
          }
        );
        ${pkgsCross.stdenv.hostPlatform.system} = (
          import ./container {
            pkgs = pkgsCross;
            inherit (inputs) dinix;
          }
        );
      };
    };
  };
  kubenixInstance =
    {
      specialArgs ? { },
    }:
    easykubenix {
      inherit pkgs;
      inherit specialArgs;
      modules = [
        ./kubenix
        {
          config.nix-csi.authorizedKeys = lib.pipe (lib.filesystem.listFilesRecursive ./keys) [
            (lib.filter (name: lib.hasSuffix ".pub" name))
            (lib.map (name: builtins.readFile name))
            (lib.map (key: lib.trim key))
          ];
        }
        {
          config = {
            nix-csi = {
              enable = true;
              version = "develop";
              cache.storageClassName = "hcloud-volumes";
            }
            // lib.optionalAttrs (local != null) {
              cache.storageClassName = "local-path";
              ctest = {
                enable = true;
                replicas = 1;
              };
            };
            kluctl = {
              discriminator = "nix-csi";
            }
            // lib.optionalAttrs (local != null) {
              preDeployScript =
                pkgs.writeScriptBin "preDeployScript" # bash
                  ''
                    #! ${pkgs.runtimeShell}
                    set -euo pipefail
                    set -x
                    nix copy --no-check-sigs --to ssh-ng://nix@192.168.88.20 "$1" -v || true
                  '';
            };
          };
        }
      ];
    };

  persys = pkgs: rec {
    inherit pkgs lib;

    pypkgs = (
      pypkgs: with pypkgs; [
        pkgs.nix-csi
        pkgs.csi-proto-python
        pkgs.kr8s
      ]
    );
    python = pkgs.python3.withPackages pypkgs;
    xonsh = pkgs.xonsh.override {
      extraPackages = pypkgs;
    };
    # env to add to PATH with direnv
    repoenv = pkgs.buildEnv {
      name = "repoenv";
      paths = [
        python
        xonsh
        pkgs.cachix
        pkgs.pyright
        pkgs.ruff
        pkgs.kluctl
        pkgs.stern
        pkgs.kubectx
        pkgs.buildah
        pkgs.skopeo
        pkgs.regctl
      ];
    };
  };
in
let
  on = persys pkgs;
  off = persys pkgsCross;
in
on
// {
  inherit
    on
    off
    inputs
    kubenixApply
    ;

  push =
    pkgs.writeScriptBin "push" # bash
      ''
        #! ${pkgs.runtimeShell}
        export PATH=${lib.makeBinPath [ pkgs.cachix ]}:$PATH
        cachix push nix-csi ${kubenixPush.manifestJSONFile}
      '';

  uploadScratch =
    let
      scratchVersion = "1.0.1";
      scratchUrl = system: "ghcr.io/lillecarl/nix-csi/scratch:${scratchVersion}-${system}";
      scratchManifest = "ghcr.io/lillecarl/nix-csi/scratch:${scratchVersion}";
    in
    pkgs.writeScriptBin "merge" # bash
      ''
        #! ${pkgs.runtimeShell}
        set -euo pipefail
        set -x
        export PATH=${lib.makeBinPath [ pkgs.buildah ]}:$PATH
        # Build and publish scratch image(s)
        container=$(buildah from --platform linux/amd64 scratch)
        buildah config --env "PATH=/nix/var/result/bin" $container
        buildah commit $container ${scratchUrl on.pkgs.stdenv.hostPlatform.system}
        buildah push ${scratchUrl on.pkgs.stdenv.hostPlatform.system}
        container=$(buildah from --platform linux/arm64 scratch)
        buildah config --env "PATH=/nix/var/result/bin" $container
        buildah commit $container ${scratchUrl off.pkgs.stdenv.hostPlatform.system}
        buildah push ${scratchUrl off.pkgs.stdenv.hostPlatform.system}
        buildah manifest rm ${scratchManifest} &>/dev/null || true
        buildah manifest create ${scratchManifest}
        buildah manifest add ${scratchManifest} ${scratchUrl on.pkgs.stdenv.hostPlatform.system}
        buildah manifest add ${scratchManifest} ${scratchUrl off.pkgs.stdenv.hostPlatform.system}
        buildah manifest push ${scratchManifest}
      '';
}
