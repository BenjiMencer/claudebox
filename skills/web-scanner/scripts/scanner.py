#!/usr/bin/env python3
"""Thin client for the web-scanner service.

The bearer token is read from the SCANNER_TOKEN environment variable and is never
printed or written to disk. The base URL can be overridden with SCANNER_BASE_URL.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_BASE = "http://100.123.181.11:8099"


def base_url() -> str:
    return os.environ.get("SCANNER_BASE_URL", DEFAULT_BASE).rstrip("/")


def token() -> str:
    tok = os.environ.get("SCANNER_TOKEN")
    if not tok:
        sys.exit(
            "SCANNER_TOKEN is not set. Export it first:\n"
            '  export SCANNER_TOKEN="<your token>"'
        )
    return tok


def _post(path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        f"{base_url()}{path}",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {token()}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} from {path}: {e.read().decode(errors='replace')}")
    except urllib.error.URLError as e:
        sys.exit(f"Could not reach scanner at {base_url()}: {e.reason}")


def health() -> dict:
    try:
        with urllib.request.urlopen(f"{base_url()}/health", timeout=15) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.URLError as e:
        sys.exit(f"Health check failed: {e.reason}")


def main() -> None:
    p = argparse.ArgumentParser(description="Web scanner client")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("health")

    s = sub.add_parser("search")
    s.add_argument("query")
    s.add_argument("--max-results", type=int, default=5)

    sc = sub.add_parser("scan")
    sc.add_argument("url")
    sc.add_argument("--task", default="summarize the key points")

    args = p.parse_args()

    if args.cmd == "health":
        out = health()
    elif args.cmd == "search":
        mr = max(1, min(20, args.max_results))
        out = _post("/search", {"query": args.query, "max_results": mr})
    elif args.cmd == "scan":
        out = _post("/scan", {"url": args.url, "task": args.task})
    else:  # pragma: no cover
        p.error("unknown command")

    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
