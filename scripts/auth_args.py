#!/usr/bin/env python3
"""Auth seed/header helpers for recon-ry HTTP-capable tools."""

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


def clean_header(value: str | None) -> str | None:
    value = str(value or "").strip()
    if not value or ":" not in value or "\n" in value or "\r" in value:
        return None
    return value


def load_seed(path: Path) -> dict[str, Any]:
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise SystemExit(f"auth seed must be owner-only: {path} mode={oct(mode)}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit("auth seed must be a JSON object")
    return data


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
            data = load_seed(seed_path)
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


def flag_for_tool(tool: str) -> str:
    return "--auth-header" if tool in {"http_fingerprinting", "param_recon"} else "-H"


def shell_header_flags(headers: list[str]) -> str:
    args: list[str] = []
    for header in headers:
        args.extend(["-H", header])
    return "".join(" " + shlex.quote(arg) for arg in args)


def render_args(
    *,
    tool: str,
    seed_file: str = "",
    auth_host: str = "",
    cli_headers: list[str] | None = None,
    cli_cookies: list[str] | None = None,
    redacted: bool = False,
) -> str:
    if tool not in SUPPORTED_TOOLS:
        return ""
    headers = collect_headers(
        seed_file=seed_file,
        auth_host=auth_host or os.environ.get("RECON_RY_AUTH_HOST", ""),
        cli_headers=cli_headers,
        cli_cookies=cli_cookies,
    )
    flag = flag_for_tool(tool)
    parts: list[str] = []
    for header in headers:
        value = header
        if redacted:
            name = header.split(":", 1)[0].strip() if ":" in header else "Header"
            value = f"{name}: <redacted>"
        parts.extend([flag, value])
    return " ".join(shlex.quote(part) for part in parts)


def metadata(seed_file: str) -> dict[str, Any]:
    seed_path = Path(str(seed_file)).expanduser()
    if not seed_path.is_file():
        return {"status": "disabled"}
    data = load_seed(seed_path)
    raw_headers = data.get("headers") if isinstance(data.get("headers"), dict) else {}
    return {
        "status": "enabled",
        "account_label": data.get("account_label"),
        "pwnfox_color": data.get("pwnfox_color"),
        "program": data.get("program"),
        "session_source": data.get("session_source"),
        "cookie_count": len(data.get("cookies", [])) if isinstance(data.get("cookies"), list) else 0,
        "header_names": sorted(str(key) for key in raw_headers.keys()),
    }


def redact_text(
    *,
    text: str,
    seed_file: str = "",
    auth_host: str = "",
    cli_headers: list[str] | None = None,
    cli_cookies: list[str] | None = None,
) -> str:
    redacted = text
    for header in collect_headers(
        seed_file=seed_file,
        auth_host=auth_host or os.environ.get("RECON_RY_AUTH_HOST", ""),
        cli_headers=cli_headers,
        cli_cookies=cli_cookies,
    ):
        if ":" in header:
            name, value = header.split(":", 1)
            redacted = redacted.replace(value.strip(), "<redacted>")
            redacted = redacted.replace(header, f"{name}: <redacted>")
        else:
            redacted = redacted.replace(header, "<redacted>")
    return redacted


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Build recon-ry auth arguments.")
    parser.add_argument("--seed-file", default="")
    parser.add_argument("--seed", default="")
    parser.add_argument("--auth-host", default="")
    parser.add_argument("--auth-header", action="append", default=[])
    parser.add_argument("--cookie", action="append", default=[])
    parser.add_argument("--format", choices=("shell-header-flags", "json"), default="shell-header-flags")

    subparsers = parser.add_subparsers(dest="command")
    render = subparsers.add_parser("render")
    render.add_argument("--seed", default="")
    render.add_argument("--tool", required=True)
    render.add_argument("--auth-host", default="")
    render.add_argument("--auth-header", action="append", default=[])
    render.add_argument("--cookie", action="append", default=[])
    render.add_argument("--redacted", action="store_true")

    meta = subparsers.add_parser("metadata")
    meta.add_argument("--seed", required=True)

    redact = subparsers.add_parser("redact")
    redact.add_argument("--seed", default="")
    redact.add_argument("--text", required=True)
    redact.add_argument("--auth-host", default="")
    redact.add_argument("--auth-header", action="append", default=[])
    redact.add_argument("--cookie", action="append", default=[])
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "render":
        print(
            render_args(
                tool=args.tool,
                seed_file=args.seed,
                auth_host=args.auth_host,
                cli_headers=args.auth_header,
                cli_cookies=args.cookie,
                redacted=args.redacted,
            )
        )
        return 0
    if args.command == "metadata":
        print(json.dumps(metadata(args.seed), indent=2, sort_keys=True))
        return 0
    if args.command == "redact":
        print(
            redact_text(
                text=args.text,
                seed_file=args.seed,
                auth_host=args.auth_host,
                cli_headers=args.auth_header,
                cli_cookies=args.cookie,
            )
        )
        return 0

    headers = collect_headers(
        seed_file=args.seed_file or args.seed,
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
