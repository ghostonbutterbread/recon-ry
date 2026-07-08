#!/usr/bin/env python3
"""Chunked EyeWitness runner with merged artifact/report output.

This wrapper keeps native EyeWitness runs small and recoverable while producing
one merged manifest/report from completed chunks.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import unquote, urlparse


CATEGORIES: list[tuple[str | None, str, str]] = [
    ("highval", "High Value Targets", "highval"),
    ("virtualization", "Virtualization", "virtualization"),
    ("kvm", "Remote Console/KVM", "kvm"),
    ("dirlist", "Directory Listings", "dirlist"),
    ("cms", "Content Management System (CMS)", "cms"),
    ("idrac", "IDRAC/ILo/Management Interfaces", "idrac"),
    ("nas", "Network Attached Storage (NAS)", "nas"),
    ("comms", "Communications", "comms"),
    ("devops", "Development Operations", "devops"),
    ("secops", "Security Operations", "secops"),
    ("appops", "Application Operations", "appops"),
    ("dataops", "Data Operations", "dataops"),
    ("netdev", "Network Devices", "netdev"),
    ("voip", "Voice/Video over IP (VoIP)", "voip"),
    ("printer", "Printers", "printer"),
    ("camera", "Cameras", "camera"),
    ("infrastructure", "Infrastructure", "infrastructure"),
    (None, "Uncategorized", "uncat"),
    ("construction", "Under Construction", "construction"),
    ("crap", "Splash Pages", "crap"),
    ("empty", "No Significant Content", "empty"),
    ("unauth", "401/403 Unauthorized", "unauth"),
    ("notfound", "404 Not Found", "notfound"),
    ("successfulLogin", "Successful Logins", "successfulLogin"),
    ("identifiedLogin", "Identified Logins", "identifiedLogin"),
    ("redirector", "Redirecting Pages", "redirector"),
    ("badhost", "Invalid Hostname", "badhost"),
    ("inerror", "Internal Error", "inerror"),
    ("badreq", "Bad Request", "badreq"),
    ("badgw", "Bad Gateway", "badgw"),
    ("serviceunavailable", "Service Unavailable", "serviceunavailable"),
]

MAX_ARTIFACT_FILENAME_BYTES = 240
INTERESTING_PRESET_FILTERS = ("errors", "no-image", "api", "json", "javascript", "unauth")
FLOURISH_DESIGN_PATH_RE = re.compile(r"^/†\d+/?$")


@dataclass
class Chunk:
    id: str
    index: int
    input: str
    work_dir: str
    status: str = "pending"
    urls: int = 0
    attempts: int = 0
    records: int = 0
    started_at: str | None = None
    finished_at: str | None = None
    exit_code: int | None = None
    log: str | None = None
    error: str | None = None


@dataclass
class RunState:
    input: str
    output: str
    run_id: str
    run_dir: str
    chunk_size: int
    created_at: str
    skipped_existing: int = 0
    chunks: list[Chunk] = field(default_factory=list)


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def default_run_id() -> str:
    return time.strftime("%Y%m%dT%H%M%S")


def script_root() -> Path:
    return Path(__file__).resolve().parents[1]


def default_eyewitness() -> Path:
    return script_root() / "tools" / "EyeWitness" / "Python" / "EyeWitness.py"


def default_eyewitness_python() -> str:
    venv_python = script_root() / "tools" / "EyeWitness" / "eyewitness-venv" / "bin" / "python"
    if venv_python.exists():
        return str(venv_python)
    return sys.executable


def default_db_root() -> Path:
    return Path.home() / ".cache" / "recon-ry-eyewitness-db"


def store_key(store_dir: Path) -> str:
    digest = hashlib.sha1(str(store_dir.resolve()).encode("utf-8")).hexdigest()[:12]
    return digest


def load_urls(path: Path) -> list[str]:
    seen: set[str] = set()
    urls: list[str] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        if value not in seen:
            seen.add(value)
            urls.append(value)
    return urls


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def chunk_to_dict(chunk: Chunk) -> dict[str, Any]:
    return {
        "id": chunk.id,
        "index": chunk.index,
        "input": chunk.input,
        "work_dir": chunk.work_dir,
        "status": chunk.status,
        "urls": chunk.urls,
        "attempts": chunk.attempts,
        "records": chunk.records,
        "started_at": chunk.started_at,
        "finished_at": chunk.finished_at,
        "exit_code": chunk.exit_code,
        "log": chunk.log,
        "error": chunk.error,
    }


def chunk_from_dict(data: dict[str, Any]) -> Chunk:
    return Chunk(
        id=data["id"],
        index=int(data["index"]),
        input=data["input"],
        work_dir=data["work_dir"],
        status=data.get("status", "pending"),
        urls=int(data.get("urls", 0)),
        attempts=int(data.get("attempts", 0)),
        records=int(data.get("records", 0)),
        started_at=data.get("started_at"),
        finished_at=data.get("finished_at"),
        exit_code=data.get("exit_code"),
        log=data.get("log"),
        error=data.get("error"),
    )


def save_state(path: Path, state: RunState) -> None:
    write_json(
        path,
        {
            "input": state.input,
            "output": state.output,
            "run_id": state.run_id,
            "run_dir": state.run_dir,
            "chunk_size": state.chunk_size,
            "created_at": state.created_at,
            "skipped_existing": state.skipped_existing,
            "updated_at": now(),
            "chunks": [chunk_to_dict(chunk) for chunk in state.chunks],
        },
    )


def load_state(path: Path) -> RunState | None:
    if not path.exists():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    return RunState(
        input=data["input"],
        output=data["output"],
        run_id=data.get("run_id", Path(path).parents[1].name),
        run_dir=data.get("run_dir", str(Path(path).parents[1])),
        chunk_size=int(data["chunk_size"]),
        created_at=data.get("created_at", now()),
        skipped_existing=int(data.get("skipped_existing", 0)),
        chunks=[chunk_from_dict(item) for item in data.get("chunks", [])],
    )


def known_scanned_urls(store_dir: Path) -> set[str]:
    manifest = store_dir / "final" / "requests.jsonl"
    return {record.get("url", "") for record in load_manifest(manifest) if record.get("url")}


def prepare_chunks(
    input_file: Path,
    store_dir: Path,
    run_id: str,
    chunk_size: int,
    skip_urls: set[str],
) -> RunState:
    all_urls = load_urls(input_file)
    urls = [url for url in all_urls if url not in skip_urls]
    run_dir = store_dir / "runs" / run_id
    chunks_dir = run_dir / "input" / "chunks"
    work_dir = run_dir / "work"
    chunks_dir.mkdir(parents=True, exist_ok=True)
    work_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "input").mkdir(parents=True, exist_ok=True)
    shutil.copy2(input_file, run_dir / "input" / "all_urls.txt")

    chunks: list[Chunk] = []
    for index, start in enumerate(range(0, len(urls), chunk_size), start=1):
        chunk_id = f"chunk_{index:04d}"
        chunk_urls = urls[start : start + chunk_size]
        chunk_input = chunks_dir / f"{chunk_id}.txt"
        chunk_input.write_text("\n".join(chunk_urls) + "\n", encoding="utf-8")
        chunks.append(
            Chunk(
                id=chunk_id,
                index=index,
                input=str(chunk_input),
                work_dir=str(work_dir / chunk_id),
                urls=len(chunk_urls),
            )
        )
    return RunState(
        input=str(input_file),
        output=str(store_dir),
        run_id=run_id,
        run_dir=str(run_dir),
        chunk_size=chunk_size,
        created_at=now(),
        skipped_existing=len(all_urls) - len(urls),
        chunks=chunks,
    )


def load_manifest(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def write_manifest(path: Path, records: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, sort_keys=True, ensure_ascii=False) + "\n")


def shorten_filename(name: str, max_bytes: int = MAX_ARTIFACT_FILENAME_BYTES) -> str:
    """Keep EyeWitness URL-derived artifact names below filesystem limits."""
    if len(name.encode("utf-8")) <= max_bytes:
        return name

    digest = hashlib.sha1(name.encode("utf-8")).hexdigest()[:12]
    stem, ext = os.path.splitext(name)
    suffix = f"__{digest}{ext}"
    suffix_bytes = len(suffix.encode("utf-8"))
    if suffix_bytes >= max_bytes:
        suffix = f"__{digest}"
        suffix_bytes = len(suffix.encode("utf-8"))

    target_stem_bytes = max(1, max_bytes - suffix_bytes)
    while len(stem.encode("utf-8")) > target_stem_bytes:
        stem = stem[:-1]
    return f"{stem}{suffix}"


def copy_artifact(src: str | None, final_dir: Path, subdir: str, chunk_id: str, base_dir: Path) -> str | None:
    if not src:
        return None
    src_path = Path(src)
    if not src_path.is_absolute():
        src_path = base_dir / src_path
    try:
        if not src_path.exists() or not src_path.is_file():
            return None
    except OSError:
        return None
    target_dir = final_dir / subdir
    target_dir.mkdir(parents=True, exist_ok=True)
    safe_name = shorten_filename(f"{chunk_id}__{src_path.name}")
    dest = target_dir / safe_name
    try:
        shutil.copy2(src_path, dest)
    except OSError:
        return None
    return str(dest.relative_to(final_dir))


def stringify(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def parse_chunk_db(chunk: Chunk, final_dir: Path, eyewitness_py: Path, artifact_prefix: str) -> list[dict[str, Any]]:
    work_dir = Path(chunk.work_dir)
    db_path = work_dir / "ew.db"
    if not db_path.exists():
        return parse_requests_csv(chunk, final_dir, artifact_prefix)

    sys.path.insert(0, str(eyewitness_py.parent))
    from modules import db_manager  # type: ignore

    manager = db_manager.DB_Manager(str(db_path))
    manager.open_connection()
    try:
        objects = manager.get_complete_http()
    finally:
        manager.close()

    records: list[dict[str, Any]] = []
    for obj in objects:
        screenshot_rel = copy_artifact(getattr(obj, "screenshot_path", None), final_dir, "screens", artifact_prefix, work_dir)
        source_rel = copy_artifact(getattr(obj, "source_path", None), final_dir, "source", artifact_prefix, work_dir)
        headers = getattr(obj, "headers", None) or getattr(obj, "http_headers", None) or {}
        records.append(
            {
                "chunk": chunk.id,
                "url": stringify(getattr(obj, "remote_system", "")),
                "title": stringify(getattr(obj, "page_title", "")),
                "category": getattr(obj, "category", None),
                "error": getattr(obj, "error_state", None),
                "resolved": stringify(getattr(obj, "resolved", "")),
                "default_creds": stringify(getattr(obj, "default_creds", "")),
                "screenshot": screenshot_rel,
                "source": source_rel,
                "headers": headers,
            }
        )
    return records


def parse_requests_csv(chunk: Chunk, final_dir: Path, artifact_prefix: str) -> list[dict[str, Any]]:
    work_dir = Path(chunk.work_dir)
    csv_path = work_dir / "Requests.csv"
    if not csv_path.exists():
        return []
    records: list[dict[str, Any]] = []
    with csv_path.open("r", encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            status = (row.get("Request Status") or "").strip()
            screenshot_rel = copy_artifact(row.get("Screenshot Path"), final_dir, "screens", artifact_prefix, work_dir)
            source_rel = copy_artifact(row.get(" Source Path") or row.get("Source Path"), final_dir, "source", artifact_prefix, work_dir)
            records.append(
                {
                    "chunk": chunk.id,
                    "url": row.get("URL", ""),
                    "title": row.get("Title", ""),
                    "category": row.get("Category") or None,
                    "error": None if status == "Successful" else status,
                    "resolved": row.get("Resolved", ""),
                    "default_creds": row.get("Default Creds", ""),
                    "screenshot": screenshot_rel,
                    "source": source_rel,
                    "headers": {},
                }
            )
    return records


def merge_chunk(chunk: Chunk, store_dir: Path, run_dir: Path, run_id: str, eyewitness_py: Path) -> int:
    final_dir = store_dir / "final"
    run_final_dir = run_dir / "final"
    central_manifest = final_dir / "requests.jsonl"
    run_manifest = run_final_dir / "requests.jsonl"
    artifact_prefix = f"{run_id}__{chunk.id}"
    new_records = parse_chunk_db(chunk, final_dir, eyewitness_py, artifact_prefix)
    for record in new_records:
        record["run_id"] = run_id
        record["chunk"] = chunk.id
        record["run_report"] = str((Path("runs") / run_id / "final" / "report.html").as_posix())

    existing_run = [
        record
        for record in load_manifest(run_manifest)
        if not (record.get("run_id") == run_id and record.get("chunk") == chunk.id)
    ]
    write_manifest(run_manifest, existing_run + new_records)

    by_url = {record.get("url"): record for record in load_manifest(central_manifest) if record.get("url")}
    for record in new_records:
        if record.get("url"):
            by_url[record["url"]] = record
    write_manifest(central_manifest, by_url.values())
    chunk.records = len(new_records)
    return len(new_records)


def run_chunk(chunk: Chunk, args: argparse.Namespace, store_dir: Path, run_dir: Path, state_path: Path, state: RunState) -> bool:
    configured_work_dir = Path(chunk.work_dir)
    work_root = Path(args.db_root).expanduser() / store_key(store_dir) / state.run_id / chunk.id
    work_dir = work_root / "work"
    shutil.rmtree(work_dir, ignore_errors=True)
    work_dir.mkdir(parents=True, exist_ok=True)
    chunk.work_dir = str(work_dir)
    log_dir = run_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    chunk.log = str(log_dir / f"{chunk.id}.eyewitness.log")
    chunk.status = "running"
    chunk.started_at = now()
    chunk.finished_at = None
    chunk.error = None
    chunk.exit_code = None
    chunk.attempts += 1
    save_state(state_path, state)

    command = [
        str(args.python),
        str(args.eyewitness),
        "--web",
        "-f",
        chunk.input,
        "--timeout",
        str(args.timeout),
        "--threads",
        str(args.threads),
        "--max-retries",
        str(args.max_retries),
        "--no-prompt",
        "--results",
        str(args.results),
        "-d",
        str(work_dir),
    ]
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    with Path(chunk.log).open("w", encoding="utf-8") as log:
        log.write("$ " + " ".join(command) + "\n")
        log.write(f"LOCAL_WORK_DIR={work_dir}\n")
        log.flush()
        result = subprocess.run(command, cwd=str(Path(args.eyewitness).parent), env=env, stdout=log, stderr=subprocess.STDOUT)

    chunk.exit_code = result.returncode
    chunk.finished_at = now()
    if result.returncode == 0 and (work_dir / "report.html").exists():
        count = merge_chunk(chunk, store_dir, run_dir, state.run_id, args.eyewitness)
        chunk.status = "done"
        chunk.error = None if count else "chunk completed but produced no completed records"
        if not args.keep_work:
            shutil.rmtree(work_dir, ignore_errors=True)
            chunk.work_dir = str(configured_work_dir)
        save_state(state_path, state)
        return True

    chunk.status = "failed"
    chunk.error = f"exit={result.returncode}; report.html missing={not (work_dir / 'report.html').exists()}"
    save_state(state_path, state)
    return False


def merge_existing_chunk(chunk: Chunk, args: argparse.Namespace, store_dir: Path, run_dir: Path, state_path: Path, state: RunState) -> bool:
    work_dir = Path(chunk.work_dir)
    if not (work_dir / "report.html").exists():
        return False
    chunk.finished_at = now()
    try:
        count = merge_chunk(chunk, store_dir, run_dir, state.run_id, args.eyewitness)
    except Exception as exc:
        chunk.status = "failed"
        chunk.error = f"merge existing output failed: {exc}"
        save_state(state_path, state)
        return False
    chunk.status = "done"
    chunk.exit_code = 0
    chunk.error = None if count else "chunk completed but produced no completed records"
    save_state(state_path, state)
    return True


def html_link(href: str | None, label: str, asset_prefix: str = "") -> str:
    if not href:
        return ""
    target = asset_prefix + href
    return f'<a href="{html.escape(target, quote=True)}" target="_blank">{html.escape(label)}</a>'


def record_header(record: dict[str, Any], header_name: str) -> str:
    headers = record.get("headers") or {}
    if not isinstance(headers, dict):
        return ""
    for key, value in headers.items():
        if str(key).lower() == header_name.lower():
            return str(value)
    return ""


def record_content_type(record: dict[str, Any]) -> str:
    return record_header(record, "content-type").split(";", 1)[0].strip().lower()


def record_content_length(record: dict[str, Any]) -> str:
    return record_header(record, "content-length").strip()


def record_status_bucket(record: dict[str, Any]) -> str:
    category = str(record.get("category") or "").lower()
    error = str(record.get("error") or "").lower()
    if category == "notfound":
        return "404"
    if category == "unauth":
        return "401-403"
    if category == "badreq":
        return "400"
    if category == "badgw":
        return "502"
    if category == "serviceunavailable":
        return "503"
    if category == "inerror":
        return "500"
    if error:
        return token_slug(error)
    return "success"


def token_slug(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")
    return slug or "unknown"


def record_response_key(record: dict[str, Any]) -> str:
    parts = [
        f"type_{record_content_type(record) or 'unknown'}",
        f"len_{record_content_length(record) or 'unknown'}",
        f"status_{record_status_bucket(record)}",
        f"title_{record.get('title') or 'unknown'}",
        f"category_{record.get('category') or 'uncategorized'}",
        f"error_{record.get('error') or 'none'}",
    ]
    return token_slug("__".join(parts))


def record_source_path(record: dict[str, Any], source_base: Path | None) -> Path | None:
    source = record.get("source")
    if not source or source_base is None:
        return None
    source_path = Path(str(source))
    if source_path.is_absolute():
        return source_path
    return source_base / source_path


def normalized_source_body(record: dict[str, Any], source_base: Path | None) -> str:
    source_path = record_source_path(record, source_base)
    if not source_path:
        return ""
    try:
        text = source_path.read_text(encoding="utf-8", errors="replace")[:250_000]
    except OSError:
        return ""
    text = html.unescape(text)
    text = re.sub(r"<script\b[^>]*>.*?</script>", " ", text, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"<style\b[^>]*>.*?</style>", " ", text, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"<[^>]+>", " ", text)
    text = text.lower()
    text = re.sub(r"https?://\S+", " {url} ", text)
    text = re.sub(r"\b[0-9a-f]{16,}\b", " {hex} ", text)
    text = re.sub(r"\b[a-z0-9_-]{24,}\b", " {token} ", text)
    text = re.sub(r"\d+", "{n}", text)
    return re.sub(r"\s+", " ", text).strip()


def record_body_key(record: dict[str, Any], source_base: Path | None) -> str:
    body = normalized_source_body(record, source_base)
    if not body:
        return record_response_key(record)
    digest = hashlib.sha1(body.encode("utf-8")).hexdigest()[:16]
    return f"body_{digest}"


def generalized_url_regex_token(record: dict[str, Any]) -> str:
    raw_url = record.get("url") or ""
    if not raw_url:
        return ""
    parsed = urlparse(raw_url)
    path = re.sub(r"\d+", r"\\d+", re.escape(parsed.path or "/"))
    base = f"{re.escape(parsed.scheme)}://{re.escape(parsed.netloc)}{path}"
    if parsed.query:
        query_parts: list[str] = []
        for part in parsed.query.split("&"):
            if "=" in part:
                name, _value = part.split("=", 1)
                query_parts.append(f"{re.escape(name)}=[^&]*")
            else:
                query_parts.append(f"{re.escape(part)}(?:=[^&]*)?")
        base += r"\?" + "&".join(query_parts)
    if parsed.fragment:
        base += r"\#" + re.escape(parsed.fragment)
    return f"url:reg:^{base}$"


def generalized_url_family(record: dict[str, Any]) -> str:
    raw_url = record.get("url") or ""
    if not raw_url:
        return "unknown"
    parsed = urlparse(raw_url.lower())
    path = re.sub(r"\d+", "{n}", parsed.path or "/")
    family = f"{parsed.scheme}://{parsed.netloc}{path}"
    if parsed.query:
        names = []
        for part in parsed.query.split("&"):
            name = part.split("=", 1)[0]
            names.append(name)
        family += "?" + "&".join(f"{name}=*" for name in names)
    return family


def record_url_response_key(record: dict[str, Any]) -> str:
    parts = [
        f"url_{generalized_url_family(record)}",
        f"len_{record_content_length(record) or 'unknown'}",
        f"type_{record_content_type(record) or 'unknown'}",
        f"status_{record_status_bucket(record)}",
    ]
    return token_slug("__".join(parts))


def same_response_filter_token(record: dict[str, Any], source_base: Path | None = None) -> str:
    parsed = urlparse(record.get("url") or "")
    parts: list[str] = []
    content_type = record_content_type(record)
    body_key = record_body_key(record, source_base)
    if parsed.hostname:
        parts.append(f"host:{parsed.hostname.lower()}")
    if content_type:
        parts.append(f"content-type:{content_type}")
    if body_key:
        parts.append(f"response-body:{body_key}")
    parts.append(f"status:{record_status_bucket(record)}")
    return " && ".join(parts)


def record_extension(record: dict[str, Any]) -> str:
    parsed = urlparse(record.get("url") or "")
    name = unquote(Path(parsed.path).name).lower().strip()
    if "." not in name:
        return ""
    ext = "." + name.rsplit(".", 1)[-1]
    if not (2 <= len(ext) <= 12) or any(char.isspace() for char in ext):
        return ""
    return ext


def record_type(record: dict[str, Any]) -> str:
    ext = record_extension(record)
    content_type = record_content_type(record)
    if ext in {".js", ".mjs", ".cjs"} or "javascript" in content_type:
        return "javascript"
    if ext == ".css" or content_type == "text/css":
        return "css"
    if ext == ".json" or content_type in {"application/json", "text/json"} or content_type.endswith("+json"):
        return "json"
    if ext == ".svg" or content_type == "image/svg+xml":
        return "svg"
    if ext in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".ico", ".bmp", ".tif", ".tiff"} or content_type.startswith("image/"):
        return "image"
    if ext in {".woff", ".woff2", ".ttf", ".otf", ".eot"} or content_type.startswith("font/"):
        return "font"
    if ext in {".mp4", ".webm", ".mov", ".m4v", ".avi", ".mkv"} or content_type.startswith("video/"):
        return "video"
    if ext in {".mp3", ".ogg", ".wav", ".m4a", ".flac"} or content_type.startswith("audio/"):
        return "audio"
    if ext == ".pdf" or content_type == "application/pdf":
        return "pdf"
    if ext in {".txt", ".csv", ".xml", ".html", ".htm"} or content_type in {"text/plain", "text/csv", "text/xml", "application/xml", "text/html"}:
        return "document"
    if ext:
        return "other-file"
    return "page"


def record_labels(record: dict[str, Any]) -> list[str]:
    labels: list[str] = []
    category = record.get("category") or "uncategorized"
    labels.append(str(category))
    parsed = urlparse(record.get("url") or "")
    if category == "notfound":
        labels.append("404")
    if category == "unauth":
        labels.extend(("401", "403"))
    rtype = record_type(record)
    labels.append(rtype)
    ext = record_extension(record)
    if ext:
        labels.append(ext.lstrip("."))
    content_type = record_content_type(record)
    if content_type:
        labels.extend(part for part in content_type.replace("+", "/").split("/") if part)
    content_length = record_content_length(record)
    if content_length:
        labels.append(f"length-{content_length}")
    labels.append(f"status-{record_status_bucket(record)}")
    if not record.get("screenshot"):
        labels.append("no-image")
    if record.get("error"):
        labels.append("error")
        if record.get("category") != "notfound":
            labels.append("errors")
    if "api" in (record.get("url") or "").lower():
        labels.append("api")
    if "†" in (record.get("url") or ""):
        labels.append("dagger-url")
    if parsed.hostname == "app.flourish.studio" and FLOURISH_DESIGN_PATH_RE.match(unquote(parsed.path)):
        labels.append("design-url")
    labels.append("response")
    labels.append(f"response-{record_response_key(record)}")
    interesting_labels = {"unauth", "errors", "no-image", "api", "json", "javascript"}
    if any(label in labels for label in interesting_labels):
        labels.append("interesting")
    return sorted(set(label for label in labels if label))


def report_section(record: dict[str, Any]) -> tuple[str, str]:
    if record.get("error"):
        return ("Errors", "errors")
    category = record.get("category")
    if category:
        for known_category, label, anchor in CATEGORIES:
            if known_category == category:
                return (label, anchor)
        return (str(category).replace("_", " ").title(), f"cat-{html.escape(str(category))}")
    labels = {
        "javascript": ("JavaScript", "type-javascript"),
        "css": ("CSS", "type-css"),
        "json": ("JSON / API Responses", "type-json"),
        "svg": ("SVG", "type-svg"),
        "image": ("Images", "type-images"),
        "font": ("Fonts", "type-fonts"),
        "video": ("Video", "type-video"),
        "audio": ("Audio", "type-audio"),
        "pdf": ("PDFs", "type-pdf"),
        "document": ("Documents / Text", "type-documents"),
        "other-file": ("Other Files", "type-other-files"),
        "page": ("Pages / No Extension", "type-pages"),
    }
    return labels.get(record_type(record), ("Uncategorized", "uncat"))


def render_record(record: dict[str, Any], asset_prefix: str = "", source_base: Path | None = None) -> str:
    title = html.escape(record.get("title") or "Unknown")
    url = html.escape(record.get("url") or "")
    resolved = html.escape(record.get("resolved") or "")
    error = html.escape(record.get("error") or "")
    screenshot = record.get("screenshot")
    source = record.get("source")
    headers = record.get("headers") or {}
    header_lines = ""
    if isinstance(headers, dict):
        for key, value in list(headers.items())[:12]:
            header_lines += f"<br><b>{html.escape(str(key))}:</b> {html.escape(str(value))}"
    labels = record_labels(record)
    label_attr = html.escape(" ".join(labels + [record.get("url", ""), record.get("title", "")]).lower(), quote=True)
    type_attr = html.escape(record_type(record), quote=True)
    image_attr = "yes" if record.get("screenshot") else "no"
    parsed = urlparse(record.get("url") or "")
    url_attr = html.escape((record.get("url") or "").lower(), quote=True)
    title_attr = html.escape((record.get("title") or "").lower(), quote=True)
    host_attr = html.escape((parsed.hostname or "").lower(), quote=True)
    path_attr = html.escape(unquote(parsed.path).lower(), quote=True)
    content_type_attr = html.escape(record_content_type(record), quote=True)
    content_length_attr = html.escape(record_content_length(record), quote=True)
    status_attr = html.escape(record_status_bucket(record), quote=True)
    response_attr = html.escape(record_response_key(record), quote=True)
    response_body_attr = html.escape(record_body_key(record, source_base), quote=True)
    url_response_attr = html.escape(record_url_response_key(record), quote=True)
    search_attr = html.escape(" ".join(labels + [record.get("url", ""), record.get("title", ""), parsed.hostname or "", unquote(parsed.path)]).lower(), quote=True)
    url_regex = html.escape(generalized_url_regex_token(record), quote=True)
    response_filter = html.escape(same_response_filter_token(record, source_base), quote=True)
    visible_labels = [label for label in labels if not label.startswith("response-")]
    badges = " ".join(f'<span class="badge">{html.escape(label)}</span>' for label in visible_labels)
    screenshot_html = ""
    if screenshot:
        escaped = html.escape(asset_prefix + screenshot, quote=True)
        screenshot_html = f'<a href="{escaped}" target="_blank"><img loading="lazy" src="{escaped}" alt="screenshot"></a>'
    else:
        screenshot_html = "<span class=\"muted\">No screenshot</span>"
    error_html = f"<br><b>Error:</b> {error}" if error else ""
    resolved_html = f"<br><b>Resolved to:</b> {resolved}" if resolved and resolved != "Unknown" else ""
    source_html = html_link(source, "Source Code", asset_prefix)
    source_line = f"<br><br>{source_html}" if source_html else ""
    actions = f"""
      <div class="row-actions">
        <button type="button" data-exclude="{url_regex}">Hide URL pattern</button>
        <button type="button" data-exclude="{response_filter}">Hide same response</button>
      </div>
    """
    return f"""
