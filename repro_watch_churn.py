#!/usr/bin/env python3
"""
Reproduce the GPUStack v2.2.1 watch-stream churn / event-loop degradation.

Background
----------
The admin Web UI keeps 4 SSE "watch" streams open for the models dashboard:
    GET /v2/models?watch=true
    GET /v2/model-instances?watch=true
    GET /v2/model-files?watch=true
    GET /v2/inference-backends?watch=true

In the field these streams are torn down at the transport layer roughly every
~5s and the UI immediately reconnects (~1 reconnect / 5s / stream). That churn
is harmless on v2.1.2, but on v2.2.1 the streaming generator swallows
asyncio.CancelledError (`except CancelledError: pass`). Combined with the v2.2
event-bus rewrite (blocking backpressure + one spawned task per subscriber +
coordinator) and Starlette's BaseHTTPMiddleware task group, every abrupt
disconnect corrupts the cancellation state and leaks DB connections.

This script accelerates that churn: N virtual clients each loop
    open watch stream -> read the snapshot -> hold briefly -> ABORT the socket
so the server generator is cancelled while suspended in subscriber.receive().

What to watch on the SERVER logs
--------------------------------
    - "subscribed, source=streaming ..."  (should flood, matching the field logs)
    - "athrow(): asynchronous generator is already running"
    - "non-checked-in connection" / "Exception terminating connection"
    - "Unhandled exception in request GET /v2/..." with asyncpg CancelledError
    - rising latency, then QueuePool timeout, then the process restarts

Usage
-----
    pip install aiohttp
    export GPUSTACK_URL=https://<server>[:port]

    # auth via token (bearer / api-key)
    export GPUSTACK_TOKEN=<admin api key or bearer/session token>
    python repro_watch_churn.py --clients 60 --duration 600

    # auth via session cookie (login as admin, like the Web UI)
    python repro_watch_churn.py --admin-password <pw> --clients 60 --duration 600

    # harsher: also fire aborted plain (non-watch) list GETs to hit the
    # asyncpg-connect-cancelled -> pool-leak path directly
    python repro_watch_churn.py --clients 60 --list-abort 20 --duration 600
"""

import argparse
import asyncio
import contextlib
import os
import ssl
import sys
import time

try:
    import aiohttp
except ImportError:
    sys.exit("aiohttp required: pip install aiohttp")

WATCH_PATHS = [
    "/v2/models",
    "/v2/model-instances",
    "/v2/model-files",
    "/v2/inference-backends",
]

SESSION_COOKIE = "gpustack_session"

# churn backends are named "<PREFIX><RUN_ID>-<worker>-<n>-custom"; the per-run
# RUN_ID keeps names unique across re-runs so leftovers can't cause 409s.
CHURN_PREFIX = "zzz-repro-churn-"
RUN_ID = f"{os.getpid():x}"


async def login_for_cookie(base, username, password, ssl_ctx):
    """Log in like the Web UI (POST /auth/login) and return the
    gpustack_session JWT cookie value. Auth (argon2) runs once here instead
    of on every request, matching how an admin browser session works."""
    url = f"{base}/auth/login"
    timeout = aiohttp.ClientTimeout(total=30)
    async with aiohttp.ClientSession(timeout=timeout) as s:
        async with s.post(
            url, data={"username": username, "password": password}, ssl=ssl_ctx
        ) as r:
            body = await r.text()
            if r.status != 200:
                sys.exit(f"login failed: HTTP {r.status}: {body[:200]}")
            morsel = r.cookies.get(SESSION_COOKIE)
            if morsel is None:
                sys.exit(
                    "login succeeded but no gpustack_session cookie was set; "
                    "check the server URL/scheme"
                )
            return morsel.value

# Hold-time buckets mimic the observed interval mix in the field log
# (many sub-second drops, a bulk around 3-6s). (weight, min, max) seconds.
HOLD_BUCKETS = [
    (0.20, 0.05, 0.8),   # transport hiccup / immediate drop
    (0.65, 3.0, 6.0),    # the dominant ~5s teardown
    (0.15, 6.0, 14.0),   # occasional longer-lived, still < 15s heartbeat
]


