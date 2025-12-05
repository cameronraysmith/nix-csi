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
      inherit (inputs.nixpkgs) lib;
    in
    {
      packages = lib.genAttrs [ "aarch64-linux" "x86_64-linux" ] (
        system:
        let
          def = import ./. { inherit system; };
        in
        {
          env = def.env;
        }
      );
    };
}
