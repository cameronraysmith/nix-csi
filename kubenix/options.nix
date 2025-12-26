{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nix-csi;
  inputs =
    (
      let
        lockFile = builtins.readFile ../flake.lock;
        lockAttrs = builtins.fromJSON lockFile;
        fcLockInfo = lockAttrs.nodes.flake-compatish.locked;
        fcSrc = builtins.fetchTree fcLockInfo;
        flake-compatish = import fcSrc;
      in
      flake-compatish ../.
    ).inputs;
in
{
  options.nix-csi = {
    enable = lib.mkEnableOption "nix-csi";
    undeploy = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    namespace = lib.mkOption {
      description = "Which namespace to deploy cknix resources too";
      type = lib.types.str;
      default = "nix-csi";
    };
    authorizedKeys = lib.mkOption {
      description = "SSH public keys that can connect to cache and builders";
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    version = lib.mkOption {
      type = lib.types.str;
      default =
        let
          pyproject = builtins.fromTOML (builtins.readFile ../python/pyproject.toml);
        in
        pyproject.project.version;
    };
    hostMountPath = lib.mkOption {
      description = "Where on the host to put cknix store";
      type = lib.types.path;
      default = "/var/lib/nix-csi";
    };
    internalServiceName = lib.mkOption {
      description = ''
        Internal service name used for reaching builder nodes from cache node
      '';
      type = lib.types.str;
      default = "nix-builders";
    };

    cachePackage = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      internal = true;
    };
    nodePackage = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      internal = true;
    };
    pkgs = lib.mkOption {
      type = lib.types.path;
      default = inputs.nixpkgs;
      internal = true;
    };
    push = lib.mkOption {
      type = lib.types.bool;
      internal = true;
      default = false;
    };
    dinix = lib.mkOption {
      type = lib.types.path;
      internal = true;
      default = inputs.dinix;
    };
  };
  config =
    let
      # Watch this fall apart when we're adding more architectures
      crossAttrs = {
        "x86_64-linux" = "aarch64-linux";
        "aarch64-linux" = "x86_64-linux";
      };
      system = pkgs.stdenv.hostPlatform.system;
      systemCross = crossAttrs.${system};

      pkgs = import cfg.pkgs {
        overlays = [ (import ../pkgs) ];
      };
      pkgsCross = import cfg.pkgs {
        system = systemCross;
        overlays = [ (import ../pkgs) ];
      };
      cachePackage = {
        ${system} = import ../environments/cache {
          inherit pkgs;
          inherit (cfg) dinix;
        };
        ${systemCross} = import ../environments/cache {
          pkgs = pkgsCross;
          inherit (cfg) dinix;
        };
      };
      nodePackage = {
        ${system} = import ../environments/node {
          inherit pkgs;
          inherit (cfg) dinix;
        };
        ${systemCross} = import ../environments/node {
          pkgs = pkgsCross;
          inherit (cfg) dinix;
        };
      };
    in
    lib.mkIf cfg.enable {
      nix-csi.cachePackage = cachePackage;
      nix-csi.nodePackage = nodePackage;
    };
}