<tr class="record-row" data-labels="{label_attr}" data-type="{type_attr}" data-image="{image_attr}" data-url="{url_attr}" data-title="{title_attr}" data-host="{host_attr}" data-path="{path_attr}" data-content-type="{content_type_attr}" data-content-length="{content_length_attr}" data-status="{status_attr}" data-response="{response_attr}" data-response-body="{response_body_attr}" data-url-response="{url_response_attr}" data-search="{search_attr}">
  <td>
    <div class="request">
      <a href="{url}" target="_blank">{url}</a>
      <br><span class="badges">{badges}</span>
      {resolved_html}
      {error_html}
      <br><b>Page Title:</b> {title}
      {header_lines}
      {source_line}
      {actions}
      <br><span class="muted">Run: {html.escape(record.get("run_id", ""))} / Chunk: {html.escape(record.get("chunk", ""))}</span>
    </div>
  </td>
  <td><div class="shot">{screenshot_html}</div></td>
</tr>
"""


def render_report(
    report_dir: Path,
    manifest_path: Path,
    title: str,
    page_size: int,
    asset_prefix: str = "",
) -> Path:
    records = load_manifest(manifest_path)
    records.sort(key=lambda item: (report_section(item)[0], str(item.get("title")), str(item.get("url"))))
    errors = [item for item in records if item.get("error")]
    source_base = (report_dir / asset_prefix).resolve()

    sections: list[tuple[str, str, list[dict[str, Any]]]] = []
    section_map: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for record in records:
        label, anchor = report_section(record)
        section_map.setdefault((label, anchor), []).append(record)
    preferred_order = [
        "type-pages",
        "type-javascript",
        "type-json",
        "type-css",
        "type-svg",
        "type-images",
        "type-fonts",
        "type-video",
        "type-audio",
        "type-pdf",
        "type-documents",
        "type-other-files",
        "unauth",
        "notfound",
        "empty",
        "errors",
    ]
    order_index = {anchor: index for index, anchor in enumerate(preferred_order)}
    for (label, anchor), group in sorted(
        section_map.items(),
        key=lambda item: (order_index.get(item[0][1], 999), item[0][0]),
    ):
        sections.append((label, anchor, group))

    toc_rows = "\n".join(
        f'<tr><td><a href="#{anchor}">{html.escape(label)}</a></td><td>{len(group)}</td></tr>'
        for label, anchor, group in sections
    )
    type_counts = Counter(record_type(record) for record in records)
    no_image_count = sum(1 for record in records if not record.get("screenshot"))
    filter_buttons = [
        ("no-image", "No Image", no_image_count),
        ("errors", "Errors", sum(1 for record in records if "errors" in record_labels(record))),
        ("javascript", "JavaScript", type_counts.get("javascript", 0)),
        ("json", "JSON", type_counts.get("json", 0)),
        ("css", "CSS", type_counts.get("css", 0)),
        ("svg", "SVG", type_counts.get("svg", 0)),
        ("image", "Images", type_counts.get("image", 0)),
        ("font", "Fonts", type_counts.get("font", 0)),
        ("video", "Video", type_counts.get("video", 0)),
        ("pdf", "PDF", type_counts.get("pdf", 0)),
        ("api", "API", sum(1 for record in records if "api" in record_labels(record))),
        ("unauth", "401/403", sum(1 for record in records if "unauth" in record_labels(record))),
        ("dagger-url", "Dagger URLs", sum(1 for record in records if "dagger-url" in record_labels(record))),
        ("design-url", "Design URLs", sum(1 for record in records if "design-url" in record_labels(record))),
        ("uncategorized", "Uncategorized", sum(1 for record in records if not record.get("category"))),
    ]
    filters = "\n".join(
        f'<label class="filter-check"><input type="checkbox" value="{html.escape(value, quote=True)}"> {html.escape(label)} <span>{count}</span></label>'
        for value, label, count in filter_buttons
        if count
    )
    section_html = []
    for label, anchor, group in sections:
        section_html.append(f'<section class="report-section" id="{anchor}"><h2>{html.escape(label)} <span class="section-count">{len(group)}</span></h2>')
        for page_start in range(0, len(group), page_size):
            page = group[page_start : page_start + page_size]
            section_html.append('<table class="report-table"><tr><th>Web Request Info</th><th>Web Screenshot</th></tr>')
            section_html.extend(render_record(record, asset_prefix, source_base) for record in page)
            section_html.append("</table>")
        section_html.append('<a class="back-top" href="#top">Back to top</a></section>')

    report = f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>{html.escape(title)}</title>
  <style>
    body {{ font-family: Arial, sans-serif; margin: 0; color: #222; }}
    h1 {{ margin-bottom: 0; }}
    h2 {{ margin-top: 36px; border-bottom: 1px solid #ccc; padding-bottom: 6px; }}
    table {{ border-collapse: collapse; width: 100%; margin: 16px 0 28px; }}
    th, td {{ border: 1px solid #999; padding: 8px; vertical-align: top; }}
    th {{ background: #eee; }}
    .summary {{ color: #555; margin: 8px 0 24px; }}
    .request {{ max-width: 520px; overflow-wrap: anywhere; }}
    .shot img {{ max-height: 400px; max-width: 820px; border: 1px solid #ddd; }}
    .muted {{ color: #777; font-size: 12px; }}
    .toc {{ max-width: 720px; }}
    .layout {{ display: grid; grid-template-columns: 280px minmax(0, 1fr); min-height: 100vh; }}
    .sidebar {{ position: sticky; top: 0; align-self: start; height: 100vh; overflow: auto; border-right: 1px solid #ccc; background: #f7f7f7; padding: 16px; box-sizing: border-box; }}
    .content {{ padding: 24px; min-width: 0; }}
    .sidebar h2 {{ margin: 18px 0 8px; border: 0; padding: 0; font-size: 16px; }}
    .sidebar input[type="search"] {{ width: 100%; box-sizing: border-box; padding: 8px; font-size: 14px; margin: 6px 0 10px; }}
    details.filter-panel {{ border: 1px solid #ccc; background: #fff; margin: 10px 0; padding: 0; }}
    details.filter-panel summary {{ cursor: pointer; padding: 9px 10px; font-weight: bold; }}
    .filter-panel-body {{ border-top: 1px solid #ddd; padding: 10px; }}
    .custom-filters label {{ display: block; color: #555; font-size: 12px; margin-top: 8px; }}
    .term-list {{ display: flex; flex-direction: column; gap: 5px; margin: 2px 0 8px; }}
    .term-chip {{ display: flex; align-items: center; justify-content: space-between; gap: 8px; border: 1px solid #bbb; background: #f5f5f5; border-radius: 4px; padding: 4px 6px; font-size: 12px; overflow-wrap: anywhere; }}
    .term-chip button {{ border: 0; background: transparent; cursor: pointer; font-size: 14px; line-height: 1; padding: 0 2px; }}
    .quick-filters {{ display: flex; gap: 6px; flex-wrap: wrap; margin: 4px 0 10px; }}
    .quick-filters button {{ border: 1px solid #aaa; background: #fff; padding: 4px 7px; border-radius: 4px; cursor: pointer; font-size: 12px; }}
    .help {{ color: #666; font-size: 12px; line-height: 1.35; }}
    .query-help {{ margin: 8px 0; font-size: 12px; }}
    .query-help summary {{ cursor: pointer; color: #333; }}
    .query-help code {{ background: #eee; padding: 1px 3px; }}
    .filter-check {{ display: block; padding: 5px 0; cursor: pointer; line-height: 1.25; }}
    .filter-check span {{ color: #666; font-size: 12px; }}
    .filter-actions, .pager {{ display: flex; gap: 8px; flex-wrap: wrap; margin: 10px 0; }}
    .filter-actions button, .pager button {{ border: 1px solid #aaa; background: #fff; padding: 6px 9px; border-radius: 4px; cursor: pointer; }}
    .filter-actions button:hover, .pager button:hover {{ background: #eee; }}
    .page-size {{ width: 100%; padding: 6px; margin-top: 6px; }}
    .badge {{ display: inline-block; border: 1px solid #bbb; background: #f5f5f5; border-radius: 3px; padding: 2px 5px; margin: 2px 3px 2px 0; font-size: 11px; color: #333; }}
    .row-actions {{ display: flex; flex-wrap: wrap; gap: 6px; margin: 8px 0; }}
    .row-actions button {{ border: 1px solid #aaa; background: #fff; border-radius: 4px; padding: 4px 7px; cursor: pointer; font-size: 12px; }}
    .row-actions button:hover {{ background: #eee; }}
    .section-count {{ color: #777; font-size: 14px; font-weight: normal; }}
    .hidden-by-filter {{ display: none; }}
    .filter-status {{ color: #555; margin-top: 8px; font-size: 13px; }}
    .back-top {{ display: inline-block; margin: 0 0 24px; font-size: 13px; }}
    .top-link {{ display: inline-block; margin-top: 8px; }}
    .no-results {{ border: 1px dashed #aaa; color: #555; padding: 18px; margin-top: 18px; }}
    @media (max-width: 900px) {{
      .layout {{ grid-template-columns: 1fr; }}
      .sidebar {{ position: relative; height: auto; border-right: 0; border-bottom: 1px solid #ccc; }}
      .content {{ padding: 16px; }}
    }}
    @media print {{ a {{ color: #111; }} .shot img {{ max-width: 700px; }} }}
  </style>
</head>
<body id="top">
  <div class="layout">
  <aside class="sidebar">
    <h2>Search</h2>
    <input id="searchBox" type="search" placeholder='Search or query: app.flourish -tag:design-url url:/†\\d+$/'>
    <div class="help">Supports text, <b>-exclude</b>, <b>field:value</b>, <b>reg:</b>, <b>/regex/</b>, and wildcards like <b>*token*</b>.</div>
    <details class="query-help">
      <summary>Query help</summary>
      <div>
        Text: <code>flourish</code><br>
        Exclude: <code>-tag:design-url</code><br>
        Fields: <code>url:</code> <code>host:</code> <code>path:</code> <code>tag:</code> <code>type:</code> <code>response:</code> <code>response-body:</code> <code>url-response:</code> <code>content-type:</code> <code>length:</code> <code>status:</code><br>
        Regex: <code>url:reg:^https://app\\.flourish\\.studio/api/data_table/\\d+$</code><br>
        Slash regex: <code>path:/^\\/†\\d+\\/?$/</code>
      </div>
    </details>
    <details id="filterPanel" class="filter-panel">
    <summary>Filters</summary>
    <div class="filter-panel-body">
    <div class="custom-filters">
      <label for="includeBox">Include terms</label>
      <input id="includeBox" type="search" placeholder="Type a term, then press Enter">
      <div id="includeTerms" class="term-list"></div>
      <label for="excludeBox">Exclude terms</label>
      <input id="excludeBox" type="search" placeholder="Type a term, then press Enter">
      <div id="excludeTerms" class="term-list"></div>
      <div class="quick-filters">
        <button type="button" data-include="†">Dagger URLs</button>
        <button type="button" data-exclude="tag:design-url">Hide Designs</button>
        <button type="button" data-include="no-image">No Image</button>
        <button type="button" data-exclude="no-image">Hide No Image</button>
        <button type="button" data-include="errors">Errors</button>
        <button type="button" data-exclude="404">Hide 404</button>
      </div>
      <div class="help">Press Enter to add a term. Regex works as <b>reg:pattern</b> or <b>field:reg:pattern</b>.</div>
    </div>
    <div class="filter-actions">
      <button type="button" id="clearFilters">Clear</button>
      <button type="button" id="interestingOnly">Interesting preset</button>
    </div>
    <div class="checks">{filters}</div>
    </div>
    </details>
    <h2>Page</h2>
    <select id="pageSize" class="page-size">
      <option value="25">25 per page</option>
      <option value="50">50 per page</option>
      <option value="{page_size}" selected>{page_size} per page</option>
      <option value="200">200 per page</option>
      <option value="500">500 per page</option>
    </select>
    <div class="pager">
      <button type="button" id="prevPage">Prev</button>
      <button type="button" id="nextPage">Next</button>
    </div>
    <div id="filterStatus" class="filter-status"></div>
    <a class="top-link" href="#top">Back to top</a>
  </aside>
  <main class="content">
  <h1>{html.escape(title)}</h1>
  <div class="summary">Generated {html.escape(now())}. Total records: {len(records)}. Errors: {len(errors)}.</div>
  <div id="noResults" class="no-results hidden-by-filter">No records match the current filters.</div>
  <div class="pager">
    <button type="button" id="prevPageTop">Prev</button>
    <button type="button" id="nextPageTop">Next</button>
  </div>
  <div id="pageStatus" class="filter-status"></div>
  <h2>Table of Contents</h2>
  <table class="toc"><tr><th>Section</th><th>Count</th></tr>{toc_rows}<tr><th>Total</th><td>{len(records)}</td></tr></table>
  {''.join(section_html)}
  </main>
  </div>
  <script>
    const searchBox = document.getElementById('searchBox');
    const includeBox = document.getElementById('includeBox');
    const excludeBox = document.getElementById('excludeBox');
    const includeTermsEl = document.getElementById('includeTerms');
    const excludeTermsEl = document.getElementById('excludeTerms');
    const rows = Array.from(document.querySelectorAll('.record-row'));
    const checks = Array.from(document.querySelectorAll('.filter-check input'));
    const status = document.getElementById('filterStatus');
    const pageStatus = document.getElementById('pageStatus');
    const pageSize = document.getElementById('pageSize');
    const noResults = document.getElementById('noResults');
    const filterPanel = document.getElementById('filterPanel');
    const interestingPresetFilters = {json.dumps(INTERESTING_PRESET_FILTERS)};
    const storageKey = `recon-ry-eye-report:v2:${{location.pathname}}`;
    const includeTerms = [];
    const excludeTerms = [];
    let currentPage = 1;

    function storageAvailable() {{
      try {{
        const testKey = `${{storageKey}}:test`;
        localStorage.setItem(testKey, '1');
        localStorage.removeItem(testKey);
        return true;
      }} catch (error) {{
        return false;
      }}
    }}

    function saveState() {{
      if (!storageAvailable()) return;
      const state = {{
        search: searchBox.value,
        includeTerms,
        excludeTerms,
        checked: selectedFilters(),
        pageSize: pageSize.value,
        currentPage,
        filterPanelOpen: filterPanel.open,
      }};
      localStorage.setItem(storageKey, JSON.stringify(state));
    }}

    function restoreState() {{
      if (!storageAvailable()) return;
      const raw = localStorage.getItem(storageKey);
      if (!raw) return;
      try {{
        const state = JSON.parse(raw);
        searchBox.value = state.search || '';
        includeTerms.splice(0, includeTerms.length, ...((state.includeTerms || []).filter(Boolean)));
        excludeTerms.splice(0, excludeTerms.length, ...((state.excludeTerms || []).filter(Boolean)));
        const checked = new Set(state.checked || []);
        checks.forEach(check => check.checked = checked.has(check.value));
        if (state.pageSize) pageSize.value = state.pageSize;
        currentPage = Number(state.currentPage) || 1;
        filterPanel.open = Boolean(state.filterPanelOpen);
        renderTermList('include');
        renderTermList('exclude');
      }} catch (error) {{
        localStorage.removeItem(storageKey);
      }}
    }}

    function selectedFilters() {{
      return checks.filter(check => check.checked).map(check => check.value);
    }}

    function normalizeTerm(term) {{
      if (term === 'dagger') return '†';
      if (term === 'error') return 'errors';
      if (term === 'non-404-error') return 'errors';
      return term;
    }}

    function rowText(row, field) {{
      if (field === 'url') return row.dataset.url || '';
      if (field === 'title') return row.dataset.title || '';
      if (field === 'host') return row.dataset.host || '';
      if (field === 'path') return row.dataset.path || '';
      if (field === 'tag' || field === 'label') return row.dataset.labels || '';
      if (field === 'type') return row.dataset.type || '';
      if (field === 'response') return row.dataset.response || '';
      if (field === 'response-body' || field === 'responsebody' || field === 'body') return row.dataset.responseBody || '';
      if (field === 'url-response' || field === 'urlresponse') return row.dataset.urlResponse || '';
      if (field === 'content-type' || field === 'contenttype') return row.dataset.contentType || '';
      if (field === 'length' || field === 'content-length') return row.dataset.contentLength || '';
      if (field === 'status' || field === 'status-code' || field === 'statuscode') return row.dataset.status || '';
      return row.dataset.search || row.dataset.labels || '';
    }}

    function buildRegex(pattern, flags = '') {{
      try {{
        return new RegExp(pattern, flags);
      }} catch (error) {{
        return null;
      }}
    }}

    function parseRegex(value) {{
      if (value.startsWith('reg:')) return buildRegex(value.slice(4));
      const match = value.match(/^\\/(.*)\\/([a-z]*)$/);
      if (!match) return null;
      return buildRegex(match[1], match[2]);
    }}

    function wildcardRegex(value) {{
      const escaped = value.replace(/[.+?^${{}}()|[\\]\\\\]/g, '\\\\$&').replace(/\\*/g, '.*');
      return new RegExp(escaped);
    }}

    function tokenMatcher(rawToken) {{
      let token = normalizeTerm(rawToken.toLowerCase());
      let field = 'search';
      const colon = token.indexOf(':');
      if (colon > 0) {{
        field = token.slice(0, colon);
        token = normalizeTerm(token.slice(colon + 1));
      }}
      const regex = parseRegex(token) || (token.includes('*') ? wildcardRegex(token) : null);
      return row => {{
        const haystack = rowText(row, field);
        if (regex) return regex.test(haystack);
        return haystack.includes(token);
      }};
    }}

    function chipMatcher(rawChip) {{
      const parts = rawChip.split('&&').map(part => part.trim()).filter(Boolean);
      const matchers = (parts.length ? parts : [rawChip]).map(part => tokenMatcher(part));
      return row => matchers.every(matches => matches(row));
    }}

    function parseQuery(value) {{
      const include = [];
      const exclude = [];
      value.trim().toLowerCase().split(/\\s+/).filter(Boolean).forEach(raw => {{
        if (raw.startsWith('-') && raw.length > 1) {{
          exclude.push(tokenMatcher(raw.slice(1)));
        }} else {{
          include.push(tokenMatcher(raw));
        }}
      }});
      return {{ include, exclude }};
    }}

    function allTermsMatch(row, terms) {{
      return terms.every(matches => matches(row));
    }}

    function noTermsMatch(row, terms) {{
      return !terms.some(matches => matches(row));
    }}

    function renderTermList(kind) {{
      const terms = kind === 'include' ? includeTerms : excludeTerms;
      const container = kind === 'include' ? includeTermsEl : excludeTermsEl;
      container.innerHTML = '';
      terms.forEach((term, index) => {{
        const chip = document.createElement('span');
        chip.className = 'term-chip';
        const text = document.createElement('span');
        text.textContent = term;
        const remove = document.createElement('button');
        remove.type = 'button';
        remove.textContent = 'x';
        remove.setAttribute('aria-label', `Remove ${{term}}`);
        remove.addEventListener('click', () => {{
          terms.splice(index, 1);
          renderTermList(kind);
          applyFilters(true);
        }});
        chip.append(text, remove);
        container.appendChild(chip);
      }});
    }}

    function addTerm(kind, term) {{
      const normalized = normalizeTerm(term.trim().toLowerCase());
      if (!normalized) return;
      const terms = kind === 'include' ? includeTerms : excludeTerms;
      if (!terms.includes(normalized)) terms.push(normalized);
      renderTermList(kind);
      applyFilters(true);
    }}

    function commitInputTerm(kind, input) {{
      const value = input.value.trim();
      if (!value) return;
      value.split(/\\s+/).filter(Boolean).forEach(term => {{
        if (kind === 'include' && term.startsWith('-') && term.length > 1) {{
          addTerm('exclude', term.slice(1));
        }} else {{
          addTerm(kind, term);
        }}
      }});
      input.value = '';
    }}

    function matchesFilter(row, filter) {{
      if (filter === 'no-image') return row.dataset.image === 'no';
      return row.dataset.type === filter || row.dataset.labels.includes(filter);
    }}

    function matchingRows() {{
      const searchParsed = parseQuery(searchBox.value);
      const includeMatchers = searchParsed.include.concat(includeTerms.map(term => chipMatcher(term)));
      const excludeMatchers = searchParsed.exclude.concat(excludeTerms.map(term => chipMatcher(term)));
      const filters = selectedFilters();
      return rows.filter(row => {{
        const matchesIncludes = includeMatchers.length === 0 || allTermsMatch(row, includeMatchers);
        const matchesExcludes = noTermsMatch(row, excludeMatchers);
        const matchesChecks = filters.length === 0 || filters.some(filter => matchesFilter(row, filter));
        return matchesIncludes && matchesExcludes && matchesChecks;
      }});
    }}

    function updateSectionVisibility() {{
      document.querySelectorAll('.report-table').forEach(table => {{
        const anyVisible = Array.from(table.querySelectorAll('.record-row')).some(row => !row.classList.contains('hidden-by-filter'));
        table.classList.toggle('hidden-by-filter', !anyVisible);
      }});
      document.querySelectorAll('.report-section').forEach(section => {{
        const anyVisible = Array.from(section.querySelectorAll('.record-row')).some(row => !row.classList.contains('hidden-by-filter'));
        section.classList.toggle('hidden-by-filter', !anyVisible);
      }});
    }}

    function applyFilters(resetPage = true) {{
      if (resetPage) currentPage = 1;
      const matched = matchingRows();
      const size = Number(pageSize.value) || {page_size};
      const pageCount = Math.max(1, Math.ceil(matched.length / size));
      currentPage = Math.min(Math.max(1, currentPage), pageCount);
      const start = (currentPage - 1) * size;
      const pageRows = new Set(matched.slice(start, start + size));
      rows.forEach(row => row.classList.toggle('hidden-by-filter', !pageRows.has(row)));
      updateSectionVisibility();
      noResults.classList.toggle('hidden-by-filter', matched.length !== 0);
      status.textContent = `Matched ${{matched.length}} of ${{rows.length}} records`;
      pageStatus.textContent = `Page ${{currentPage}} of ${{pageCount}} - showing ${{pageRows.size}} records`;
      saveState();
    }}

    function changePage(delta) {{
      currentPage += delta;
      applyFilters(false);
      window.scrollTo({{ top: 0, behavior: 'smooth' }});
    }}

    checks.forEach(check => {{
      check.addEventListener('change', () => applyFilters(true));
    }});
    searchBox.addEventListener('input', applyFilters);
    includeBox.addEventListener('keydown', event => {{
      if (event.key === 'Enter') {{
        event.preventDefault();
        commitInputTerm('include', includeBox);
      }}
    }});
    excludeBox.addEventListener('keydown', event => {{
      if (event.key === 'Enter') {{
        event.preventDefault();
        commitInputTerm('exclude', excludeBox);
      }}
    }});
    pageSize.addEventListener('change', () => applyFilters(true));
    filterPanel.addEventListener('toggle', saveState);
    document.getElementById('prevPage').addEventListener('click', () => changePage(-1));
    document.getElementById('nextPage').addEventListener('click', () => changePage(1));
    document.getElementById('prevPageTop').addEventListener('click', () => changePage(-1));
    document.getElementById('nextPageTop').addEventListener('click', () => changePage(1));
    document.getElementById('clearFilters').addEventListener('click', () => {{
      checks.forEach(check => check.checked = false);
      searchBox.value = '';
      includeBox.value = '';
      excludeBox.value = '';
      includeTerms.splice(0, includeTerms.length);
      excludeTerms.splice(0, excludeTerms.length);
      renderTermList('include');
      renderTermList('exclude');
      localStorage.removeItem(storageKey);
      applyFilters(true);
    }});
    document.getElementById('interestingOnly').addEventListener('click', () => {{
      checks.forEach(check => check.checked = interestingPresetFilters.includes(check.value));
      applyFilters(true);
    }});
    document.querySelectorAll('.quick-filters button').forEach(button => {{
      button.addEventListener('click', () => {{
        if (button.dataset.include) addTerm('include', button.dataset.include);
        if (button.dataset.exclude) addTerm('exclude', button.dataset.exclude);
      }});
    }});
    document.querySelectorAll('.row-actions button').forEach(button => {{
      button.addEventListener('click', () => {{
        if (button.dataset.exclude) addTerm('exclude', button.dataset.exclude);
      }});
    }});
    restoreState();
    applyFilters(false);
  </script>
</body>
</html>
"""
    report_dir.mkdir(parents=True, exist_ok=True)
    report_path = report_dir / "report.html"
    report_path.write_text(report, encoding="utf-8")
    return report_path


