self: pkgs: {
  # Overlay lib
  lib = pkgs.lib.extend (import ../lib);

  # execline script that takes NIX_STATE_DIR as first and second arg, then
  # storepaths as consecutive args. Dumps nix database one NIX_STATE_DIR and
  # imports it into another NIX_STATE_DIR database
  nix_init_db =
    pkgs.writeScriptBin "nix_init_db" # execline
      ''
        #! ${self.lib.getExe' pkgs.execline "execlineb"} -s1
        emptyenv -p
        pipeline { nix-store --option store local --dump-db $@ }
        export USER nobody
        export NIX_STATE_DIR $1
        exec nix-store --load-db --option store local
      '';

  nix-csi = self.csi-root.csi;
  nix-cache = self.csi-root.cache;
  csi-root = pkgs.python3Packages.callPackage ../python {
    inherit (self) csi-proto-python kr8s;
  };

  lix = pkgs.lix.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or [ ]) ++ [
      (pkgs.fetchpatch {
        url = "https://github.com/Lillecarl/lix/commit/b5e5a56b93da57239feb192416291af21df8dfe8.patch";
        hash = "sha256-b65/gMXdC1oghF5SPdmYYeqkwifzCW/cb6TGbwkne8U=";
      })
    ];
    doCheck = false;
    doInstallCheck = false;
  });

  csi-proto-python = pkgs.python3Packages.callPackage ./csi-proto-python { };
  python-jsonpath = pkgs.python3Packages.callPackage ./python-jsonpath.nix { };
  kr8s = pkgs.python3Packages.callPackage ./kr8s.nix { inherit (self) python-jsonpath; };

}
