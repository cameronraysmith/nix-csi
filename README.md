# nix-csi

Mount /nix into Kubernetes pods using the CSI Ephemeral Volume feature. Volumes
share lifetime with Pods and are embedded into the Podspec.

## Deploying nix-csi

Stick your pubkeys in ./keys and they will be imported into the module system
then run the following command and you'll have nix-csi deployed.
```nix
nix run --file . kubenixEval.deploymentScript -- --yes --prune
```

## Deploying workloads

TODO