def render_pdf(report_path: Path, pdf_path: Path) -> bool:
    try:
        from playwright.sync_api import sync_playwright  # type: ignore
    except Exception:
        return False
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1440, "height": 1200})
        page.goto(report_path.resolve().as_uri(), wait_until="load")
        page.pdf(path=str(pdf_path), format="A4", print_background=True)
        browser.close()
    return True


def resolve_run_id(args: argparse.Namespace, store_dir: Path) -> str:
    if args.run_id:
        return args.run_id
    latest_path = store_dir / "state" / "latest_run.txt"
    if args.resume and latest_path.exists():
        return latest_path.read_text(encoding="utf-8").strip()
    return default_run_id()


def run(args: argparse.Namespace) -> int:
    input_file = Path(args.input).expanduser().resolve()
    store_dir = Path(args.output).expanduser().resolve()
    store_dir.mkdir(parents=True, exist_ok=True)
    run_id = resolve_run_id(args, store_dir)
    if not run_id:
        print("Could not resolve run id. Pass --run-id when using --resume.", file=sys.stderr)
        return 2
    run_dir = store_dir / "runs" / run_id
    state_path = run_dir / "state" / "chunks.json"

    if state_path.exists() and not args.resume:
        print(f"Existing run state found: {state_path}", file=sys.stderr)
        print("Use --resume to continue this run, pass --force to rerun chunks, or choose a new --run-id.", file=sys.stderr)
        return 2

    state = load_state(state_path) if args.resume else None
    if state is None:
        skip_urls = set() if args.fresh else known_scanned_urls(store_dir)
        state = prepare_chunks(input_file, store_dir, run_id, args.chunk_size, skip_urls)
        save_state(state_path, state)
        latest_path = store_dir / "state" / "latest_run.txt"
        latest_path.parent.mkdir(parents=True, exist_ok=True)
        latest_path.write_text(run_id + "\n", encoding="utf-8")
    else:
        run_dir = Path(state.run_dir)

    if args.dry_run:
        print(f"Prepared {len(state.chunks)} chunks under {run_dir}")
        if state.skipped_existing:
            print(f"Skipped {state.skipped_existing} URLs already present in {store_dir / 'final' / 'requests.jsonl'}")
        for chunk in state.chunks[:10]:
            print(f"{chunk.id}: {chunk.urls} URLs -> {chunk.input}")
        if len(state.chunks) > 10:
            print(f"... {len(state.chunks) - 10} more chunks")
        return 0

    args.eyewitness = Path(args.eyewitness).expanduser().resolve()
    if not args.eyewitness.exists():
        print(f"EyeWitness.py not found: {args.eyewitness}", file=sys.stderr)
        return 2

    failed = 0
    for chunk in state.chunks:
        if args.only_chunk and chunk.id != args.only_chunk:
            continue
        if args.resume and chunk.status == "done" and not args.force:
            continue
        if args.resume and chunk.status == "running" and not args.force:
            ok = merge_existing_chunk(chunk, args, store_dir, run_dir, state_path, state)
            if not ok:
                ok = run_chunk(chunk, args, store_dir, run_dir, state_path, state)
        else:
            ok = run_chunk(chunk, args, store_dir, run_dir, state_path, state)
        if not ok:
            failed += 1
            if not args.continue_on_fail:
                break

    run_report_path = render_report(
        run_dir / "final",
        run_dir / "final" / "requests.jsonl",
        f"{args.title} ({state.run_id})",
        args.report_page_size,
        asset_prefix="../../../final/",
    )
    report_path = render_report(
        store_dir / "final",
        store_dir / "final" / "requests.jsonl",
        args.title,
        args.report_page_size,
    )
    print(f"Run report: {run_report_path}")
    print(f"Central report: {report_path}")
    print(f"Central manifest: {store_dir / 'final' / 'requests.jsonl'}")
    if args.pdf:
        pdf_path = store_dir / "final" / "report.pdf"
        if render_pdf(report_path, pdf_path):
            print(f"PDF report: {pdf_path}")
        else:
            print("PDF skipped: Playwright is not installed or Chromium is unavailable", file=sys.stderr)
    return 1 if failed else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run EyeWitness in recoverable chunks and generate one merged report.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--input", required=True, help="URL input file")
    parser.add_argument("--output", required=True, help="Durable EyeWitness store/output directory")
    parser.add_argument("--run-id", help="Run id under <output>/runs/. Defaults to timestamp; --resume uses latest when omitted")
    parser.add_argument("--eyewitness", default=str(default_eyewitness()), help="Path to EyeWitness.py")
    parser.add_argument("--python", default=default_eyewitness_python(), help="Python interpreter used to run EyeWitness")
    parser.add_argument("--db-root", default=str(default_db_root()), help="Local root for per-chunk EyeWitness SQLite DBs")
    parser.add_argument("--chunk-size", type=int, default=4000, help="URLs per EyeWitness chunk")
    parser.add_argument("--threads", type=int, default=1, help="EyeWitness threads per chunk")
    parser.add_argument("--timeout", type=int, default=10, help="EyeWitness per-target timeout")
    parser.add_argument("--max-retries", type=int, default=1, help="EyeWitness max retries")
    parser.add_argument("--results", type=int, default=100, help="Native EyeWitness results per page")
    parser.add_argument("--report-page-size", type=int, default=100, help="Rows per merged report table page")
    parser.add_argument("--title", default="Incremental EyeWitness Report", help="Merged report title")
    parser.add_argument("--keep-work", action="store_true", help="Keep successful chunk work dirs after merge")
    parser.add_argument("--fresh", action="store_true", help="Recapture URLs even when they already exist in the central store manifest")
    parser.add_argument("--continue-on-fail", action="store_true", help="Continue later chunks after a chunk failure")
    parser.add_argument("--resume", action="store_true", help="Reuse existing state and skip done chunks")
    parser.add_argument("--force", action="store_true", help="Rerun selected/done chunks")
    parser.add_argument("--only-chunk", help="Run or rerun one chunk id, e.g. chunk_0007")
    parser.add_argument("--pdf", action="store_true", help="Render final/report.pdf with Playwright when available")
    parser.add_argument("--dry-run", action="store_true", help="Prepare chunks and show plan without running EyeWitness")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.chunk_size < 1:
        parser.error("--chunk-size must be positive")
    if args.threads < 1:
        parser.error("--threads must be positive")
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
