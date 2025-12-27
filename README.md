# nix-csi

Mount /nix into Kubernetes pods using the CSI Ephemeral Volume feature. Volumes
share lifetime with Pods and are embedded into the Podspec.

## Deploying nix-csi

Stick your pubkeys in ./keys and they will be imported into the module system
then run the following command and you'll have nix-csi deployed.
```bash
nix run --file . kubenixEval.deploymentScript -- --yes --prune
```

If you'd rather mangle YAML yourself you can use
```bash
nix build --file . easykubenix.manifestYAMLFile
```
and stuff the result into Kustomize, a blender or your Kubernetes cluster

## Deploying workloads

* [multi-system example](https://github.com/Lillecarl/hetzkube/blob/4ed76ec77bfb104d1c2307b1ba178efa61dd34e2/kubenix/modules/cheapam.nix#L113)
* [single-system ci example(s)](https://github.com/Lillecarl/nix-csi/blob/3179e5f8383e760bbef313300a224e44f18722c7/kubenix/ci/default.nix)
* YAML example, because YAML is....cool
```yaml
volumeAttributes:
  # Pull storePath without eval, prio 1
  x86_64-linux: /nix/store/hello-......
  aarch64-linux: /nix/store/hello-......
  # Evaluates and builds flake, prio 2
  flakeRef: github:nixos/nixpkgs/nixos-unstable#hello
  # Evaluates and builds expression, prio 3
  nixExpr: |
    let
      nixpkgs = builtins.fetchTree {
        type = "github";
        owner = "nixos";
        repo = "nixpkgs";
        ref = "nixos-unstable";
      };
      pkgs = import nixpkgs { };
    in
    pkgs.hello
```
You can specify all these options but the first successful one by priority wins

