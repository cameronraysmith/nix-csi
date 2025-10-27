{
  buildPythonApplication, # Builder
  hatchling, # Build system
  coreutils, # ln
  csi-proto-python, # CSI GRPC bindings
  gitMinimal, # Lix requires Git since it doesn't use libgit2
  kr8s, # Kubernetes API
  lix, # We need a Nix implementation.... :)
  nix_init_db, # Import from one nix DB to another
  openssh, # Copying to cache
  rsync, # hardlinking
  tenacity, # Retrying library
  util-linuxMinimal, # mount, umount
}:
let
  pyproject = builtins.fromTOML (builtins.readFile ./pyproject.toml);
in
buildPythonApplication {
  pname = pyproject.project.name;
  version = pyproject.project.version;
  src = ./.;
  pyproject = true;
  build-system = [ hatchling ];
  dependencies = [
    coreutils
    csi-proto-python
    gitMinimal
    kr8s
    lix
    nix_init_db
    openssh
    rsync
    tenacity
    util-linuxMinimal
  ];
  meta.mainProgram = "nix-csi";
}