class Stats:
    def __init__(self):
        self.opened = 0
        self.aborted = 0
        self.errors = 0
        self.snapshot_bytes = 0
        self.churn_created = 0
        self.churn_deleted = 0
        self.churn_errors = 0


def pick_hold(rng_state):
    # deterministic-ish spread without importing random per call cost
    rng_state[0] = (rng_state[0] * 1103515245 + 12345) & 0x7FFFFFFF
    r = rng_state[0] / 0x7FFFFFFF
    acc = 0.0
    for w, lo, hi in HOLD_BUCKETS:
        acc += w
        if r <= acc:
            rng_state[0] = (rng_state[0] * 1103515245 + 12345) & 0x7FFFFFFF
            f = rng_state[0] / 0x7FFFFFFF
            return lo + f * (hi - lo)
    return HOLD_BUCKETS[-1][2]


def abort_transport(resp):
    """Force a TCP RST instead of a graceful close, so the server sees an
    abrupt client disconnect mid-stream (the toxic case)."""
    conn = getattr(resp, "connection", None)
    transport = getattr(conn, "transport", None) if conn else None
    if transport is not None:
        with contextlib.suppress(Exception):
            transport.abort()


async def watch_client(idx, path, base, headers, ssl_ctx, deadline, stats, rng):
    url = f"{base}{path}?watch=true"
    while time.monotonic() < deadline:
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=10, sock_read=None)
        try:
            async with aiohttp.ClientSession(
                headers=headers, timeout=timeout
            ) as session:
                async with session.get(url, ssl=ssl_ctx) as resp:
                    if resp.status != 200:
                        stats.errors += 1
                        body = await resp.text()
                        if stats.errors <= 3:
                            print(f"[{path}] HTTP {resp.status}: {body[:200]}")
                        await asyncio.sleep(1.0)
                        continue
                    stats.opened += 1
                    hold = pick_hold(rng)
                    # Read the initial snapshot so the server registers the
                    # subscription, then sit idle so the generator is parked
                    # in receive() when we kill it.
                    end = time.monotonic() + hold
                    try:
                        while time.monotonic() < end:
                            chunk = await asyncio.wait_for(
                                resp.content.read(65536),
                                timeout=max(0.05, end - time.monotonic()),
                            )
                            if not chunk:
                                break
                            stats.snapshot_bytes += len(chunk)
                    except asyncio.TimeoutError:
                        pass
                    # Abrupt transport-level teardown, then reconnect at once.
                    abort_transport(resp)
                    stats.aborted += 1
        except (aiohttp.ClientError, asyncio.TimeoutError, ssl.SSLError):
            stats.errors += 1
            await asyncio.sleep(0.5)
        except Exception as e:  # noqa: BLE001
            stats.errors += 1
            if stats.errors <= 5:
                print(f"[{path}] client error: {type(e).__name__}: {e}")
            await asyncio.sleep(0.5)


async def list_abort_client(path, base, headers, ssl_ctx, deadline, stats):
    """Fire a plain (non-watch) list GET and abort it immediately, to hit the
    'asyncpg connect cancelled mid-flight -> non-checked-in connection' path."""
    url = f"{base}{path}"
    while time.monotonic() < deadline:
        timeout = aiohttp.ClientTimeout(total=2, sock_connect=5)
        try:
            async with aiohttp.ClientSession(headers=headers, timeout=timeout) as s:
                async with s.get(url, ssl=ssl_ctx) as resp:
                    # read a sliver then reset
                    with contextlib.suppress(Exception):
                        await asyncio.wait_for(resp.content.read(1), timeout=0.02)
                    abort_transport(resp)
        except Exception:  # noqa: BLE001
            pass
        await asyncio.sleep(0.01)


