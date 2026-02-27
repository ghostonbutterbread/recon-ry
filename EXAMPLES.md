# Examples

Practical `recon-ry` workflows using current commands and output behavior.

## 1) First Project Recon

```bash
PROJECT=~/bounties/hackerone
./main.sh init --project "$PROJECT"
./main.sh recon --full --project "$PROJECT" --url hackerone.com -vv
```

Inspect results:

```bash
wc -l "$PROJECT"/wild.txt "$PROJECT"/alive.txt "$PROJECT"/params.txt
ls -la "$PROJECT"/history
ls -la "$PROJECT"/dirs_status
```

## 2) Daily Re-Run (Incremental)

```bash
PROJECT=~/bounties/hackerone
./main.sh recon --full --project "$PROJECT" --url hackerone.com -v
```

Compare latest delta folder:

```bash
DATE_DIR=$(date +"%-m-%-d-%Y")
ls -la "$PROJECT/history/$DATE_DIR"
```

Notes:
- Root files (`alive.txt`, `params.txt`, etc.) keep accumulated unique data.
- `history/<date>/...` stores new findings relative to baseline for that run.

## 3) Existing Data Only (No URL)

If `urls.txt`/`wild.txt` already exist:

```bash
PROJECT=~/bounties/hackerone
./main.sh recon --full --project "$PROJECT"
```

Useful for resume/re-run workflows.

## 4) Fast Discovery Loop

```bash
PROJECT=~/targets/acme
./main.sh recon --subs --project "$PROJECT" --url acme.com
./main.sh recon --urls --project "$PROJECT"
./main.sh recon --fast --project "$PROJECT" --url acme.com
```

## 5) EyeWitness Workflows

EyeWitness-only mode using project data:

```bash
PROJECT=~/bounties/hackerone
./main.sh recon --project "$PROJECT" --eye
```

Single URL input:

```bash
./main.sh recon --project "$PROJECT" --eye https://app.hackerone.com
```

File input:

```bash
./main.sh recon --project "$PROJECT" --eye ~/targets/alive.txt
```

Outputs:
- `eyewitness/history/<m-d-YYYY>/alive`
- `eyewitness/history/<m-d-YYYY>/params`
- `eyewitness/history/<m-d-YYYY>/custom_input`

`--full` behavior:
- Empty/missing `eyewitness/`: scans standard alive/params inputs.
- Existing `eyewitness/` content: scans current run history deltas (`history/<date>/alive.txt` and `history/<date>/params.txt`).

## 6) Directory Enumeration and Status Buckets

Run only directory enumeration:

```bash
PROJECT=~/bounties/hackerone
./main.sh recon --dir --project "$PROJECT"
```

Review results by response code:

```bash
ls -la "$PROJECT/dirs_status"
for f in "$PROJECT"/dirs_status/*.txt; do echo "== $f =="; wc -l "$f"; done
```

Notes:
- ffuf output is split into `dirs_status/<status>.txt`.
- `dirs.txt` is intermediate and removed after split.

## 7) Background dir_enum Control

When `dir_enum` is included in a profile run, it starts in background after `alive_check`.

```bash
PROJECT=~/bounties/hackerone
./main.sh scans --project "$PROJECT"
./main.sh scans --project "$PROJECT" --kill
```

## 8) Secrets Workflow

```bash
PROJECT=~/bounties/hackerone
./main.sh secrets --project "$PROJECT" -vv
```

This runs configured `secret_scan` tools (from config), writing into `secrets.txt` and history deltas.

## 9) Dry-Run Before Large Changes

```bash
PROJECT=~/bounties/hackerone
./main.sh recon --full --project "$PROJECT" --url hackerone.com --dry-run
```

Use this to verify enabled stages/tools before execution.

## 10) Tune Timeouts and Rate Limits Per Project

Generate/refresh per-project overrides:

```bash
PROJECT=~/bounties/hackerone
./main.sh init --project "$PROJECT"
```

Edit `rate_limit.conf`, then run:

```bash
./main.sh recon --full --project "$PROJECT" --url hackerone.com
```

Quick timeout override example:

```bash
./main.sh recon --full --project "$PROJECT" --timeout 900
```

## 11) Useful One-Liners

Filter interesting live hosts:

```bash
grep -Ei "(api|admin|auth|internal)" ~/bounties/hackerone/alive.txt
```

Find parameterized URLs with redirect-style parameters:

```bash
grep -Ei "(redirect=|url=|next=|return=|callback=)" ~/bounties/hackerone/params.txt
```

List newest history entries:

```bash
DATE_DIR=$(date +"%-m-%-d-%Y")
PROJECT=~/bounties/hackerone
find "$PROJECT/history/$DATE_DIR" -maxdepth 2 -type f
```

## 12) Health Checks

```bash
# Tool status
./main.sh check

# Offline framework self-test
./main.sh selftest
```

## Reference

- Full documentation: [README.md](README.md)
- Quick start: [QUICKSTART.md](QUICKSTART.md)
