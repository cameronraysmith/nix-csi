# Project Notes

## Version Control
- **Always use Jujutsu (jj) instead of Git** for version control operations
- Common commands:
  - `jj status` - Check working copy status
  - `jj diff` - View changes
  - `jj commit -m "message"` - Create a commit
  - `jj log` - View commit history

## Building
- **Build and verify all environments:**
  ```bash
  nix build --builders "eu.nixbuild.net aarch64-linux; eu.nixbuild.net x86_64-linux" --file . push --no-link
  ```
  This builds both cache and node environments for x86_64-linux and aarch64-linux architectures.

## Project Structure
- `environments/` - Nix-built environments (previously `container/`)
  - `cache/` - Cache environment configuration
  - `node/` - Node/CSI environment configuration
- `kubenix/` - Kubernetes deployment configurations
- `python/` - Python services (nix-csi, nix-cache, nix-timegc)
- `pkgs/` - Custom Nix packages
