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
  pkgs ? import inputs.nixpkgs { },
  local ? null,
}:
let
  pkgs' = pkgs.extend (import ./pkgs);
in
let
  pkgs = pkgs';
  lib = pkgs.lib;

  dinix = inputs.dinix;

  crossAttrs = {
    "x86_64-linux" = "aarch64-linux";
    "aarch64-linux" = "x86_64-linux";
  };
  pkgsCross = import pkgs.path {
    system = crossAttrs.${builtins.currentSystem};
    overlays = [ (import ./pkgs) ];
  };
  persys = pkgs: rec {
    inherit pkgs lib;
    n2c = import inputs.nix2container {
      inherit pkgs;
    };
    easykubenix = import inputs.easykubenix;

    # kubenix evaluation
    kubenixEval = easykubenix {
      inherit pkgs;
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
            }
            // lib.optionalAttrs (local != null) {
              image = imageRef;
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

    # script to build daemonset image
    image = import ./container {
      inherit pkgs dinix;
      inherit (n2c) nix2container;
    };
    inherit (image.passthru) dinixEval;

    imageToContainerd = copyToContainerd image;
    imageRef = "quay.io/nix-csi/${image.imageRefUnsafe}";

    copyToContainerd =
      image:
      pkgs.writeScriptBin "copyToContainerd" # execline
        ''
          #!${pkgs.execline}/bin/execlineb -P

          # Set up a socket we can write to
          backtick -E fifo { mktemp -u ocisocket.XXXXXX }
          foreground { mkfifo $fifo }
          trap { default { rm ''${fifo} } }

          # Dump image to socket in the background
          background {
            # Ignore stdout (since containerd requires sudo and we want a clean prompt)
            redirfd -w 1 /dev/null
            ${lib.getExe n2c.skopeo-nix2container}
              --insecure-policy copy
              nix:${image}
              oci-archive:''${fifo}:${imageRef}
          }
          export CONTAINERD_ADDRESS /run/containerd/containerd.sock

          foreground {
            sudo -E ${lib.getExe' pkgs.containerd "ctr"}
              --namespace k8s.io
              images import ''${fifo}
          }
          rm ''${fifo}
        '';

    deploy =
      pkgs.writers.writeFishBin "deploy" # fish
        ''
          # Build container image
          nix run --file . imageToContainerd || begin
              echo "DaemonSet image failed"
              return 1
          end
          ${lib.getExe kubenixEval.deploymentScript} $argv
        '';

    # simpler than devshell
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
        n2c.skopeo-nix2container
        pkgs.kluctl
        pkgs.buildah
        pkgs.step-cli
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
  inherit off;

  uploadCsi =
    let
      csiUrl = system: "quay.io/nix-csi/nix-csi:${on.pkgs.nix-csi.version}-${system}";
      csiManifest = "quay.io/nix-csi/nix-csi:${on.pkgs.nix-csi.version}";
    in
    pkgs.writeScriptBin "merge" # bash
      ''
        #! ${pkgs.runtimeShell}
        set -euo pipefail
        set -x
        buildDir=$(mktemp -d ocibuild.XXXXXX)
        echo $buildDir
        mkdir -p $buildDir
        cleanup() {
          rm -rf "$buildDir"
        }
        trap cleanup EXIT
        # Build and publish nix-csi image(s)
        ${lib.getExe on.image.copyTo} oci-archive:$buildDir/csi-${on.pkgs.stdenv.hostPlatform.system}:${csiUrl on.pkgs.stdenv.hostPlatform.system}
        ${lib.getExe off.image.copyTo} oci-archive:$buildDir/csi-${off.pkgs.stdenv.hostPlatform.system}:${csiUrl off.pkgs.stdenv.hostPlatform.system}
        podman load --input $buildDir/csi-${on.pkgs.stdenv.hostPlatform.system}
        podman load --input $buildDir/csi-${off.pkgs.stdenv.hostPlatform.system}
        podman push ${csiUrl on.pkgs.stdenv.hostPlatform.system}
        podman push ${csiUrl off.pkgs.stdenv.hostPlatform.system}
        podman manifest rm ${csiManifest} &>/dev/null || true
        podman manifest create ${csiManifest}
        podman manifest add ${csiManifest} ${csiUrl on.pkgs.stdenv.hostPlatform.system}
        podman manifest add ${csiManifest} ${csiUrl off.pkgs.stdenv.hostPlatform.system}
        podman manifest push ${csiManifest}
      '';
  uploadScratch =
    let
      scratchVersion = "1.0.1";
      scratchUrl = system: "quay.io/nix-csi/scratch:${scratchVersion}-${system}";
      scratchManifest = "quay.io/nix-csi/scratch:${scratchVersion}";
    in
    pkgs.writeScriptBin "merge" # bash
      ''
        #! ${pkgs.runtimeShell}
        set -euo pipefail
        set -x
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
