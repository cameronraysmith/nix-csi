{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-compatish = {
      url = "github:lillecarl/flake-compatish";
      flake = false;
    };
    easykubenix = {
      url = "github:lillecarl/easykubenix";
      flake = false;
    };
    dinix = {
      url = "github:lillecarl/dinix";
      flake = false;
    };
    nix2container = {
      url = "github:nlewo/nix2container";
      flake = false;
    };
  };
  outputs =
    inputs:
    let
      eachSystem = inputs.nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      packages = eachSystem (
        system:
        let
          pkgs = import inputs.nixpkgs { inherit system; };
          nix-csi = import ./default.nix { inherit pkgs; };
        in
        {
          image = nix-csi.image;
          inherit
            (nix-csi.easykubenix {
              modules = [
                ./kubenix
                { nix-csi.enable = true; }
              ];
            })
            deploymentScript
            manifestYAMLFile
            manifestJSONFile
            ;
        }
      );
    };
}
