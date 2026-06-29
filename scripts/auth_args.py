#!/usr/bin/env python3
"""Render redacted or executable auth arguments for recon-ry tools."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import stat
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


SUPPORTED_TOOLS = {
    "ffuf",
    "http_fingerprinting",
    "httpx",
    "katana",
    "nuclei",
    "param_recon",
}


def load_seed(path: Path) -> dict[str, Any]:
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise SystemExit(f"auth seed must be owner-only: {path} mode={oct(mode)}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit("auth seed must be a JSON object")
    return data


def host_matches(cookie: dict[str, Any], target_host: str | None) -> bool:
    if not target_host:
        return False
    raw_url = str(cookie.get("url") or "")
    raw_domain = str(cookie.get("domain") or "")
    host = urlparse(raw_url).hostname if raw_url else raw_domain.lstrip(".")
    if not host:
        return False
    host = host.lower()
    target = target_host.lower()
    return target == host or target.endswith(f".{host}")


def cookie_header(seed: dict[str, Any], *, target_host: str | None = None) -> str | None:
    cookies = seed.get("cookies")
    if not isinstance(cookies, list):
        return None
    pairs: list[str] = []
    for cookie in cookies:
        if not isinstance(cookie, dict):
            continue
        if not host_matches(cookie, target_host):
            continue
        name = cookie.get("name")
        value = cookie.get("value")
        if name is None or value is None:
            continue
        pairs.append(f"{name}={value}")
    return "; ".join(pairs) if pairs else None


def headers(seed: dict[str, Any], *, redacted: bool = False, target_host: str | None = None) -> list[str]:
    rows: list[str] = []
    raw_headers = seed.get("headers")
    if isinstance(raw_headers, dict):
        for key, value in raw_headers.items():
            if key and value is not None:
                rows.append(f"{key}: {'<redacted>' if redacted else value}")
    cookie = cookie_header(seed, target_host=target_host)
    if cookie:
        rows.append(f"Cookie: {'<redacted>' if redacted else cookie}")
    return rows


def render_args(seed: dict[str, Any], tool: str, *, redacted: bool = False) -> str:
    if tool not in SUPPORTED_TOOLS:
        return ""
    flag = "--auth-header" if tool in {"http_fingerprinting", "param_recon"} else "-H"
    parts: list[str] = []
    target_host = os.environ.get("RECON_RY_AUTH_HOST")
    for header in headers(seed, redacted=redacted, target_host=target_host):
        parts.extend([flag, header])
    return " ".join(shlex.quote(part) for part in parts)


def metadata(seed: dict[str, Any]) -> dict[str, Any]:
    raw_headers = seed.get("headers") if isinstance(seed.get("headers"), dict) else {}
    return {
        "status": "enabled",
        "account_label": seed.get("account_label"),
        "pwnfox_color": seed.get("pwnfox_color"),
        "program": seed.get("program"),
        "session_source": seed.get("session_source"),
        "cookie_count": len(seed.get("cookies", [])) if isinstance(seed.get("cookies"), list) else 0,
        "header_names": sorted(str(key) for key in raw_headers.keys()),
    }


def redact_text(seed: dict[str, Any], text: str) -> str:
    redacted = text
    raw_headers = seed.get("headers")
    if isinstance(raw_headers, dict):
        for value in raw_headers.values():
            if value is not None:
                redacted = redacted.replace(str(value), "<redacted>")
    cookie = cookie_header(seed, target_host=os.environ.get("RECON_RY_AUTH_HOST"))
    if cookie:
        redacted = redacted.replace(cookie, "<redacted>")
    cookies = seed.get("cookies")
    if isinstance(cookies, list):
        for cookie_item in cookies:
            if isinstance(cookie_item, dict) and cookie_item.get("value") is not None:
                redacted = redacted.replace(str(cookie_item["value"]), "<redacted>")
    return redacted


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--seed", required=True, type=Path)

    render = sub.add_parser("render", parents=[common])
    render.add_argument("--tool", required=True)
    render.add_argument("--redacted", action="store_true")

    meta = sub.add_parser("metadata", parents=[common])

    redact = sub.add_parser("redact", parents=[common])
    redact.add_argument("--text", required=True)

    args = parser.parse_args()
    seed_path = args.seed.expanduser()
    if not seed_path.is_file():
        return 0
    seed = load_seed(seed_path)

    if args.command == "render":
        print(render_args(seed, args.tool, redacted=args.redacted))
    elif args.command == "metadata":
        print(json.dumps(metadata(seed), indent=2, sort_keys=True))
    elif args.command == "redact":
        print(redact_text(seed, args.text))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
