import asyncio
import logging
import os
import shutil
import socket
import math
import subprocess

from csi import csi_grpc, csi_pb2
from grpclib import GRPCError
from grpclib.const import Status
from grpclib.server import Server
from importlib import metadata
from pathlib import Path
from typing import List
from cachetools import TTLCache
from asyncio import Semaphore
from collections import defaultdict
from .identityservicer import IdentityServicer
from .copytocache import copyToCache
from .subprocessing import run_captured, run_console, try_captured, try_console

logger = logging.getLogger("nix-csi")

CSI_PLUGIN_NAME = "nix.csi.store"
CSI_VENDOR_VERSION = metadata.version("nix-csi")

MOUNT_ALREADY_MOUNTED = 32

# Paths we base everything on.
# Remember that these are CSI pod paths not node paths.
NIX_ROOT = Path("/")
CSI_ROOT = NIX_ROOT / "nix/var/nix-csi"
CSI_VOLUMES = CSI_ROOT / "volumes"
CSI_GCROOTS = NIX_ROOT / "nix/var/nix/gcroots/nix-csi"
NAMESPACE = os.environ["KUBE_NAMESPACE"]

RSYNC_CONCURRENCY = Semaphore(1)


def get_kernel_boot_time(stat_file: Path = Path("/proc/stat")) -> int:
    """Returns kernel boot time as Unix timestamp."""
    for line in stat_file.read_text().splitlines():
        if line.startswith("btime "):
            return int(line.split()[1].strip())
    raise RuntimeError("btime not found in /hoststat")


def reboot_cleanup():
    """Cleanup volume trees and gcroots if we have rebooted"""
    stat_file = Path("/proc/stat")
    state_file = CSI_ROOT / "proc_stat"
    state_file.parent.mkdir(parents=True, exist_ok=True)

    needs_cleanup = False
    if state_file.exists():
        try:
            old_boot = get_kernel_boot_time(state_file)
            current_boot = get_kernel_boot_time(stat_file)
            needs_cleanup = old_boot != current_boot
        except RuntimeError:
            # Corrupted state file, treat as needing cleanup
            needs_cleanup = True

    shutil.copy2(stat_file, state_file)

    if needs_cleanup:
        logger.info("Reboot detected - cleaning volumes and gcroots")
        for path in [CSI_VOLUMES, CSI_GCROOTS]:
            if path.exists():
                shutil.rmtree(path)
                path.mkdir(parents=True, exist_ok=True)

def get_current_system():
    cmd = ["nix", "eval", "--raw", "--impure", "--expr", "builtins.currentSystem"]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return result.stdout.strip()

def initialize():
    logger.info("Initializing NodeServicer")
    # Clean old volumes on startup
    reboot_cleanup()
    # Create directories we operate in
    CSI_ROOT.mkdir(parents=True, exist_ok=True)
    CSI_VOLUMES.mkdir(parents=True, exist_ok=True)
    CSI_GCROOTS.mkdir(parents=True, exist_ok=True)



