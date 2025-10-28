{ config, lib, ... }:
let
  cfg = config.nix-csi;
  nsRes = config.kubernetes.resources.${cfg.namespace};
  hashAttrs = attrs: builtins.hashString "md5" (builtins.toJSON attrs);
in
{
  options.nix-csi.cache = {
    enable = lib.mkEnableOption "nix-cache";
    storageClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
    };
  };
  config = lib.mkIf cfg.cache.enable {
    kubernetes.resources.${cfg.namespace} = {
      # Mounts to /etc/ssh
      Secret.sshd.stringData = {
        authorized_keys = builtins.readFile ../id_ed25519.pub;
        id_ed25519 = builtins.readFile ../id_ed25519;
        sshd_config = # ssh
          ''
            Port 22
            AddressFamily Any

            HostKey /etc/ssh/id_ed25519

            SyslogFacility DAEMON
            SetEnv PATH=/nix/var/result/bin
            SetEnv NIXPKGS_ALLOW_UNFREE=1

            PermitRootLogin prohibit-password
            PubkeyAuthentication yes
            PasswordAuthentication no
            ChallengeResponseAuthentication no
            UsePAM no

            AuthorizedKeysFile %h/.ssh/authorized_keys

            StrictModes no

            Subsystem sftp internal-sftp
          '';
      };
      StatefulSet.nix-cache = {
        spec = {
          serviceName = "nix-cache";
          replicas = 1;
          selector.matchLabels.app = "nix-cache";
          template = {
            metadata.labels.app = "nix-cache";

            metadata.annotations.configHash = hashAttrs nsRes.ConfigMap.nix-cache-config;
            metadata.annotations.sshHash = hashAttrs nsRes.Secret.sshd;
            metadata.annotations.exprHash = hashAttrs nsRes.StatefulSet.nix-cache.spec.template.spec.volumes;
            spec = {
              serviceAccountName = "nix-csi";
              initContainers = [
                {
                  name = "initcopy";
                  image = cfg.image;
                  command = [ "initcopy" ];
                  volumeMounts = {
                    _namedlist = true;
                    nix-store.mountPath = "/nix-volume";
                    nix-config.mountPath = "/etc/nix";
                  };
                }
              ];
              containers = {
                _namedlist = true;
                cache = {
                  command = [
                    "dinit"
                    "cache"
                  ];
                  image = "quay.io/nix-csi/scratch:1.0.1";
                  env = [
                    {
                      name = "HOME";
                      value = "/nix/var/nix-csi/root";
                    }
                  ];
                  ports = [
                    {
                      containerPort = 80;
                      name = "http";
                    }
                  ];
                  volumeMounts = {
                    _namedlist = true;
                    nix-config.mountPath = "/etc/nix-mount";
                    sshd.mountPath = "/etc/ssh-mount";
                    nix-store = {
                      mountPath = "/nix";
                      subPath = "nix";
                    };
                  }
                  // (lib.optionalAttrs cfg.cache.enable {
                    sshc.mountPath = "/etc/sshc";
                  });
                };
              };
              volumes = {
                _namedlist = true;
                nix-config.configMap.name = "nix-cache-config";
                sshd.secret = {
                  secretName = "sshd";
                  defaultMode = 384;
                };
              }
              // (lib.optionalAttrs cfg.cache.enable {
                sshc.secret.secretName = "sshc";
              });
            };
          };
          volumeClaimTemplates = [
            {
              metadata.name = "nix-store";
              spec = {
                accessModes = [ "ReadWriteOnce" ];
                resources.requests.storage = "10Gi";
                inherit (cfg.cache) storageClassName;
              };
            }
          ];
        };
      };

      Service.nix-cache = {
        spec = {
          selector.app = "nix-cache";
          ports = [
            {
              port = 22;
              targetPort = 22;
              name = "ssh";
            }
            {
              port = 80;
              targetPort = 80;
              name = "http";
            }
          ];
          type = "ClusterIP";
        };
      };
      Service.nix-cache-lb = {
        spec = {
          selector.app = "nix-cache";
          ports = [
            {
              port = 22;
              targetPort = 22;
              name = "ssh";
            }
            {
              port = 80;
              targetPort = 80;
              name = "http";
            }
          ];
          type = "LoadBalancer";
        };
      };
    };
  };
}
