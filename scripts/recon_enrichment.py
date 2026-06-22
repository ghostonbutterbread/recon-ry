#!/usr/bin/env python3
"""Recon enrichment helpers for recon-ry.

These helpers keep enrichment output additive. Existing canonical line files
such as alive.txt remain stable, while sidecars capture richer host, HTTP, port,
and ranking context for later agent review.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import urlparse


def read_lines(path: Path) -> list[str]:
    if not path.is_file():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8", errors="ignore").splitlines() if line.strip()]


def append_unique(path: Path, rows: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    existing = set(read_lines(path))
    merged = list(read_lines(path))
    for row in rows:
        if row and row not in existing:
            existing.add(row)
            merged.append(row)
    path.write_text("\n".join(merged) + ("\n" if merged else ""), encoding="utf-8")


def extract_host(value: str) -> str:
    candidate = value.strip()
    if not candidate:
        return ""
    if "://" not in candidate:
        candidate = f"//{candidate}"
    parsed = urlparse(candidate)
    host = parsed.hostname or candidate.split("/")[0].split(":")[0]
    return host.strip().lower().strip(".")


def unique_hosts(values: list[str]) -> list[str]:
    hosts: list[str] = []
    seen: set[str] = set()
    for value in values:
        host = extract_host(value)
        if host and host not in seen:
            seen.add(host)
            hosts.append(host)
    return hosts


def resolve_ips(host: str) -> list[str]:
    try:
        infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        return []
    ips = sorted({info[4][0] for info in infos if info and info[4]})
    return ips


IP_LINE_RE = re.compile(r"\[([0-9a-fA-F:.]+)\]")
IP_LITERAL_RE = re.compile(r"^[0-9a-fA-F:.]+$")


def httpx_binary() -> str | None:
    """Prefer the ProjectDiscovery httpx binary, including common Go install paths."""
    candidates = [
        shutil.which("httpx-toolkit"),
        str(Path.home() / "go" / "bin" / "httpx"),
        shutil.which("httpx"),
    ]
    for candidate in candidates:
        if not candidate:
            continue
        try:
            help_text = subprocess.run(
                [candidate, "-h"],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (FileNotFoundError, subprocess.SubprocessError):
            continue
        combined = f"{help_text.stdout}\n{help_text.stderr}"
        if "-ip" in combined and ("-l," in combined or "-list" in combined):
            return candidate
    return None


def httpx_ip_probe(input_path: Path, rate_limit: int) -> tuple[int, list[str]]:
    binary = httpx_binary()
    if not binary:
        return 127, []

    command = [binary, "-l", str(input_path), "-ip", "-silent"]
    if rate_limit:
        command.extend(["-rl", str(rate_limit)])
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        return 127, []
    rows = [
        line.strip()
        for line in f"{result.stdout}\n{result.stderr}".splitlines()
        if line.strip()
    ]
    return result.returncode, rows


def host_ip_rows_from_httpx(rows: list[str]) -> tuple[list[str], list[str]]:
    ips: set[str] = set()
    host_rows: dict[str, set[str]] = {}
    for row in rows:
        match = IP_LINE_RE.search(row)
        if not match:
            continue
        ip = match.group(1)
        host = extract_host(row.split("[", 1)[0].strip())
        if not host:
            continue
        ips.add(ip)
        host_rows.setdefault(host, set()).add(ip)

    host_json = [
        json.dumps({"host": host, "ips": sorted(host_ips), "resolved": True, "source": "httpx-ip"}, sort_keys=True)
        for host, host_ips in sorted(host_rows.items())
    ]
    return sorted(ips), host_json


def load_ip_to_hosts(project_dir: Path) -> dict[str, list[str]]:
    ip_to_hosts: dict[str, set[str]] = {}
    for line in read_lines(project_dir / "hosts.jsonl"):
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        host = str(item.get("host") or "")
        ips = item.get("ips") or []
        if not host or not isinstance(ips, list):
            continue
        for ip in ips:
            ip_to_hosts.setdefault(str(ip), set()).add(host)
    return {ip: sorted(hosts) for ip, hosts in ip_to_hosts.items()}


def has_cdn_like_resolution(project_dir: Path) -> bool:
    for line in read_lines(project_dir / "hosts.jsonl"):
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        ips = item.get("ips") or []
        if isinstance(ips, list) and len(ips) > 2:
            return True
    return False


def cmd_get_ips(args: argparse.Namespace) -> int:
    input_values = read_lines(args.input) + read_lines(args.project_dir / "alive.txt")
    hosts = unique_hosts(input_values)
    if not hosts:
        args.output.write_text("", encoding="utf-8")
        return 0

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write("\n".join(hosts) + "\n")
        host_file = Path(handle.name)

    rate_limit = normalized_rate_limit(args.rate_limit)
    try:
        code, httpx_rows = httpx_ip_probe(host_file, rate_limit)
        if code == 0:
            ips_rows, host_rows = host_ip_rows_from_httpx(httpx_rows)
            if ips_rows:
                append_unique(args.output, ips_rows)
                append_unique(args.project_dir / "hosts.jsonl", host_rows)
                append_unique(args.project_dir / "httpx_ip_raw.txt", httpx_rows)
                return 0
    finally:
        host_file.unlink(missing_ok=True)

    ips: set[str] = set()
    host_rows: list[str] = []

    for host in hosts:
        resolved_ips = resolve_ips(host)
        if not resolved_ips:
            host_rows.append(json.dumps({"host": host, "ips": [], "resolved": False, "source": "dns-fallback"}, sort_keys=True))
            continue
        ips.update(resolved_ips)
        host_rows.append(json.dumps({"host": host, "ips": resolved_ips, "resolved": True, "source": "dns-fallback"}, sort_keys=True))

    append_unique(args.output, sorted(ips))
    append_unique(args.project_dir / "hosts.jsonl", host_rows)
    return 0


def run_command(command: list[str]) -> int:
    try:
        return subprocess.run(command, check=False).returncode
    except FileNotFoundError:
        return 127


def normalized_rate_limit(value: str | None) -> int:
    if value in {None, ""}:
        return 0
    try:
        return max(int(float(value)), 0)
    except ValueError:
        return 0


def cmd_run_naabu(args: argparse.Namespace) -> int:
    input_rows = read_lines(args.input)
    host_map = load_ip_to_hosts(args.project_dir)
    ip_to_hosts: dict[str, list[str]] = {}
    host_ip_counts: dict[str, int] = {}
    for value in input_rows:
        target = extract_host(value)
        if not target:
            continue
        if IP_LITERAL_RE.match(target):
            ip_to_hosts[target] = host_map.get(target, [target])
            continue
        ips = resolve_ips(target)
        host_ip_counts[target] = len(ips)
        for ip in ips:
            ip_to_hosts.setdefault(ip, []).append(target)

    if not ip_to_hosts:
        args.output.write_text("", encoding="utf-8")
        return 0

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write("\n".join(sorted(ip_to_hosts)) + "\n")
        host_file = Path(handle.name)

    # CDN-backed hosts commonly resolve to several edge IPs. Keep those checks
    # bounded to the HTTP ports instead of doing broad edge-network scans.
    cdn_like = any(count > 2 for count in host_ip_counts.values()) or has_cdn_like_resolution(args.project_dir)
    port_args = ["-p", "80,443"] if cdn_like else ["-top-ports", str(args.top_ports)]

    command = [
        "naabu",
        "-list",
        str(host_file),
        *port_args,
        "-json",
        "-silent",
        "-o",
        str(args.output),
        "-retries",
        "1",
        "-warm-up-time",
        "0",
    ]
    rate_limit = normalized_rate_limit(args.rate_limit)
    if rate_limit:
        command.extend(["-rate", str(rate_limit)])
    try:
        code = run_command(command)
        if code != 0:
            return code
    finally:
        host_file.unlink(missing_ok=True)

    ports_rows: list[str] = []
    for line in read_lines(args.output):
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        host = item.get("host") or item.get("ip") or item.get("address") or ""
        port = item.get("port")
        protocol = item.get("protocol") or item.get("scheme") or "tcp"
        if host and port:
            mapped_hosts = ip_to_hosts.get(str(host), [str(host)])
            for mapped_host in mapped_hosts:
                ports_rows.append(f"{mapped_host}:{port}/{protocol}")

    append_unique(args.project_dir / "ports.txt", ports_rows)
    return 0


def cmd_run_httpx(args: argparse.Namespace) -> int:
    command = [
        "httpx",
        "-list",
        str(args.input),
        "-silent",
        "-json",
        "-tech-detect",
        "-cdn",
        "-title",
        "-status-code",
        "-web-server",
        "-o",
        str(args.output),
    ]
    rate_limit = normalized_rate_limit(args.rate_limit)
    if rate_limit:
        command.extend(["-rate-limit", str(rate_limit)])
    code = run_command(command)
    if code != 0:
        return code

    waf_hosts: list[str] = []
    unprotected_hosts: list[str] = []
    for line in read_lines(args.output):
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        url = item.get("url") or item.get("input") or ""
        host = extract_host(url)
        if not host:
            continue
        cdn = item.get("cdn") or item.get("cdn_name") or item.get("cdn_type") or ""
        webserver = str(item.get("webserver") or item.get("web_server") or "").lower()
        title = str(item.get("title") or "").lower()
        cdn_text = str(cdn).lower()
        protected_hint = bool(cdn_text and cdn_text not in {"false", "none", "unknown"})
        protected_hint = protected_hint or any(name in webserver or name in title for name in WAF_HINTS)
        if protected_hint:
            waf_hosts.append(host)
        else:
            unprotected_hosts.append(host)

    append_unique(args.project_dir / "waf_hosts.txt", sorted(set(waf_hosts)))
    append_unique(args.project_dir / "unprotected_hosts.txt", sorted(set(unprotected_hosts)))
    return 0


WAF_HINTS = {
    "akamai",
    "cloudflare",
    "fastly",
    "imperva",
    "incapsula",
    "sucuri",
    "cloudfront",
    "azure",
}


INTERESTING_PORTS = {"21", "22", "25", "80", "81", "443", "445", "8080", "8443", "9000", "9200", "9443"}


def load_hosts_from_host_port(rows: list[str]) -> set[str]:
    hosts: set[str] = set()
    for row in rows:
        host = row.split()[0].split(":")[0].strip()
        if host:
            hosts.add(host)
    return hosts


def cmd_rank_urls(args: argparse.Namespace) -> int:
    alive = read_lines(args.project_dir / "alive.txt")
    waf_hosts = set(read_lines(args.project_dir / "waf_hosts.txt"))
    unprotected_hosts = set(read_lines(args.project_dir / "unprotected_hosts.txt"))
    port_rows = read_lines(args.project_dir / "ports.txt")
    port_hosts = load_hosts_from_host_port(port_rows)

    port_map: dict[str, list[str]] = {}
    for row in port_rows:
        match = re.match(r"^([^:]+):(\d+)", row)
        if match:
            port_map.setdefault(match.group(1), []).append(match.group(2))

    ranked: list[dict[str, object]] = []
    for url in alive:
        host = extract_host(url)
        if not host:
            continue
        score = 0
        reasons: list[str] = []
        if host in unprotected_hosts:
            score += 30
            reasons.append("unprotected_host")
        if host in waf_hosts:
            score -= 15
            reasons.append("waf_or_cdn")
        if host in port_hosts:
            score += 10
            reasons.append("open_ports")
        interesting = sorted(set(port_map.get(host, [])) & INTERESTING_PORTS)
        if interesting:
            score += 20
            reasons.append("interesting_ports:" + ",".join(interesting))
        ranked.append({"url": url, "host": host, "score": score, "reasons": reasons})

    ranked.sort(key=lambda item: (int(item["score"]), str(item["url"])), reverse=True)
    rows = [json.dumps(item, sort_keys=True) for item in ranked]
    append_unique(args.output, rows)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Recon-ry enrichment helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    get_ips = subparsers.add_parser("get-ips", help="Resolve live hosts to IP sidecars")
    get_ips.add_argument("--input", type=Path, required=True)
    get_ips.add_argument("--output", type=Path, required=True)
    get_ips.add_argument("--project-dir", type=Path, required=True)
    get_ips.add_argument("--rate-limit", default="")
    get_ips.set_defaults(func=cmd_get_ips)

    naabu = subparsers.add_parser("run-naabu", help="Run Naabu once and create port sidecars")
    naabu.add_argument("--input", type=Path, required=True)
    naabu.add_argument("--output", type=Path, required=True)
    naabu.add_argument("--project-dir", type=Path, required=True)
    naabu.add_argument("--top-ports", default="1000")
    naabu.add_argument("--rate-limit", default="")
    naabu.set_defaults(func=cmd_run_naabu)

    httpx = subparsers.add_parser("run-httpx", help="Run httpx JSON fingerprinting sidecars")
    httpx.add_argument("--input", type=Path, required=True)
    httpx.add_argument("--output", type=Path, required=True)
    httpx.add_argument("--project-dir", type=Path, required=True)
    httpx.add_argument("--rate-limit", default="")
    httpx.set_defaults(func=cmd_run_httpx)

    rank = subparsers.add_parser("rank-urls", help="Rank URLs for focused review")
    rank.add_argument("--output", type=Path, required=True)
    rank.add_argument("--project-dir", type=Path, required=True)
    rank.set_defaults(func=cmd_rank_urls)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
