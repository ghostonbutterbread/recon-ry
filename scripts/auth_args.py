#!/usr/bin/env python3
"""Auth seed/header helpers for recon-ry HTTP-capable tools."""

from __future__ import annotations

import argparse
import json
import shlex
from pathlib import Path
from urllib.parse import urlparse


def clean_header(value: str | None) -> str | None:
    value = str(value or "").strip()
    if not value or ":" not in value or "\n" in value or "\r" in value:
        return None
    return value


def cookie_host(cookie: dict) -> str:
    domain = str(cookie.get("domain") or "").lstrip(".").lower()
    if domain:
        return domain
    parsed = urlparse(str(cookie.get("url") or ""))
    return (parsed.hostname or "").lower()


def cookie_applies(cookie: dict, auth_host: str) -> bool:
    if not auth_host:
        return True
    host = cookie_host(cookie)
    return not host or auth_host == host or auth_host.endswith("." + host)


def collect_headers(
    *,
    seed_file: str = "",
    auth_host: str = "",
    cli_headers: list[str] | None = None,
    cli_cookies: list[str] | None = None,
) -> list[str]:
    headers: list[str] = []
    auth_host = str(auth_host or "").lower()

    if seed_file:
        seed_path = Path(str(seed_file)).expanduser()
        if seed_path.is_file():
            data = json.loads(seed_path.read_text(encoding="utf-8"))
            seed_headers = data.get("headers")
            if isinstance(seed_headers, dict):
                for name, value in seed_headers.items():
                    header = clean_header(f"{name}: {value}")
                    if header:
                        headers.append(header)
            cookies = data.get("cookies")
            if isinstance(cookies, list):
                parts: list[str] = []
                for cookie in cookies:
                    if not isinstance(cookie, dict) or not cookie_applies(cookie, auth_host):
                        continue
                    name = str(cookie.get("name") or "").strip()
                    value = str(cookie.get("value") or "")
                    if name and "\n" not in name and "\r" not in name and "\n" not in value and "\r" not in value:
                        parts.append(f"{name}={value}")
                if parts:
                    headers.append("Cookie: " + "; ".join(parts))

    for value in cli_headers or []:
        header = clean_header(value)
        if header:
            headers.append(header)
    for value in cli_cookies or []:
        header = clean_header(f"Cookie: {value}")
        if header:
            headers.append(header)
    return headers


def shell_header_flags(headers: list[str]) -> str:
    args: list[str] = []
    for header in headers:
        args.extend(["-H", header])
    return "".join(" " + shlex.quote(arg) for arg in args)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Build recon-ry auth arguments.")
    parser.add_argument("--seed-file", default="")
    parser.add_argument("--auth-host", default="")
    parser.add_argument("--auth-header", action="append", default=[])
    parser.add_argument("--cookie", action="append", default=[])
    parser.add_argument("--format", choices=("shell-header-flags", "json"), default="shell-header-flags")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    headers = collect_headers(
        seed_file=args.seed_file,
        auth_host=args.auth_host,
        cli_headers=args.auth_header,
        cli_cookies=args.cookie,
    )
    if args.format == "json":
        print(json.dumps(headers))
    else:
        print(shell_header_flags(headers), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
