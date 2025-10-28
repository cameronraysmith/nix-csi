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
          known_hosts = ''
            nix-cache ${builtins.readFile ../id_ed25519.pub}
            * ${builtins.readFile ../id_ed25519.pub}
          '';
          id_ed25519 = builtins.readFile ../id_ed25519;
          config = # ssh
            ''
              Host nix-cache
                  HostName nix-cache
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
            metadata.annotations.configHash = hashAttrs nsRes.ConfigMap.nix-cache-config;
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
                  image = "quay.io/nix-csi/scratch:1.0.1";
                  command = [
                    "dinit"
                    "csi"
                  ];
                  securityContext.privileged = true;
                  env = {
                    _namedlist = true;
                    BUILD_CACHE.value = lib.boolToString cfg.cache.enable;
                    CSI_ENDPOINT.value = "unix:///csi/csi.sock";
                    HOME.value = "/nix/var/nix-csi/root";
                    KUBE_NAMESPACE.valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    KUBE_NODE_NAME.valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    KUBE_POD_IP.valueFrom.fieldRef.fieldPath = "status.podIP";
                    USER.value = "root";
                  }
                  // lib.optionalAttrs (lib.stringLength (builtins.getEnv "GITHUB_KEY") > 0) {
                    NIX_CONFIG.value = "access-tokens = github.com=${builtins.getEnv "GITHUB_KEY"}";
                  };
                  volumeMounts = {
                    _namedlist = true;
                    csi-socket.mountPath = "/csi";
                    nix-config.mountPath = "/etc/nix";
                    registration.mountPath = "/registration";
                    sshd.mountPath = "/etc/ssh-mount";
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
                nix-config.configMap.name = "nix-csi-config";
                registration.hostPath.path = "/var/lib/kubelet/plugins_registry";
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
        };
      };
    };
  };
}
