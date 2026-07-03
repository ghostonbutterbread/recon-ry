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
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


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


def copy_artifact(src: str | None, final_dir: Path, subdir: str, chunk_id: str, base_dir: Path) -> str | None:
    if not src:
        return None
    src_path = Path(src)
    if not src_path.is_absolute():
        src_path = base_dir / src_path
    if not src_path.exists() or not src_path.is_file():
        return None
    target_dir = final_dir / subdir
    target_dir.mkdir(parents=True, exist_ok=True)
    safe_name = f"{chunk_id}__{src_path.name}"
    dest = target_dir / safe_name
    shutil.copy2(src_path, dest)
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
    work_dir = Path(chunk.work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
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
    db_dir = Path(args.db_root).expanduser() / store_key(store_dir) / state.run_id / chunk.id
    shutil.rmtree(db_dir, ignore_errors=True)
    db_dir.mkdir(parents=True, exist_ok=True)
    env["EYEWITNESS_DB_DIR"] = str(db_dir)
    with Path(chunk.log).open("w", encoding="utf-8") as log:
        log.write("$ " + " ".join(command) + "\n")
        log.write(f"EYEWITNESS_DB_DIR={db_dir}\n")
        log.flush()
        result = subprocess.run(command, cwd=str(Path(args.eyewitness).parent), env=env, stdout=log, stderr=subprocess.STDOUT)

    db_path = db_dir / "ew.db"
    if db_path.exists():
        shutil.copy2(db_path, work_dir / "ew.db")

    chunk.exit_code = result.returncode
    chunk.finished_at = now()
    if result.returncode == 0 and (work_dir / "report.html").exists():
        count = merge_chunk(chunk, store_dir, run_dir, state.run_id, args.eyewitness)
        chunk.status = "done"
        chunk.error = None if count else "chunk completed but produced no completed records"
        if not args.keep_work:
            shutil.rmtree(work_dir, ignore_errors=True)
        save_state(state_path, state)
        return True

    chunk.status = "failed"
    chunk.error = f"exit={result.returncode}; report.html missing={not (work_dir / 'report.html').exists()}"
    save_state(state_path, state)
    return False


def html_link(href: str | None, label: str, asset_prefix: str = "") -> str:
    if not href:
        return ""
    target = asset_prefix + href
    return f'<a href="{html.escape(target, quote=True)}" target="_blank">{html.escape(label)}</a>'


def render_record(record: dict[str, Any], asset_prefix: str = "") -> str:
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
    return f"""
<tr>
  <td>
    <div class="request">
      <a href="{url}" target="_blank">{url}</a>
      {resolved_html}
      {error_html}
      <br><b>Page Title:</b> {title}
      {header_lines}
      {source_line}
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
    records.sort(key=lambda item: (str(item.get("category")), str(item.get("title")), str(item.get("url"))))
    errors = [item for item in records if item.get("error")]
    non_errors = [item for item in records if not item.get("error")]

    sections: list[tuple[str, str, list[dict[str, Any]]]] = []
    for category, label, anchor in CATEGORIES:
        group = [item for item in non_errors if item.get("category") == category]
        if group:
            sections.append((label, anchor, group))
    if errors:
        sections.append(("Errors", "errors", errors))

    toc_rows = "\n".join(
        f'<tr><td><a href="#{anchor}">{html.escape(label)}</a></td><td>{len(group)}</td></tr>'
        for label, anchor, group in sections
    )
    section_html = []
    for label, anchor, group in sections:
        section_html.append(f'<h2 id="{anchor}">{html.escape(label)}</h2>')
        for page_start in range(0, len(group), page_size):
            page = group[page_start : page_start + page_size]
            section_html.append('<table><tr><th>Web Request Info</th><th>Web Screenshot</th></tr>')
            section_html.extend(render_record(record, asset_prefix) for record in page)
            section_html.append("</table>")

    report = f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>{html.escape(title)}</title>
  <style>
    body {{ font-family: Arial, sans-serif; margin: 24px; color: #222; }}
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
    @media print {{ a {{ color: #111; }} .shot img {{ max-width: 700px; }} }}
  </style>
</head>
<body>
  <h1>{html.escape(title)}</h1>
  <div class="summary">Generated {html.escape(now())}. Total records: {len(records)}. Errors: {len(errors)}.</div>
  <h2>Table of Contents</h2>
  <table class="toc"><tr><th>Section</th><th>Count</th></tr>{toc_rows}<tr><th>Total</th><td>{len(records)}</td></tr></table>
  {''.join(section_html)}
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
