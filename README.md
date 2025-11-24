# nix-csi

Mount /nix into Kubernetes pods using the CSI Ephemeral Volume feature. Volumes
share lifetime with Pods and are embedded into the Podspec.

## Deploying

```nix
nix run --file . kubenixEval.deploymentScript -- --yes --prune
```