async def churn_worker(worker, base, headers, ssl_ctx, deadline, stats, live_ids):
    """Rapidly create+delete dummy inference-backends to flood the event bus
    with UN-COALESCED CREATED/DELETED events on the watched `inferencebackend`
    topic. This is what exercises the v2.2 fan-out that spawns one enqueue
    task per subscriber and blocks on `queue.put` under backpressure.

    Backends are lightweight config rows (no scheduling, no downloads) and are
    named 'zzz-repro-churn-*' so leftovers are trivial to find and remove.
    """
    create_url = f"{base}/v2/inference-backends"
    n = 0
    seen_msgs = set()  # distinct failure reasons already printed
    while time.monotonic() < deadline:
        n += 1
        # Custom backend names must end with '-custom' (server-side validation);
        # RUN_ID keeps them unique per run so leftovers don't cause 409s.
        name = f"{CHURN_PREFIX}{RUN_ID}-{worker}-{n}-custom"
        payload = {"backend_name": name, "version_configs": {}}
        timeout = aiohttp.ClientTimeout(total=15)
        try:
            async with aiohttp.ClientSession(
                headers=headers, timeout=timeout
            ) as s:
                async with s.post(create_url, json=payload, ssl=ssl_ctx) as r:
                    if r.status not in (200, 201):
                        stats.churn_errors += 1
                        body = await r.text()
                        key = f"{r.status}:{body[:120]}"
                        if key not in seen_msgs and len(seen_msgs) < 6:
                            seen_msgs.add(key)
                            print(f"[churn] create HTTP {r.status}: {body[:200]}")
                        await asyncio.sleep(2.0)
                        continue
                    data = await r.json()
                bid = data.get("id")
                stats.churn_created += 1
                if bid is not None:
                    live_ids.add(bid)
                    async with s.delete(
                        f"{create_url}/{bid}", ssl=ssl_ctx
                    ) as dr:
                        await dr.read()
                        if dr.status in (200, 204):
                            stats.churn_deleted += 1
                            live_ids.discard(bid)
        except Exception:  # noqa: BLE001
            stats.churn_errors += 1
            await asyncio.sleep(1.0)


async def sweep_churn_backends(base, headers, ssl_ctx):
    """Delete any leftover 'zzz-repro-churn-*' inference-backends from earlier
    runs (create succeeded but delete didn't, or the run was interrupted), so
    a re-run starts clean and doesn't collide with stale names."""
    url = f"{base}/v2/inference-backends"
    deleted = 0
    async with aiohttp.ClientSession(headers=headers) as s:
        try:
            async with s.get(url, params={"perPage": 1000}, ssl=ssl_ctx) as r:
                if r.status != 200:
                    return 0
                data = await r.json()
        except Exception:  # noqa: BLE001
            return 0
        for item in data.get("items", []):
            name = item.get("backend_name", "")
            bid = item.get("id")
            if name.startswith(CHURN_PREFIX) and bid is not None:
                with contextlib.suppress(Exception):
                    async with s.delete(f"{url}/{bid}", ssl=ssl_ctx) as dr:
                        await dr.read()
                        if dr.status in (200, 204):
                            deleted += 1
    return deleted


async def reporter(stats, deadline, interval=5.0):
    last = 0
    last_t = time.monotonic()
    while time.monotonic() < deadline:
        await asyncio.sleep(interval)
        now = time.monotonic()
        d = stats.opened - last
        rate = d / (now - last_t)
        churn = ""
        if stats.churn_created or stats.churn_errors:
            churn = (f" | churn create/del={stats.churn_created}/"
                     f"{stats.churn_deleted} cerr={stats.churn_errors}")
        print(
            f"  opened={stats.opened} (+{d}, {rate:.1f}/s) "
            f"aborted={stats.aborted} errors={stats.errors} "
            f"snapshot={stats.snapshot_bytes/1e6:.1f}MB{churn}"
        )
        last, last_t = stats.opened, now


