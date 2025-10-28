import asyncio
import logging
import os
import shutil
import socket
import tempfile
import math

from csi import csi_grpc, csi_pb2
from grpclib import GRPCError
from grpclib.const import Status
from grpclib.server import Server
from importlib import metadata
from pathlib import Path
from typing import List
from cachetools import TTLCache
from asyncio import Semaphore, sleep
from collections import defaultdict
from .identityservicer import IdentityServicer
from .copytocache import copyToCache
from .subprocessing import run_captured, run_console, try_captured, try_console
from .kubernetes import get_builder_ips

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


async def set_nix_path():
    NIX_PATH_LINK = CSI_ROOT / "NIX_PATH"
    NIX_PATH_LINK.parent.mkdir(parents=True, exist_ok=True)
    await try_console(
        "nix",
        "build",
        "--print-out-paths",
        "--file",
        "/etc/nix/nix-path.nix",
        "--out-link",
        NIX_PATH_LINK,
    )
    os.environ["NIX_PATH"] = NIX_PATH_LINK.read_text().strip()


class NodeServicer(csi_grpc.NodeBase):
    initialized = False
    system = "x86_64-linux"
    # Cache positive Nix commands
    packagePathCache: TTLCache[str, Path] = TTLCache(math.inf, 60)
    pathInfoCache: TTLCache[Path, List[str]] = TTLCache(math.inf, 60)
    # Locks that prevents the same expression to be processed in parallel
    expressionLock: defaultdict[str, Semaphore] = defaultdict(Semaphore)

    async def initialize(self):
        logger.info("Initializing NodeServicer")
        # Clean old volumes on startup
        reboot_cleanup()
        # Create directories we operate in
        CSI_ROOT.mkdir(parents=True, exist_ok=True)
        CSI_VOLUMES.mkdir(parents=True, exist_ok=True)
        CSI_GCROOTS.mkdir(parents=True, exist_ok=True)
        await set_nix_path()
        self.system = (
            await try_captured(
                "nix",
                "eval",
                "--raw",
                "--impure",
                "--expr",
                "builtins.currentSystem",
            )
        ).stdout
        logger.info("Initialized NodeServicer")
        self.initialized = True

    async def NodePublishVolume(self, stream):
        request: csi_pb2.NodePublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodePublishVolumeRequest is None")

        for i in range(120):
            if not self.initialized:
                await sleep(1)
        if not self.initialized:
            raise GRPCError(
                Status.INTERNAL, "NodeServicer not initialized within 120 seconds"
            )

        targetPath = Path(request.target_path)
        expression = request.volume_context.get("expression")
        storePath = request.volume_context.get(self.system)
        packagePath: Path = Path("/nonexistent/path/that/should/never/exist")
        gcPath = CSI_GCROOTS / request.volume_id

        if storePath is not None:
            packagePathCacheResult = self.packagePathCache.get(storePath)
            if packagePathCacheResult is not None and packagePathCacheResult.exists():
                packagePath = packagePathCacheResult
            else:
                packagePath = Path(storePath)
                logger.debug(f"{storePath=}")
                buildCommand = [
                    "nix",
                    "build",
                    "--extra-substituters",
                    "ssh-ng://nix@nix-cache?trusted=1&priority=20",
                    "--out-link",
                    gcPath,
                    packagePath,
                ]

                # Try reaching cache for substitution
                await try_captured(
                    "nix", "store", "ping", "--store", "ssh-ng://nix@nix-cache"
                )

                # Fetch storePath from caches
                await try_console(*buildCommand)
                if packagePath.exists():
                    self.packagePathCache[storePath] = packagePath

        elif expression is not None:
            async with self.expressionLock[expression]:
                with tempfile.NamedTemporaryFile(mode="w", suffix=".nix") as f:
                    expressionFile = Path(f.name)
                    f.write(expression)
                    f.flush()

                    packagePathCacheResult = self.packagePathCache.get(expression)
                    if (
                        packagePathCacheResult is not None
                        and packagePathCacheResult.exists()
                    ):
                        packagePath = packagePathCacheResult
                    else:
                        # eval expression to get storePath
                        eval = await try_captured(
                            "nix",
                            "eval",
                            "--raw",
                            "--impure",
                            "--expr",
                            f"(import {expressionFile} {{}}).outPath",
                        )
                        packagePath = Path(eval.stdout)
                        self.packagePathCache[expression] = packagePath
                        # Try fetching from cache
                        await run_captured("nix", "build", "--no-link", packagePath)

                    if not packagePath.exists():
                        buildCommand = [
                            "nix",
                            "build",
                            "--print-out-paths",
                            "--out-link",
                            gcPath,
                            "--file",
                            expressionFile,
                        ]

                        # Try reaching cache for substitution
                        try:
                            await try_captured(
                                "nix",
                                "store",
                                "ping",
                                "--store",
                                "ssh-ng://nix@nix-cache",
                            )
                            buildCommand += [
                                "--extra-substituters",
                                "ssh-ng://nix@nix-cache?trusted=1&priority=20",
                            ]
                        except Exception:
                            pass

                        reachable_builders = []
                        for ip in await get_builder_ips(NAMESPACE):
                            if ip == os.environ["KUBE_POD_IP"]:
                                continue
                            try:
                                await try_captured(
                                    "nix",
                                    "store",
                                    "ping",
                                    "--store",
                                    f"ssh-ng://nix@{ip}",
                                )
                                reachable_builders.append(
                                    f"ssh-ng://nix@{ip}?trusted=1"
                                )
                            except Exception:
                                pass
                        if len(reachable_builders) > 0:
                            buildCommand += ["--builders", ";".join(reachable_builders)]

                        # Update packagePath when we've built it, required to
                        # prevent impure derivations from never "finalizing"
                        packagePath = Path((await try_console(*buildCommand)).stdout.splitlines()[0])

                        if packagePath.exists():
                            self.packagePathCache[expression] = packagePath
        else:
            raise GRPCError(
                Status.INVALID_ARGUMENT,
                "Set either `expression` or `storePath` in volume attributes",
            )

        if not packagePath.exists():
            raise GRPCError(
                Status.INVALID_ARGUMENT,
                "packagePath passed through all build steps yet doesn't exist",
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

        if os.getenv("BUILD_CACHE") == "true":
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
    nodeServicer = NodeServicer()

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

    await server.start(sock=sock)
    logger.info(f"CSI driver (grpclib) listening on unix://{sock_path}")
    await nodeServicer.initialize()
    await server.wait_closed()
