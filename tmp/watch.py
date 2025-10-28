#! /usr/bin/env python3

import asyncio
import kr8s
import time


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
        # TODO: Render configuration file and restart service here
    except kr8s.NotFoundError:
        print("Resources not found, skipping update.")
    except Exception as e:
        print(f"An error occurred during update: {e}")


async def main():
    namespace = "nix-csi"
    label_selector = {"app": "nix-csi-node"}
    debounce_task = None
    first_event_time = None
    debounce_delay = 5  # seconds
    max_debounce_wait = 60  # seconds

    print("Performing initial IP fetch on startup...")
    await update_config(namespace)

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


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("Interrupted by user.")
