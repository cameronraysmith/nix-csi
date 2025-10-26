{ config, lib, ... }:
let
  cfg = config.nix-csi;
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
            metadata.annotations.configHash = builtins.hashString "md5" (
              builtins.toJSON config.kubernetes.resources.${cfg.namespace}.ConfigMap.nix-config
            );
            spec = {
              serviceAccountName = "nix-csi";
              initContainers = [
                {
                  name = "initcopy";
                  image = cfg.image;
                  command = [ "initcopy" ];
                  volumeMounts = {
                    _namedlist = true;
                    init.mountPath = "/nix-volume";
                    nix-config.mountPath = "/etc/nix";
                  };
                }
              ];
              containers = {
                _namedlist = true;
                nix-csi-node = {
                  image = cfg.image;
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
                    registration.mountPath = "/registration";
                    kubelet = {
                      mountPath = "/var/lib/kubelet";
                      mountPropagation = "Bidirectional";
                    };
                    runtime = {
                      mountPath = "/nix";
                      mountPropagation = "Bidirectional";
                    };
                  }
                  // (lib.optionalAttrs cfg.cache.enable {
                    name = "sshc";
                    mountPath = "/etc/sshc";
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
                init.hostPath = {
                  path = cfg.hostMountPath;
                  type = "DirectoryOrCreate";
                };
                runtime.hostPath = {
                  path = "${cfg.hostMountPath}/nix";
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
                registration.hostPath.path = "/var/lib/kubelet/plugins_registry";
                nix-config.configMap.name = "nix-config";
              }
              // (lib.optionalAttrs cfg.cache.enable {
                name = "sshc";
                secret.secretName = "sshc";
              });
            };
          };
        };
      };
    };
  };
}
