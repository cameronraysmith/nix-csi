{ config, lib, ... }:
let
  cfg = config.nix-csi;
  nsRes = config.kubernetes.resources.${cfg.namespace};
  hashAttrs = attrs: builtins.hashString "md5" (builtins.toJSON attrs);
in
{
  config = lib.mkIf cfg.enable {
    kubernetes.resources.${cfg.namespace} = {
      # mounts to /nix/var/nix-csi/home/.ssh
      Secret.sshc = lib.mkIf cfg.cache.enable {
        stringData = {
          known_hosts = "nix-cache.${cfg.namespace}.svc ${builtins.readFile ../id_ed25519.pub}";
          id_ed25519 = builtins.readFile ../id_ed25519;
          config = # ssh
            ''
              Host nix-cache
                  HostName nix-cache.${cfg.namespace}.svc
                  User root
                  Port 22
                  IdentityFile ~/.ssh/id_ed25519
                  UserKnownHostsFile ~/.ssh/known_hosts
            '';
        };
      };

      DaemonSet.nix-csi-node = {
        spec = {
          updateStrategy = {
            type = "RollingUpdate";
            rollingUpdate.maxUnavailable = 1;
          };
          selector.matchLabels.app = "nix-csi-node";
          template = {
            metadata.labels.app = "nix-csi-node";
            metadata.annotations."kubectl.kubernetes.io/default-container" = "nix-csi-node";
            metadata.annotations.configHash = hashAttrs nsRes.ConfigMap.nix-config;
            metadata.annotations.scriptsHash = hashAttrs nsRes.ConfigMap.nix-scripts;
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
                nix-csi-node = {
                  # image = cfg.image;
                  image = "quay.io/nix-csi/scratch:1.0.1";
                  command = [ "dinit" ];
                  securityContext.privileged = true;
                  env = {
                    _namedlist = true;
                    NIX_CONFIG.value = "access-tokens = github.com=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";
                    BUILD_CACHE.value = lib.boolToString cfg.cache.enable;
                    CSI_ENDPOINT.value = "unix:///csi/csi.sock";
                    HOME.value = "/nix/var/nix-csi/home";
                    KUBE_NAMESPACE.valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    KUBE_NODE_NAME.valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    USER.value = "root";
                  };
                  volumeMounts = {
                    _namedlist = true;
                    csi-socket.mountPath = "/csi";
                    nix-config.mountPath = "/etc/nix";
                    nix-scripts.mountPath = "/scripts";
                    registration.mountPath = "/registration";
                    kubelet = {
                      mountPath = "/var/lib/kubelet";
                      mountPropagation = "Bidirectional";
                    };
                    nix-store = {
                      mountPath = "/nix";
                      mountPropagation = "Bidirectional";
                      subPath = "nix";
                    };
                  }
                  // (lib.optionalAttrs cfg.cache.enable {
                    sshc.mountPath = "/etc/sshc";
                  });
                };
                csi-node-driver-registrar = {
                  image = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.15.0";
                  args = [
                    "--v=5"
                    "--csi-address=/csi/csi.sock"
                    "--kubelet-registration-path=/var/lib/kubelet/plugins/nix.csi.store/csi.sock"
                  ];
                  env = [
                    {
                      name = "KUBE_NODE_NAME";
                      valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    }
                  ];
                  volumeMounts = {
                    _namedlist = true;
                    csi-socket.mountPath = "/csi";
                    kubelet.mountPath = "/var/lib/kubelet";
                    registration.mountPath = "/registration";
                  };
                };
                livenessprobe = {
                  image = "registry.k8s.io/sig-storage/livenessprobe:v2.17.0";
                  args = [ "--csi-address=/csi/csi.sock" ];
                  volumeMounts = {
                    _namedlist = true;
                    csi-socket.mountPath = "/csi";
                    registration.mountPath = "/registration";
                  };
                };
              };
              volumes = {
                _namedlist = true;
                nix-config.configMap.name = "nix-config";
                registration.hostPath.path = "/var/lib/kubelet/plugins_registry";
                nix-scripts.configMap = {
                  name = "nix-scripts";
                  defaultMode = 493; # 755
                };
                nix-store.hostPath = {
                  path = cfg.hostMountPath;
                  type = "DirectoryOrCreate";
                };
                csi-socket.hostPath = {
                  path = "/var/lib/kubelet/plugins/nix.csi.store/";
                  type = "DirectoryOrCreate";
                };
                kubelet.hostPath = {
                  path = "/var/lib/kubelet";
                  type = "Directory";
                };
              }
              // (lib.optionalAttrs cfg.cache.enable {
                sshc.secret.secretName = "sshc";
              });
            };
          };
        };
      };
    };
  };
}
