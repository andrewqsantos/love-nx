#!/usr/bin/env python3
"""PC-side ENet peer for the love-nx acceptance test.

Usage:
    python3 pc_enet_peer.py server        # listen on :7777, expect the Switch to connect
    python3 pc_enet_peer.py client <ip>   # connect to the Switch at <ip>:7777

Either role sends "hello-from-pc" on connect, waits for a reply, and prints a
single verdict line. Requires: pip install pyenet-dlts
"""
import sys

try:
    import enet
except ImportError:
    sys.exit("pip install pyenet-dlts   # provides the 'enet' module")

PORT = 7777
MSG = b"hello-from-pc"


def pump(host, want_event, timeout_s=10.0):
    """Service until want_event arrives; returns the event or None."""
    import time
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        event = host.service(100)
        if event.type == want_event:
            return event
    return None


def run_server():
    host = enet.Host(enet.Address(b"0.0.0.0", PORT), 32, 2, 0, 0)
    print(f"listening on :{PORT} — start the Switch test app now", flush=True)
    event = pump(host, enet.EVENT_TYPE_CONNECT, 120.0)
    if not event:
        return fail("no connection within 120s")
    print(f"connect from {event.peer.address}", flush=True)
    event.peer.send(0, enet.Packet(MSG, enet.PACKET_FLAG_RELIABLE))
    event = pump(host, enet.EVENT_TYPE_RECEIVE, 10.0)
    if not event:
        return fail("no reply")
    print(f"receive: {event.packet.data!r}", flush=True)
    event.peer.send(0, enet.Packet(b"ack:" + event.packet.data, enet.PACKET_FLAG_RELIABLE))
    return ok()


def run_client(ip):
    host = enet.Host(None, 1, 2, 0, 0)
    peer = host.connect(enet.Address(ip.encode(), PORT), 2)
    event = pump(host, enet.EVENT_TYPE_CONNECT, 10.0)
    if not event:
        return fail(f"no connect to {ip}:{PORT}")
    print("connected", flush=True)
    peer.send(0, enet.Packet(MSG, enet.PACKET_FLAG_RELIABLE))
    event = pump(host, enet.EVENT_TYPE_RECEIVE, 10.0)
    if not event:
        return fail("no reply from Switch")
    print(f"receive: {event.packet.data!r}", flush=True)
    return ok()


def ok():
    print("VERDICT: PASS", flush=True)
    return 0


def fail(why):
    print(f"VERDICT: FAIL ({why})", flush=True)
    return 1


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "server":
        sys.exit(run_server())
    if len(sys.argv) == 3 and sys.argv[1] == "client":
        sys.exit(run_client(sys.argv[2]))
    sys.exit(__doc__)