async def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--url", default=os.environ.get("GPUSTACK_URL", "http://127.0.0.1"),
        help="GPUStack server base URL (default: http://127.0.0.1)",
    )
    ap.add_argument("--token", default=os.environ.get("GPUSTACK_TOKEN"))
    ap.add_argument(
        "--auth", choices=["bearer", "x-api-key"], default="bearer",
        help="how to send --token (ignored when --admin-password is set)",
    )
    ap.add_argument(
        "--admin-username", default=os.environ.get("GPUSTACK_ADMIN_USERNAME", "admin"),
        help="username for /auth/login (default: admin)",
    )
    ap.add_argument(
        "--admin-password", default=os.environ.get("GPUSTACK_ADMIN_PASSWORD"),
        help="log in with this password and reuse the session cookie (like the "
             "Web UI) instead of --token",
    )
    ap.add_argument(
        "--clients", type=int, default=40,
        help="virtual browsers; each opens all 4 watch streams",
    )
    ap.add_argument(
        "--list-abort", type=int, default=0,
        help="extra workers firing aborted plain list GETs (pool-leak path)",
    )
    ap.add_argument(
        "--churn", type=int, default=0,
        help="workers that create+delete dummy inference-backends to flood the "
             "event bus (WRITES/DELETES real DB rows -- test env only)",
    )
    ap.add_argument("--duration", type=float, default=600, help="seconds")
    ap.add_argument("--insecure", action="store_true", help="skip TLS verify")
    args = ap.parse_args()

    if not args.url:
        sys.exit("set --url or GPUSTACK_URL")
    if not args.admin_password and not args.token:
        sys.exit(
            "set --admin-password (login -> session cookie) or "
            "--token / GPUSTACK_TOKEN"
        )

    base = args.url.rstrip("/")

    ssl_ctx = None
    if base.startswith("https"):
        ssl_ctx = ssl.create_default_context()
        if args.insecure:
            ssl_ctx.check_hostname = False
            ssl_ctx.verify_mode = ssl.CERT_NONE

    # A password logs in via /auth/login and reuses the session cookie, exactly
    # like the admin Web UI (argon2 runs once, not per request). A token is sent
    # as a bearer / api-key header instead.
    if args.admin_password:
        jwt = await login_for_cookie(
            base, args.admin_username, args.admin_password, ssl_ctx
        )
        headers = {"Cookie": f"{SESSION_COOKIE}={jwt}"}
        auth_desc = f"session cookie ({args.admin_username})"
    elif args.auth == "bearer":
        headers = {"Authorization": f"Bearer {args.token}"}
        auth_desc = "bearer"
    else:
        headers = {"X-API-Key": args.token}
        auth_desc = "x-api-key"

    stats = Stats()
    deadline = time.monotonic() + args.duration
    rng = [123456789]

    print(
        f"Target {base} | auth={auth_desc} | "
        f"{args.clients} clients x {len(WATCH_PATHS)} streams "
        f"= {args.clients*len(WATCH_PATHS)} concurrent watches | "
        f"{args.list_abort} list-abort | {args.churn} churn workers | "
        f"{args.duration:.0f}s"
    )
    if args.churn:
        print("!! --churn creates/deletes real 'zzz-repro-churn-*' "
              "inference-backends. TEST ENVIRONMENT ONLY.")
    print("Watch the SERVER log for 'athrow ... already running' and "
          "'non-checked-in connection'.\n")

    live_ids = set()
    if args.churn:
        swept = await sweep_churn_backends(base, headers, ssl_ctx)
        if swept:
            print(f"swept {swept} leftover churn backends from earlier runs")

    tasks = [asyncio.create_task(reporter(stats, deadline))]
    for i in range(args.clients):
        for path in WATCH_PATHS:
            tasks.append(
                asyncio.create_task(
                    watch_client(i, path, base, headers, ssl_ctx, deadline, stats, rng)
                )
            )
    for _ in range(args.list_abort):
        tasks.append(
            asyncio.create_task(
                list_abort_client(
                    "/v2/model-instances", base, headers, ssl_ctx, deadline, stats
                )
            )
        )
    for w in range(args.churn):
        tasks.append(
            asyncio.create_task(
                churn_worker(w, base, headers, ssl_ctx, deadline, stats, live_ids)
            )
        )

    try:
        await asyncio.gather(*tasks)
    except asyncio.CancelledError:
        pass
    finally:
        if args.churn:
            with contextlib.suppress(Exception):
                await sweep_churn_backends(base, headers, ssl_ctx)
    print(
        f"\nDONE. total opened={stats.opened} aborted={stats.aborted} "
        f"errors={stats.errors} churn={stats.churn_created}/{stats.churn_deleted}"
    )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\ninterrupted")
