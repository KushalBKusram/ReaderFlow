#!/usr/bin/env python3
"""Throttling TCP proxy that simulates network outages by total bytes.

usage: dropproxy.py LISTEN_HOST LISTEN_PORT TARGET_HOST TARGET_PORT RATE_MBPS DROP_AT_MB[,..] OUTAGE_SECS

When the cumulative bytes sent target->client cross DROP_AT_MB[i], the
current connection is cut and every new connection is refused for
OUTAGE_SECS seconds. Logs byte counts and timing only, never payload.
"""
import socket, sys, threading, time

lh, lp, th, tp = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
rate = float(sys.argv[5]) * 1_000_000
drops = [int(float(x) * 1_000_000) for x in sys.argv[6].split(",") if x]
outage = float(sys.argv[7])
total = 0
next_drop = 0
outage_until = 0.0
lock = threading.Lock()
n = 0


def up(src, dst):
    try:
        while (d := src.recv(65536)):
            dst.sendall(d)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass


def handle(c, idx):
    global total, next_drop, outage_until
    if time.time() < outage_until:
        print(f"[conn {idx}] refused (outage, {outage_until-time.time():.1f}s left)", flush=True)
        c.close(); return
    try:
        s = socket.create_connection((th, tp))
    except OSError as e:
        print(f"[conn {idx}] target unreachable: {e}", flush=True); c.close(); return
    threading.Thread(target=up, args=(c, s), daemon=True).start()
    t0, sent = time.time(), 0
    try:
        while (d := s.recv(65536)):
            with lock:
                if next_drop < len(drops) and total + len(d) >= drops[next_drop]:
                    keep = max(0, drops[next_drop] - total)
                    c.sendall(d[:keep]); total += keep
                    print(f"[conn {idx}] DROP #{next_drop+1} at {total/1e6:.1f} MB total; outage {outage:.0f}s", flush=True)
                    next_drop += 1
                    outage_until = time.time() + outage
                    break
                total += len(d)
            c.sendall(d); sent += len(d)
            ahead = sent / rate - (time.time() - t0)
            if ahead > 0: time.sleep(ahead)
    except OSError as e:
        print(f"[conn {idx}] error: {e}", flush=True)
    finally:
        for x in (c, s):
            try: x.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            x.close()


srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((lh, lp)); srv.listen(64)
print(f"proxy {lh}:{lp} -> {th}:{tp} {rate/1e6:.0f} MB/s drops@{[d/1e6 for d in drops]} MB outage {outage}s", flush=True)
while True:
    c, _ = srv.accept()
    n += 1
    threading.Thread(target=handle, args=(c, n), daemon=True).start()
