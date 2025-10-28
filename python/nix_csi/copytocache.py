import logging
from collections import defaultdict
from pathlib import Path
from asyncio import Semaphore, sleep
from .subprocessing import run_captured, run_console

logger = logging.getLogger("nix-csi")

# Locks that prevent the same derivation to be uploaded in parallel
copyLock: defaultdict[Path, Semaphore] = defaultdict(Semaphore)


async def copyToCache(packagePath: Path):
    # Only run one copy per path per time
    async with copyLock[packagePath]:
        paths = [str(packagePath)]
        # Get all paths recursively++
        pathInfoDrv = await run_captured(
            "nix",
            "path-info",
            "--recursive",
            "--derivation",
            packagePath,
        )
        if pathInfoDrv.returncode == 0:
            paths += pathInfoDrv.stdout.splitlines()

        # Unique the paths since we're running path-info twice
        paths = list(set(paths))
        # Filter derivation files
        paths = {p for p in paths if not p.endswith(".drv")}
        if len(paths) > 0:
            for _ in range(6):
                await sleep(5)
                nixCopy = await run_captured(
                    "nix", "copy", "--to", "ssh-ng://nix@nix-cache", *paths
                )
                if nixCopy.returncode == 0:
                    logger.debug(nixCopy.combined)
                    break
                await sleep(5)
