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
and stuff the result into

## Deploying workloads

TODO, but essentially stick a storePath in volumeAttributes like [this](https://github.com/Lillecarl/hetzkube/blob/4ed76ec77bfb104d1c2307b1ba178efa61dd34e2/kubenix/modules/cheapam.nix#L113)

