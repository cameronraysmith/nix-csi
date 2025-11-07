{ config, lib, ... }:
let
  cfg = config.nix-csi;
  nsRes = config.kubernetes.resources.${cfg.namespace};
  hashAttrs = attrs: builtins.hashString "md5" (builtins.toJSON attrs);
in
{
  options.nix-csi.cache = {
    storageClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    loadBalancerPort = lib.mkOption {
      type = lib.types.int;
      default = 2222;
    };
  };
  config = {
    kubernetes.resources.${cfg.namespace} = {
      ConfigMap.authorized-keys.data.authorized_keys = lib.concatLines cfg.authorizedKeys;
      StatefulSet.nix-cache = {
        spec = {
          serviceName = "nix-cache";
          replicas = 1;
          selector.matchLabels.app = "nix-cache";
          template = {
            metadata.labels.app = "nix-cache";

            metadata.annotations.configHash = hashAttrs nsRes.ConfigMap.nix-cache-config;
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
                  env = {
                    _namedlist = true;
                    HOME.value = "/nix/var/nix-csi/root";
                    KUBE_NAMESPACE.valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    BUILDERS_SERVICE_NAME.value = cfg.internalServiceName;
                  };
                  ports = [
                    {
                      containerPort = 80;
                      name = "http";
                    }
                  ];
                  volumeMounts = {
                    _namedlist = true;
                    nix-config.mountPath = "/etc/nix-mount";
                    ssh.mountPath = "/etc/ssh-mount";
                    nix-store = {
                      mountPath = "/nix";
                      subPath = "nix";
                    };
                  };
                };
              };
              volumes = {
                _namedlist = true;
                nix-config.configMap.name = "nix-cache-config";
                ssh.secret = {
                  secretName = "ssh";
                  defaultMode = 384;
                  optional = true;
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
          ];
          type = "ClusterIP";
        };
      };
      Service.nix-cache-lb = {
        spec = {
          selector.app = "nix-cache";
          ports = {
            _namedlist = true;
            ssh = {
              port = cfg.cache.loadBalancerPort;
              targetPort = 22;
            };
          };
          type = "LoadBalancer";
        };
      };
    };
  };
}
