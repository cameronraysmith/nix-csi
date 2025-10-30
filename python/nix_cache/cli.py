#! /usr/bin/env python3

import asyncio
import kr8s
import time
import argparse
import logging
import textwrap
from pathlib import Path
from nix_csi.subprocessing import run_captured, run_console


async def update_config(namespace: str):
    """Fetches IPs and performs the update action."""
    print("Debounce timer finished. Fetching IPs and updating config...")
    try:
        # 1. Get nodes with the specific label directly from the API
        builder_nodes = {
            node.name
            async for node in kr8s.asyncio.get(
                "nodes", label_selector="nix.csi/builder"
            )
        }

        if not builder_nodes:
            print("No builder nodes found.")
            return

        # 2. Get relevant pods and filter them
        builder_ips = [
            pod.status.podIP
            async for pod in kr8s.asyncio.get(
                "pods", namespace=namespace, label_selector={"app": "nix-csi-node"}
            )
            if pod.spec.nodeName in builder_nodes and pod.status.podIP
        ]

        print(f"Discovered builder IPs: {builder_ips}")

        machines_path = Path("/etc/nix/machines")
        content = "".join(f"nix@{ip}?trusted=1\n" for ip in builder_ips)
        machines_path.write_text(content)
        await run_captured("dinitctl", "restart", "nix-daemon")
    except kr8s.NotFoundError:
        print("Resources not found, skipping update.")
    except Exception as e:
        print(f"An error occurred during update: {e}")


async def async_main():
    namespace = "nix-csi"
    label_selector = {"app": "nix-csi-node"}
    debounce_task = None
    first_event_time = None
    debounce_delay = 5  # seconds
    max_debounce_wait = 60  # seconds

    privKey = Path("/nix/var/nix-csi/root/privkey")
    pubKey = privKey.with_suffix(".pub")
    if not privKey.exists():
        await run_captured(
            "ssh-keygen", "-t", "ed25519", "-f", privKey, "-N", "", "-C", "nix-csi"
        )

    stringData = {
        # Keys
        "id_ed25519": privKey.read_text(),
        "id_ed25519.pub": pubKey.read_text(),
        # Client config
        "known_hosts": f"* {pubKey.read_text()}",
        "config": textwrap.dedent("""
            Host *
                IdentityFile ~/.ssh/id_ed25519
                UserKnownHostsFile ~/.ssh/known_hosts
        """),
        # Server config
        "authorized_keys": pubKey.read_text(),
        "sshd_config": textwrap.dedent("""
            Port 22
            AddressFamily Any

            HostKey /etc/ssh/id_ed25519

            SyslogFacility DAEMON
            SetEnv PATH=/nix/var/result/bin
            SetEnv NIXPKGS_ALLOW_UNFREE=1

            PermitRootLogin no
            PubkeyAuthentication yes
            PasswordAuthentication no
            ChallengeResponseAuthentication no
            UsePAM no

            AuthorizedKeysFile %h/.ssh/authorized_keys

            StrictModes no

            Subsystem sftp internal-sftp
        """),
    }

    secret_manifest = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": "ssh", "namespace": namespace},
        "stringData": stringData,
        "type": "Opaque",
    }
    secret = await kr8s.asyncio.objects.Secret(secret_manifest)

    if await secret.exists():
        await secret.patch({"stringData": stringData})
    else:
        await secret.create()

    while True:
        try:
            async for event in kr8s.asyncio.watch(
                "pods", namespace=namespace, label_selector=label_selector
            ):
                if event[0] not in ["ADDED", "DELETED"]:
                    continue

                now = time.monotonic()

                if first_event_time is None:
                    first_event_time = now

                if debounce_task:
                    debounce_task.cancel()

                # Force execution if max wait time is exceeded
                if now - first_event_time >= max_debounce_wait:
                    print(
                        f"Max debounce time of {max_debounce_wait}s reached. Forcing update."
                    )
                    await update_config(namespace)
                    # Reset state for the next series of events
                    first_event_time = None
                    debounce_task = None
                    continue

                # Otherwise, schedule the normal debounced update
                print(
                    f"Pod event '{event[0]}' detected for {event[1].name}. Resetting debounce timer."
                )

                async def debounced_run():
                    nonlocal first_event_time, debounce_task
                    try:
                        await asyncio.sleep(debounce_delay)
                        await update_config(namespace)
                        # Reset state after a successful debounced run
                        first_event_time = None
                        debounce_task = None
                    except asyncio.CancelledError:
                        # This is expected if another event arrives
                        pass

                debounce_task = asyncio.create_task(debounced_run())

        except asyncio.CancelledError:
            print("Main task cancelled, shutting down.")
            break
        except Exception as e:
            print(f"Kubernetes API error: {e}. Retrying in 15 seconds...")
            # Reset state on error to avoid stale timers after reconnect
            if debounce_task:
                debounce_task.cancel()
            debounce_task = None
            first_event_time = None
            await asyncio.sleep(15)


def parse_args():
    parser = argparse.ArgumentParser(description="nix CSI driver")
    parser.add_argument(
        "--loglevel",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="Set the logging level (default: INFO)",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    logging.basicConfig(
        level=logging.WARN,
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )
    logger = logging.getLogger("nix-csi")
    loglevel_str = logging.getLevelName(logger.getEffectiveLevel())
    logger.info(f"Current log level: {loglevel_str}")

    logging.getLogger("nix-csi").setLevel(getattr(logging, args.loglevel))
    try:
        asyncio.run(async_main())
    except KeyboardInterrupt:
        print("Interrupted by user.")


if __name__ == "__main__":
    main()
