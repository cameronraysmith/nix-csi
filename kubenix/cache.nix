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

            metadata.annotations.configHash = hashAttrs nsRes.ConfigMap.nix-config;
            metadata.annotations.sshHash = hashAttrs nsRes.Secret.sshd;
            metadata.annotations.exprHash = hashAttrs nsRes.StatefulSet.nix-cache.spec.template.spec.volumes;
            spec = {
              initContainers = [
                {
                  name = "initcopy";
                  image = "quay.io/nix-csi/scratch:1.0.1";
                  command = [ "initcopy" ];
                  volumeMounts = {
                    _namedlist = true;
                    nix-csi.mountPath = "/nix";
                    nix-store.mountPath = "/nix-volume";
                    nix-config.mountPath = "/etc/nix";
                  };
                }
              ];
              containers = {
                _namedlist = true;
                cache = {
                  command = [ "dinit" ];
                  image = "quay.io/nix-csi/scratch:1.0.1";
                  env = [
                    {
                      name = "HOME";
                      value = "/var/empty";
                    }
                  ];
                  ports = [
                    {
                      containerPort = 80;
                      name = "http";
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "nix-store";
                      mountPath = "/nix";
                      subPath = "nix";
                    }
                    {
                      name = "nix-config";
                      mountPath = "/etc/nix";
                    }
                    {
                      name = "sshd";
                      mountPath = "/etc/ssh-mount";
                    }
                  ];
                };
              };
              volumes = {
                _namedlist = true;
                nix-config.configMap.name = "nix-config";
                sshd.secret = {
                  secretName = "sshd";
                  defaultMode = 384;
                };
                nix-csi.csi = {
                  driver = "nix.csi.store";
                  readOnly = false;
                  volumeAttributes.buildInCSI = "";
                  volumeAttributes.expression = builtins.readFile ../guests/cache.nix;
                };
              };
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
