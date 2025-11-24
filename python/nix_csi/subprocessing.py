import logging
import shlex
import asyncio
import time
from typing import NamedTuple

from grpclib import GRPCError
from grpclib.const import Status

logger = logging.getLogger("nix-csi")


class SubprocessResult(NamedTuple):
    returncode: int
    stdout: str
    stderr: str
    combined: str
    elapsed: float


async def try_captured(*args):
    result = await run_captured(*args)
    if result.returncode != 0:
        raise GRPCError(
            Status.INTERNAL,
            f"{shlex.join([str(arg) for arg in args[:5]])}... failed: {result.returncode=}",
            result.combined
        )
    return result


async def try_console(*args, log_level: int = logging.DEBUG):
    result = await run_console(*args, log_level=log_level)
    if result.returncode != 0:
        raise GRPCError(
            Status.INTERNAL,
            f"{shlex.join([str(arg) for arg in args[:5]])}... failed: {result.returncode=}",
            result.combined
        )
    return result


# Run async subprocess, capture output and returncode
async def run_captured(*args):
    return await run_console(*args, log_level=logging.NOTSET)


# Run async subprocess, forward output to console and return returncode
async def run_console(*args, log_level: int = logging.DEBUG):
    start_time = time.perf_counter()
    log_command(*args, log_level=log_level)
    proc = await asyncio.create_subprocess_exec(
        *[str(arg) for arg in args],
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    stdout_data = []
    stderr_data = []
    combined_data = []

    async def stream_output(stream, buffer):
        async for line in stream:
            decoded = line.decode().strip()
            buffer.append(decoded)
            combined_data.append(decoded)
            logger.log(log_level, decoded)

    await asyncio.gather(
        stream_output(proc.stdout, stdout_data),
        stream_output(proc.stderr, stderr_data),
        proc.wait(),
    )
    elapsed_time = time.perf_counter() - start_time
    if elapsed_time > 5:
        logger.info(
            f"Comamnd executed in {elapsed_time} seconds: {shlex.join([str(arg) for arg in args[:5]])}"
        )

    assert proc.returncode is not None
    return SubprocessResult(
        proc.returncode,
        "\n".join(stdout_data).strip(),
        "\n".join(stderr_data).strip(),
        "\n".join(combined_data).strip(),
        elapsed_time,
    )


def log_command(*args, log_level: int):
    logger.log(
        log_level,
        f"Running command: {shlex.join([str(arg) for arg in args])}",
    )
