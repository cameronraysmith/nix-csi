{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nix-csi;
  system = pkgs.stdenv.hostPlatform.system;
in
{
  options.nix-csi.ctest = {
    enable = lib.mkEnableOption "ctest";
    replicas = lib.mkOption {
      type = lib.types.int;
      default = 10;
    };
  };
  config = lib.mkIf cfg.ctest.enable {
    kubernetes.resources.${cfg.namespace}.Deployment.ctest =
      let
        pkg.${system} = import ../guests/ctest.nix {
          inherit pkgs;
        };
      in
      {
        spec = {
          replicas = cfg.ctest.replicas;
          selector.matchLabels.app = "ctest";
          template = {
            metadata.labels.app = "ctest";
            spec = {
              containers = [
                {
                  name = "ctest";
                  command = [ pkg.${system}.meta.mainProgram ];
                  image = "quay.io/nix-csi/scratch:1.0.1";
                  volumeMounts = lib.mkNamedList {
                    nix-csi.mountPath = "/nix";
                  };
                }
              ];
              volumes = lib.mkNamedList {
                nix-csi.csi = {
                  driver = "nix.csi.store";
                  readOnly = false;
                  volumeAttributes.${system} = pkg.${system};
                };
              };
            };
          };
        };
      };
  };
}
