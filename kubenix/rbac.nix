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
          {
            apiGroups = [ "" ];
            resources = [
              "secrets"
            ];
            verbs = [
              "get"
              "list"
              "create"
              "patch"
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
