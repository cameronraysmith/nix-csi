{ config, lib, ... }:
let
  cfg = config.nix-csi;
in
{
  config = lib.mkIf cfg.enable {
    kubernetes.resources.${cfg.namespace} = {
      ServiceAccount.nix-csi = { };

      ClusterRole.nix-csi = {
        rules = [
          {
            # Read-only access to Pods and their logs in the core API group.
            apiGroups = [ "" ];
            resources = [
              "nodes"
              "pods"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
        ];
      };

      # Binds the Role to the ServiceAccount.
      ClusterRoleBinding.nix-csi = {
        subjects = [
          {
            kind = "ServiceAccount";
            name = "nix-csi";
            namespace = cfg.namespace;
          }
        ];
        roleRef = {
          kind = "ClusterRole";
          name = "nix-csi";
          apiGroup = "rbac.authorization.k8s.io";
        };
      };
    };
  };
}
