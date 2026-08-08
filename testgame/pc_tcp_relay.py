#!/usr/bin/env python3
"""PC-side TCP newline echo for the love-nx acceptance test.

Usage:
    python3 pc_tcp_relay.py [port]

Listens on 0.0.0.0:port (default 7778), accepts one connection, reads one
newline-delimited line, replies with ack:<line>\\n, then exits.
"""
import socket
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7778


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT))
    srv.listen(1)
    srv.settimeout(120.0)
    print(f"listening on :{PORT} — start the Switch tcp pc relay check now", flush=True)
    try:
        conn, addr = srv.accept()
    except socket.timeout:
        print("VERDICT: FAIL (no connection within 120s)", flush=True)
        return 1
    print(f"connect from {addr}", flush=True)
    conn.settimeout(10.0)
    buf = b""
    try:
        while b"\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        print("VERDICT: FAIL (receive timeout)", flush=True)
        conn.close()
        return 1
    line = buf.split(b"\n", 1)[0]
    print(f"receive: {line!r}", flush=True)
    reply = b"ack:" + line + b"\n"
    conn.sendall(reply)
    conn.close()
    srv.close()
    print("VERDICT: PASS", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
