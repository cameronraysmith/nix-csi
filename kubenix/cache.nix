{ config, lib, ... }:
let
  cfg = config.nix-csi;
in
{
  options.nix-csi.cache = {
    enable = lib.mkEnableOption "harmonia";
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
            LogLevel DEBUG3
            SetEnv PATH=/nix/var/result/bin

            PermitRootLogin prohibit-password
            PubkeyAuthentication yes
            PasswordAuthentication no
            ChallengeResponseAuthentication no
            UsePAM no

            AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys

            StrictModes no

            Subsystem sftp internal-sftp
          '';
      };
      Secret.harmonia.stringData.sign_key = builtins.readFile ../cache-secret;
      ConfigMap.harmonia.data."config.toml" = # TOML
      ''
        bind = "[::]:80"
        virtual_nix_store = "/nix/store"
        real_nix_store = "/content/nix/store"
        sign_key_paths = [ "/var/run/secrets/harmonia/sign_key" ]
      '';

      StatefulSet.nix-cache = {
        spec = {
          serviceName = "nix-cache";
          replicas = 1;
          selector.matchLabels.app = "nix-cache";
          template = {
            metadata.labels.app = "nix-cache";
            metadata.annotations.harmoniaHash = builtins.hashString "md5" (builtins.toJSON config.kubernetes.resources.${cfg.namespace}.ConfigMap.harmonia);
            metadata.annotations.sshHash = builtins.hashString "md5" (builtins.toJSON config.kubernetes.resources.${cfg.namespace}.Secret.sshd);
            spec = {
              containers = {
                _namedlist = true;
                nix-serve = {
                  command = [ "dinit" ];
                  image = "quay.io/nix-csi/scratch:1.0.1";
                  env = [
                    {
                      name = "HOME";
                      value = "/var/empty";
                    }
                    {
                      name = "CONFIG_FILE";
                      value = "/etc/harmonia/config.toml";
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
                      name = "nix-csi";
                      mountPath = "/nix";
                    }
                    {
                      name = "nix-cache";
                      mountPath = "/content";
                    }
                    {
                      name = "nix-config";
                      mountPath = "/etc/nix";
                    }
                    {
                      name = "sshd";
                      mountPath = "/etc/ssh-mount";
                    }
                    {
                      name = "harmonia-config";
                      mountPath = "/etc/harmonia";
                    }
                    {
                      name = "harmonia-secret";
                      mountPath = "/var/run/secrets/harmonia";
                    }
                  ];
                };
              };
              volumes = {
                _namedlist = true;
                nix-config.configMap.name = "nix-config";
                harmonia-secret.secret.secretName = "harmonia";
                harmonia-config.configMap.name = "harmonia";
                sshd.secret.secretName = "sshd";
                nix-csi.csi = {
                  driver = "nix.csi.store";
                  readOnly = false;
                  volumeAttributes.expression = builtins.readFile ../guests/cache.nix;
                };
              };
            };
          };
          volumeClaimTemplates = [
            {
              metadata.name = "nix-cache";
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
