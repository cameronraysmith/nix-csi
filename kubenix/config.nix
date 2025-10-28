{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nix-csi;
in
{
  config = lib.mkIf cfg.enable {
    kubernetes.resources.${cfg.namespace} =
      let
        sharedConfig = # dinit
          ''
            # Use nix daemon for builds
            store = daemon
            # Users who can do supernixxy things
            trusted-users = root nix
            # Allow everyone to Nix!
            allowed-users = *
            # Auto allocare uids so we don't have to create lots of users in containers
            auto-allocate-uids = true
            # This supposedly helps with the sticky cache issue
            fallback = true
            # Enable common features
            experimental-features = nix-command flakes auto-allocate-uids fetch-closure pipe-operator
            # let builders sub
            builders-use-substitutes = true
            # Fuck purity
            warn-dirty = false
            # Features?
            system-features = nixos-test benchmark big-parallel uid-range
          '';
      in
      {
        ConfigMap.nix-cache-config.data = {
          "nix.conf" = # dinit
            ''
              ${sharedConfig}
              max-jobs = auto
            '';
        };
        ConfigMap.nix-csi-config.data = {
          "nix.conf" = # dinit
            ''
                ${sharedConfig}
              # substituters
              extra-substituters = ssh-ng://nix@nix-cache?trusted=1&priority=20
              max-jobs = 0
            '';
          "nix-path.nix" = # nix
            ''
              let
                paths = {
                  nixpkgs = builtins.fetchTree {
                    type = "github";
                    owner = "nixos";
                    repo = "nixpkgs";
                    ref = "nixos-25.05";
                  };
                  nixos-unstable = builtins.fetchTree {
                    type = "github";
                    owner = "nixos";
                    repo = "nixpkgs";
                    ref = "nixos-unstable";
                  };
                  home-manager = builtins.fetchTree {
                    type = "github";
                    owner = "nix-community";
                    repo = "home-manager";
                    ref = "release-25.05";
                  };
                  home-manager-unstable = builtins.fetchTree {
                    type = "github";
                    owner = "nix-community";
                    repo = "home-manager";
                    ref = "master";
                  };
                  dinix = builtins.fetchTree {
                    type = "github";
                    owner = "lillecarl";
                    repo = "dinix";
                    ref = "main";
                  };
                  flake-compatish = builtins.fetchTree {
                    type = "github";
                    owner = "lillecarl";
                    repo = "flake-compatish";
                    ref = "main";
                  };
                };

                pkgs = import paths.nixpkgs { };
                inherit (pkgs) lib;

              in
              lib.pipe paths [
                (lib.mapAttrsToList (name: value: "''${name}=''${value}"))
                (lib.concatStringsSep ":")
                (pkgs.writeText "NIX_PATH")
              ]
            '';
        };
      };
  };
}
