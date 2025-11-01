# nix-csi
nix-csi implements a CSI driver that populates a volume with the result of a nix expression

AKA: A nix-snapshotter clone implemented on the CSI layer rather than the CRI layer.

# Alpha software
If you're curious about actually using this, please visit [cloud native
nix](https://matrix.to/#/!VhbWwlUdjHkamKnfrK:nixos.org?via=nixos.org&via=matrix.
org&via=nixos.dev) or hit me up directly at @lillecarl:matrix.org. I'm keen to
hand-hold and learn from anyone who isn't localhost :))

## How to deploy

```bash
# Build manifest
CSINS=nix-csi nix build --file . manifestYAML
# Inspect manifest
kubectl apply -f result
```

## Highlevel design
nix-csi is a [CSI](https://github.com/container-storage-interface/spec)
implementation that implements ephemeral volumes consisting of a fully functional
/nix folder with store, database and everything required to run NixOS(privileged),
nixNG (unprivileged) or exactly anything else that you've packaged with Nix
in Kubernetes (or another CSI compatible scheduler/orchestrator thingy like Nomad
(PR's welcome)).

nix-csi is a glorified script runner that does the following:
* nix eval
* nix build
* nix path-info (get closure)
* rsync (hardlinkgs)
* mount
This explanation can be simplified as: nix copy --to /somewhere but with
hardlinks instead of dumb read copying which is nice.

The mount calls will be either bind or overlayfs depending on if you're mounting
RO or RW. The benefit of hardlinks and bind-mounts is that inodes are shared all
the way meaning that your processes share page-cache for applications resulting
in lower memory usage than running normal docker images.

OverlayFS gives similar storage savings but without page-cache sharing.


## nix-csi as a build cluster
Since nix-daemon supports building ofc nix-csi does too. You just need to set
up your root ssh config appropriately:
```ssh
Host nixcachelbip
  User nix
  IdentityFile /tmp/id_ed25519
Host *.nix-builders.namespace.svc.cluster.local
  HostName %h
  User nix
  IdentityFile /tmp/id_ed25519
  ProxyJump nixcachelbip
  HostKeyAlias nix-csi-builder
  StrictHostKeyChecking accept-new
```
And then you run ```scp nixcachelbip:/etc/nix/machines ./machines && nix build --max-jobs 0 --builders @$PWD/machines nixpkgs#hello```

## Beware
And beware of bugs and unfinished sandwiches.

## TODO:
* Testing (no unittests and mocking bogus)
* Implement some kind of central binary cache
* Examples
* Support different Nix versions