class NodeServicer(csi_grpc.NodeBase):
    # Cache positive Nix commands
    pathInfoCache: TTLCache[Path, List[str]] = TTLCache(math.inf, 60)
    volumeLocks: defaultdict[str, Semaphore] = defaultdict(Semaphore)

    def __init__(self, system: str):
        self.system = system

    async def NodePublishVolume(self, stream):
        request: csi_pb2.NodePublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodePublishVolumeRequest is None")

        async with self.volumeLocks[request.volume_id]:
            targetPath = Path(request.target_path)
            storePath = request.volume_context.get(self.system)
            packagePath: Path = Path("/nonexistent/path/that/should/never/exist")
            gcPath = CSI_GCROOTS / request.volume_id

            if storePath is not None:
                packagePath = Path(storePath)
                if not packagePath.exists():
                    logger.debug(f"{storePath=}")
                    buildCommand = [
                        "nix",
                        "build",
                        # TODO: Be less opinionated
                        "--extra-substituters",
                        "ssh-ng://nix@nix-cache?trusted=1&priority=20",
                        "--out-link",
                        gcPath,
                        packagePath,
                    ]

                    # Fetch storePath from caches
                    await try_console(*buildCommand)
            else:
                raise GRPCError(
                    Status.INVALID_ARGUMENT,
                    f"Volume doesn't have storePath configured for {self.system}",
                )

            if not packagePath.exists():
                raise GRPCError(
                    Status.INVALID_ARGUMENT,
                    "packagePath passed through all steps yet doesn't exist",
                )

            # Root directory for volume. Contains /nix, also contains "workdir" and
            # "upperdir" if we're doing overlayfs
            volumeRoot = CSI_VOLUMES / request.volume_id
            # Capitalized to emphasise they're Nix environment variables
            NIX_STATE_DIR = volumeRoot / "nix/var/nix"
            # Create NIX_STATE_DIR where database will be initialized
            NIX_STATE_DIR.mkdir(parents=True, exist_ok=True)

            # Get closure
            paths = []
            pathInfoCacheResult = self.pathInfoCache.get(packagePath)
            if pathInfoCacheResult is not None:
                paths = pathInfoCacheResult
            else:
                pathInfo = await try_captured(
                    "nix",
                    "path-info",
                    "--recursive",
                    packagePath,
                )
                paths = pathInfo.stdout.splitlines()
                self.pathInfoCache[packagePath] = paths

            try:
                # This try block is essentially nix copy into a chroot store with
                # extra steps. (Hardlinking instead of dumbcopying)

                # Install CSI gcroots
                await try_captured("nix", "build", "--out-link", gcPath, packagePath)

                # Copy closure to substore, rsync saves a lot of implementation
                # headache here. --archive keeps all attributes, --hard-links
                # hardlinks everything hardlinkable.
                async with RSYNC_CONCURRENCY:
                    await try_captured(
                        "rsync",
                        "--one-file-system",
                        "--recursive",
                        "--links",
                        "--hard-links",
                        "--mkpath",
                        # "--archive",
                        *paths,
                        volumeRoot / "nix/store",
                    )

                # Create Nix database
                # This is an execline script that runs nix-store --dump-db | NIX_STATE_DIR=something nix-store --load-db
                await try_captured(
                    "nix_init_db",
                    NIX_STATE_DIR,
                    *paths,
                )

                # install gcroots in container using chroot store
                # TODO: Check if this is still needed when using chroot store
                # into /nix/var/result from below
                await try_captured(
                    "nix",
                    "build",
                    "--store",
                    volumeRoot,
                    "--out-link",
                    NIX_STATE_DIR / "gcroots/result",
                    packagePath,
                )

                # install /nix/var/result in container using chroot store
                await try_captured(
                    "nix",
                    "build",
                    "--store",
                    volumeRoot,
                    "--out-link",
                    volumeRoot / "nix/var/result",
                    packagePath,
                )
            except Exception as ex:
                # Remove gcroots if we failed something else
                gcPath.unlink(missing_ok=True)
                # Remove what we were working on
                shutil.rmtree(volumeRoot, True)
                raise ex

            targetPath.mkdir(parents=True, exist_ok=True)
            mountCommand = []
            if request.readonly:
                # For readonly we use a bind mount, the benefit is that different
                # container stores using bindmounts will get the same inodes and
                # share page cache with others, reducing memory usage.
                mountCommand = [
                    "mount",
                    "--verbose",
                    "--bind",
                    "-o",
                    "ro",
                    volumeRoot / "nix",
                    targetPath,
                ]
            else:
                # For readwrite we use an overlayfs mount, the benefit here is that
                # it works as CoW even if the underlying filesystem doesn't support
                # it, reducing host storage usage.
                workdir = volumeRoot / "workdir"
                upperdir = volumeRoot / "upperdir"
                workdir.mkdir(parents=True, exist_ok=True)
                upperdir.mkdir(parents=True, exist_ok=True)
                mountCommand = [
                    "mount",
                    "--verbose",
                    "-t",
                    "overlay",
                    "overlay",
                    "-o",
                    f"rw,lowerdir={volumeRoot / 'nix'},upperdir={upperdir},workdir={workdir}",
                    targetPath,
                ]

            mount = await run_console(*mountCommand)
            if mount.returncode == MOUNT_ALREADY_MOUNTED:
                logger.debug(f"Mount target {targetPath} was already mounted")
            elif mount.returncode != 0:
                raise GRPCError(
                    Status.INTERNAL,
                    f"Failed to mount {mount.returncode=} {mount.stderr=}",
                )

            reply = csi_pb2.NodePublishVolumeResponse()
            await stream.send_message(reply)

            asyncio.create_task(copyToCache(packagePath))

    async def NodeUnpublishVolume(self, stream):
        request: csi_pb2.NodeUnpublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeUnpublishVolumeRequest is None")

        errors = []
        targetPath = Path(request.target_path)

        # Check if mounted first
        check = await run_captured("mountpoint", "--quiet", targetPath)
        if check.returncode == 0:
            umount = await run_console("umount", "--verbose", targetPath)
            if umount.returncode != 0:
                errors.append(f"umount failed {umount.returncode=} {umount.stderr=}")

        gcPath = CSI_GCROOTS / request.volume_id
        if gcPath.exists():
            try:
                gcPath.unlink()
            except Exception as ex:
                errors.append(f"gcroot unlink failed: {ex}")

        volume_path = CSI_VOLUMES / request.volume_id
        if volume_path.exists():
            try:
                shutil.rmtree(volume_path)
            except Exception as ex:
                errors.append(f"volume cleanup failed: {ex}")

        if errors:
            raise GRPCError(Status.INTERNAL, "; ".join(errors))

        reply = csi_pb2.NodeUnpublishVolumeResponse()
        await stream.send_message(reply)

    async def NodeGetCapabilities(self, stream):
        request: csi_pb2.NodeGetCapabilitiesRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeGetCapabilitiesRequest is None")
        reply = csi_pb2.NodeGetCapabilitiesResponse(capabilities=[])
        await stream.send_message(reply)

    async def NodeGetInfo(self, stream):
        request: csi_pb2.NodeGetInfoRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeGetInfoRequest is None")
        reply = csi_pb2.NodeGetInfoResponse(
            node_id=str(os.environ.get("KUBE_NODE_NAME")),
        )
        await stream.send_message(reply)

    async def NodeGetVolumeStats(self, stream):
        del stream  # typechecker
        raise GRPCError(Status.UNIMPLEMENTED, "NodeGetVolumeStats not implemented")

    async def NodeExpandVolume(self, stream):
        del stream  # typechecker
        raise GRPCError(Status.UNIMPLEMENTED, "NodeExpandVolume not implemented")

    async def NodeStageVolume(self, stream):
        del stream  # typechecker
        raise GRPCError(Status.UNIMPLEMENTED, "NodeStageVolume not implemented")

    async def NodeUnstageVolume(self, stream):
        del stream  # typechecker
        raise GRPCError(Status.UNIMPLEMENTED, "NodeUnstageVolume not implemented")


async def serve():
    sock_path = "/csi/csi.sock"
    Path(sock_path).unlink(missing_ok=True)

    identityServicer = IdentityServicer()
    nodeServicer = NodeServicer(get_current_system())

    server = Server(
        [
            identityServicer,
            nodeServicer,
        ]
    )

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(sock_path)
    sock.listen(128)
    sock.setblocking(False)

    initialize()
    await server.start(sock=sock)
    logger.info(f"CSI driver (grpclib) listening on unix://{sock_path}")
    await server.wait_closed()
