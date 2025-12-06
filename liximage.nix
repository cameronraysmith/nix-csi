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
  pkgs = import inputs.nixpkgs { };
  inherit (pkgs) lib;
  inherit (import inputs.nix2container { inherit pkgs; }) nix2container;
in
rec {
  inherit nix2container pkgs;
  images = lib.genAttrs [ "aarch64-linux" "x86_64-linux" ] (
    system:
    let
      pkgs = import inputs.nixpkgs { inherit system; };
      inherit (pkgs) lib;
      initCopy =
        pkgs.writeScriptBin "initCopy" # bash
          ''
            #! ${pkgs.runtimeShell}
            export PATH=${
              lib.makeBinPath [
                pkgs.coreutils
                pkgs.gitMinimal
                pkgs.lix
                pkgs.rsync
                pkgs.openssh
              ]
            }
            set -x
            rsync --archive ${pkgs.dockerTools.fakeNss.override {
              extraGroupLines = [
                "nixbld:x:30000:"
              ];
            }}/ /
            mkdir /tmp
            nix \
              build \
                --max-jobs auto \
                --option sandbox false \
                --store /nix-volume \
                --out-link /nix-volume/nix/var/result \
                --fallback \
                github:lillecarl/nix-csi/$TAG#env
          '';
    in
    nix2container.buildImage {
      name = "quay.io/nix-csi/lix";
      tag = "${pkgs.lix.version}-${pkgs.stdenv.hostPlatform.system}";
      arch = pkgs.go.GOARCH;
      maxLayers = 127;
      initializeNixDatabase = true;
      copyToRoot = [
        pkgs.dockerTools.binSh
        pkgs.dockerTools.caCertificates
        pkgs.dockerTools.usrBinEnv
      ];
      config = {
        Entrypoint = [ (lib.getExe initCopy) ];
      };
    }
  );
  push =
    pkgs.writeScriptBin "push" # bash
      ''
        #! ${pkgs.runtimeShell}
        export PATH=${lib.makeBinPath [ pkgs.regctl ]}:$PATH
        ${lib.getExe images.${"aarch64-linux"}.copyToRegistry}
        ${lib.getExe images.${"x86_64-linux"}.copyToRegistry}
        regctl index create quay.io/nix-csi/lix:${pkgs.lix.version} \
          --ref ${images.${"aarch64-linux"}.imageRefUnsafe} \
          --ref ${images.${"x86_64-linux"}.imageRefUnsafe}
        regctl index create quay.io/nix-csi/lix:latest \
          --ref ${images.${"aarch64-linux"}.imageRefUnsafe} \
          --ref ${images.${"x86_64-linux"}.imageRefUnsafe}
      '';
}
