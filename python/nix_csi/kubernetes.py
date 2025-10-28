#! /usr/bin/env python3

import kr8s


async def get_builder_ips(namespace: str) -> list[str]:
    candidate_nodes = []
    nodes = kr8s.asyncio.get("nodes")
    # Get all builder tagged nodes
    async for node in nodes:
        try:
            node.metadata["labels"]["nix.csi/builder"]
            candidate_nodes.append(node.name)
        except KeyError:
            pass

    builder_ips = []
    pods = kr8s.asyncio.get(
        "pods", namespace=namespace, label_selector={"app": "nix-csi-node"}
    )
    async for pod in pods:
        try:
            nodeName = pod.spec["nodeName"]
            if nodeName in candidate_nodes:
                builder_ips.append(pod.status["podIP"])
        except KeyError:
            pass

    return builder_ips
