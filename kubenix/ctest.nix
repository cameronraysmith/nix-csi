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
                  image = "quay.io/nix-csi/scratch:1.0.0";
                  env = [
                    {
                      name = "PATH";
                      value = "/nix/var/result/bin";
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "nix-csi";
                      mountPath = "/nix";
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "nix-csi";
                  csi = {
                    driver = "nix.csi.store";
                    readOnly = false;
                    volumeAttributes.${system} = pkg.${system};
                  };
                }
              ];
            };
          };
        };
      };
  };
}
