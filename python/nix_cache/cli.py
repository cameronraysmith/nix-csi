#! /usr/bin/env python3

import asyncio
import kr8s
import argparse
import logging
import textwrap
from pathlib import Path
from nix_csi.subprocessing import run_captured


async def update_config(namespace: str):
    """Fetches builder pod info and atomically updates the nix machines file."""
    try:
        builder_nodes = {
            node.name: node
            async for node in kr8s.asyncio.get(
                "nodes", label_selector="nix.csi/builder"
            )
        }

        if not builder_nodes:
            logging.info("No builder nodes found, preparing to clear machines file.")

        arch_map = {
            "amd64": "x86_64-linux",
            "arm64": "aarch64-linux",
        }

        builders = []
        async for pod in kr8s.asyncio.get(
            "pods", namespace=namespace, label_selector={"app": "nix-csi-node"}
        ):
            node_name = pod.spec.nodeName
            if node := builder_nodes.get(node_name):
                k8s_arch = node.metadata.labels.get("kubernetes.io/arch")
                if not k8s_arch:
                    logging.warning(
                        f"Node '{node_name}' missing 'kubernetes.io/arch' label. Skipping pod '{pod.name}'."
                    )
                    continue

                nix_arch = arch_map.get(k8s_arch)
                if not nix_arch:
                    logging.warning(
                        f"Unhandled architecture '{k8s_arch}' for node '{node_name}'. Skipping pod '{pod.name}'."
                    )
                    continue

                builders.append(
                    f"ssh-ng://{pod.metadata['name']}.nix-builders.nix-csi.svc.ksb.lillecarl.com?trusted=1 {nix_arch}"
                )

        machines_path = Path("/etc/nix/machines")
        temp_path = machines_path.with_suffix(".tmp")
        content = "".join(f"{builder}\n" for builder in builders)
        temp_path.write_text(content)
        temp_path.rename(machines_path)

        logging.info(
            f"Atomically updated {machines_path} with {len(builders)} builders."
        )

    except kr8s.NotFoundError:
        logging.warning("Resources not found, skipping update.")
    except Exception:
        logging.exception("An error occurred during update.")


async def async_main():
    namespace = "nix-csi"
    label_selector = {"app": "nix-csi-node"}

    privKey = Path("/nix/var/nix-csi/root/privkey")
    pubKey = privKey.with_suffix(".pub")
    if not privKey.exists():
        await run_captured(
            "ssh-keygen", "-t", "ed25519", "-f", privKey, "-N", "", "-C", "nix-csi"
        )

    stringData = {
        "id_ed25519": privKey.read_text(),
        "id_ed25519.pub": pubKey.read_text(),
        "known_hosts": f"* {pubKey.read_text()}",
        "config": textwrap.dedent(
            """
            Host *
                IdentityFile ~/.ssh/id_ed25519
                UserKnownHostsFile ~/.ssh/known_hosts
        """
        ),
        "authorized_keys": pubKey.read_text(),
        "sshd_config": textwrap.dedent(
            """
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
        """
        ),
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

    # No need to do this since watch will trigger added straight away for some reason
    # logging.info("Performing initial configuration update on startup.")
    # await update_config(namespace)

    logging.info(
        f"Watching for pod events in namespace '{namespace}' with selector '{label_selector}'..."
    )
    while True:
        try:
            async for event_type, obj in kr8s.asyncio.watch(
                "pods", namespace=namespace, label_selector=label_selector
            ):
                if event_type not in ["ADDED", "DELETED"]:
                    continue

                logging.info(
                    f"Pod event '{event_type}' for {obj.name}. Triggering update."
                )
                await update_config(namespace)

        except asyncio.CancelledError:
            logging.info("Main task cancelled, shutting down.")
            break
        except Exception:
            logging.exception("Kubernetes API watch error. Retrying in 15 seconds...")
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
        level=logging.INFO,
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )
    logging.getLogger("nix-csi").setLevel(getattr(logging, args.loglevel))

    try:
        asyncio.run(async_main())
    except KeyboardInterrupt:
        print("Interrupted by user.")


if __name__ == "__main__":
    main()
