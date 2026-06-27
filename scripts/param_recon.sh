#!/usr/bin/env bash
# param_recon.sh — Multi-source parameter & endpoint discovery
#
# Passive (archive-based):
#   waybackurls  — Wayback Machine CDX API
#   waymore       — Wayback + CommonCrawl + URLScan.io + AlienVault OTX
#
# Active (live crawl):
#   katana        — ProjectDiscovery crawler with JS parsing (-jc)
#   xnLinkFinder  — Deep link/param extraction from JS, HTML, and responses
#   hakrawler     — Fast link/form crawler (disabled by default)
#   gospider      — Broad active spider (disabled by default)
#   scrapling     — Stealth crawler (bypasses Cloudflare/bot protection)
#
# Post-processing:
#   uro           — Deduplicate and normalize parameter-bearing URLs
#
# Usage:
#   ./param_recon.sh                          # defaults: alive.txt → ./
#   ./param_recon.sh -i alive.txt -o ./out
#   ./param_recon.sh -i alive.txt -r 10       # explicit rate limit (req/s)
#   ./param_recon.sh -i alive.txt --passive-only
#   ./param_recon.sh -i alive.txt --active-only
#   ./param_recon.sh -i alive.txt --stealth   # include scrapling (slower)
#   ./param_recon.sh -i alive.txt --no-waymore --no-gospider

if [ -z "$BASH_VERSION" ]; then
    echo "Error: requires bash. Run: bash $0"; exit 1
fi
set -o pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BLUE='\033[0;34m'
NC='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'

# ─── Defaults ─────────────────────────────────────────────────────────────────
INPUT="alive.txt"
OUTDIR="."
RATE_OVERRIDE=""
PASSIVE_ONLY=0
ACTIVE_ONLY=0
USE_STEALTH=0
USE_WAYBACKURLS=1
USE_WAYMORE=1
USE_KATANA=1
USE_XNLINKFINDER=1
USE_HAKRAWLER=0
USE_GOSPIDER=0
KATANA_DEPTH=5
EXT_FILTER="png,jpg,jpeg,gif,svg,ico,woff,woff2,eot,ttf,otf,webp,mp4,mp3,pdf,zip,gz,tar,map,css"

usage() {
    cat <<EOF

Usage: $0 [options]

  -i  <file>    Input file of live URLs (default: alive.txt)
  -o  <dir>     Output directory (default: current dir)
  -r  <num>     Rate limit in req/s — overrides rate_limit.conf (default: 5)
  -d  <depth>   Katana crawl depth (default: 5)

  --passive-only       Only run waybackurls + waymore
  --active-only        Only run katana + xnLinkFinder
  --stealth            Also run scrapling (slower, bypasses bot protection)

  --no-waybackurls     Skip waybackurls
  --no-waymore         Skip waymore
  --no-katana          Skip katana
  --no-xnlinkfinder    Skip xnLinkFinder
  --hakrawler          Enable hakrawler (disabled by default)
  --gospider           Enable gospider (disabled by default)
  --no-hakrawler       Skip hakrawler
  --no-gospider        Skip gospider

Output:
  params_raw.txt   Combined raw URLs from all sources (sorted-unique)
  params.txt       Deduplicated + normalized via uro

EOF
    exit 1
}

# ─── Arg parsing ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i) INPUT="$2"; shift 2 ;;
        -o) OUTDIR="$2"; shift 2 ;;
        -r) RATE_OVERRIDE="$2"; shift 2 ;;
        -d) KATANA_DEPTH="$2"; shift 2 ;;
        --passive-only) PASSIVE_ONLY=1; shift ;;
        --active-only) ACTIVE_ONLY=1; shift ;;
        --stealth) USE_STEALTH=1; shift ;;
        --no-waybackurls) USE_WAYBACKURLS=0; shift ;;
        --no-waymore) USE_WAYMORE=0; shift ;;
        --no-katana) USE_KATANA=0; shift ;;
        --no-xnlinkfinder) USE_XNLINKFINDER=0; shift ;;
        --hakrawler) USE_HAKRAWLER=1; shift ;;
        --no-hakrawler) USE_HAKRAWLER=0; shift ;;
        --gospider) USE_GOSPIDER=1; shift ;;
        --no-gospider) USE_GOSPIDER=0; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

[[ $PASSIVE_ONLY -eq 1 ]] && { USE_KATANA=0; USE_XNLINKFINDER=0; USE_HAKRAWLER=0; USE_GOSPIDER=0; USE_STEALTH=0; }
[[ $ACTIVE_ONLY -eq 1 ]]  && { USE_WAYBACKURLS=0; USE_WAYMORE=0; }

[[ ! -f "$INPUT" ]] && { echo -e "${RED}Error:${NC} '$INPUT' not found"; exit 1; }
mkdir -p "$OUTDIR"

RAW_OUT="$OUTDIR/params_raw.txt"
DEDUP_OUT="$OUTDIR/params.txt"

# ─── Rate limit ───────────────────────────────────────────────────────────────
# Priority: -r flag > rate_limit.conf (katana entry) > rate_limit.conf (default) > 5
RATE=10
if [[ -n "$RATE_OVERRIDE" ]]; then
    if [[ "$RATE_OVERRIDE" =~ ^[0-9]+$ && "$RATE_OVERRIDE" -gt 0 ]]; then
        RATE=$RATE_OVERRIDE
    else
        echo -e "${RED}Error:${NC} -r must be a positive integer (got: $RATE_OVERRIDE)"; exit 1
    fi
else
    for conf in "$(dirname "$INPUT")/rate_limit.conf" "./rate_limit.conf"; do
        if [[ -f "$conf" ]]; then
            tool_rate=$(grep -E '^katana=' "$conf" | cut -d= -f2 | tr -d ' ')
            default_rate=$(grep -E '^default=' "$conf" | cut -d= -f2 | tr -d ' ')
            if [[ "$tool_rate" =~ ^[0-9]+$ && "$tool_rate" -gt 0 ]]; then
                RATE=$tool_rate; break
            elif [[ "$default_rate" =~ ^[0-9]+$ && "$default_rate" -gt 0 ]]; then
                RATE=$default_rate; break
            fi
        fi
    done
fi

# ─── Extract domains (for passive tools) ──────────────────────────────────────
DOMAINS_TMP=$(mktemp /tmp/pr_domains.XXXXXX)
python3 -c "
import sys, re
seen = set()
for line in sys.stdin:
    m = re.search(r'https?://([^/\s:]+)', line)
    if m:
        d = m.group(1).strip(\"'\").lower()
        if d not in seen:
            seen.add(d)
            print(d)
" < "$INPUT" | sort -u > "$DOMAINS_TMP"
DOMAIN_COUNT=$(wc -l < "$DOMAINS_TMP" | tr -d ' ')
URL_COUNT=$(wc -l < "$INPUT" | tr -d ' ')

# waymore enumerates all subdomains itself — pass root domains only.
# Strategy: derive wild.txt roots first (scope wildcard bases + discovered
# subdomains all collapsed to eTLD+1). Then add urls.txt entries: bare
# hostnames whose eTLD+1 is already in wild roots are discovered subdomains
# and get collapsed; bare hostnames NOT in wild roots are exact scope entries
# (e.g. flo.uri.sh) and are kept verbatim. Full URL entries always collapse.
WAYMORE_DOMAINS_TMP=$(mktemp /tmp/pr_waymore_domains.XXXXXX)
_proj="$(dirname "$INPUT")"
python3 - "$_proj" <<'PYEOF'
import sys, re, os

def host_of(line):
    h = re.sub(r'^https?://', '', line.strip().lower())
    return h.split('/')[0].split('?')[0].split('#')[0]

def root2(h):
    p = h.split('.')
    return '.'.join(p[-2:]) if len(p) >= 2 else h

proj = sys.argv[1]
wild_f = os.path.join(proj, 'wild.txt')
urls_f = os.path.join(proj, 'urls.txt')

results = set()

# Pass 1: wild.txt — always collapse to eTLD+1 (scope roots + discovered subs)
if os.path.exists(wild_f):
    for line in open(wild_f):
        h = host_of(line)
        if h and '*' not in h:
            results.add(root2(h))

wild_roots = set(results)  # snapshot before urls pass

# Pass 2: urls.txt — collapse only if eTLD+1 is already a wild root or is a full URL
if os.path.exists(urls_f):
    for line in open(urls_f):
        val = line.strip().lower()
        is_url = val.startswith(('http://', 'https://'))
        h = host_of(val)
        if not h or '*' in h:
            continue
        if root2(h) in wild_roots:
            results.add(root2(h))  # wildcard domain — collapse to root
        else:
            results.add(h)  # exact scope entry — keep verbatim (handles unusual TLDs like flo.uri.sh)

# Fallback: no seed files, read from stdin (INPUT)
if not os.path.exists(wild_f) and not os.path.exists(urls_f):
    for line in sys.stdin:
        h = host_of(line)
        if h and '*' not in h:
            results.add(root2(h))

for r in sorted(results):
    print(r)
PYEOF

# ─── Temp files ───────────────────────────────────────────────────────────────
WB_TMP=$(mktemp /tmp/pr_wb.XXXXXX)
WAYMORE_TMP=$(mktemp /tmp/pr_waymore.XXXXXX)
KATANA_TMP=$(mktemp /tmp/pr_katana.XXXXXX)
XNLF_TMP=$(mktemp /tmp/pr_xnlf.XXXXXX)
HAK_TMP=$(mktemp /tmp/pr_hak.XXXXXX)
GOSPIDER_TMP=$(mktemp /tmp/pr_gospider.XXXXXX)
SCRAPLING_TMP=$(mktemp /tmp/pr_scrapling.XXXXXX)
SCRAPLING_SCRIPT=$(mktemp /tmp/pr_scrapling.XXXXXX.py)
START_TIME=$(date +%s)

cleanup() {
    rm -f "$DOMAINS_TMP" "$WAYMORE_DOMAINS_TMP" "$WB_TMP" "$WAYMORE_TMP" \
          "$KATANA_TMP" "$XNLF_TMP" "$HAK_TMP" "$GOSPIDER_TMP" "$SCRAPLING_TMP" "$SCRAPLING_SCRIPT"
}
trap cleanup EXIT INT TERM

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         param_recon.sh                       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}Input:${NC}       $INPUT  ($URL_COUNT URLs, $DOMAIN_COUNT domains)"
echo -e "  ${DIM}Output:${NC}      $OUTDIR"
echo -e "  ${DIM}Rate limit:${NC}  $RATE req/s$([ -n "$RATE_OVERRIDE" ] && echo " (from -r flag)" || echo " (from rate_limit.conf)")"
echo ""
echo -e "  ${CYAN}Passive:${NC}"
echo -e "    waybackurls  $([ $USE_WAYBACKURLS -eq 1 ] && echo -e "${GREEN}✓${NC}" || echo -e "${DIM}skip${NC}")"
echo -e "    waymore      $([ $USE_WAYMORE -eq 1 ] && echo -e "${GREEN}✓${NC}" || echo -e "${DIM}skip${NC}")"
echo -e "  ${CYAN}Active:${NC}"
echo -e "    katana       $([ $USE_KATANA -eq 1 ] && echo -e "${GREEN}✓${NC} (depth=$KATANA_DEPTH, -jc)" || echo -e "${DIM}skip${NC}")"
echo -e "    xnLinkFinder $([ $USE_XNLINKFINDER -eq 1 ] && echo -e "${GREEN}✓${NC}" || echo -e "${DIM}skip${NC}")"
echo -e "    hakrawler    $([ $USE_HAKRAWLER -eq 1 ] && echo -e "${GREEN}✓${NC}" || echo -e "${DIM}skip (--hakrawler to enable)${NC}")"
echo -e "    gospider     $([ $USE_GOSPIDER -eq 1 ] && echo -e "${GREEN}✓${NC}" || echo -e "${DIM}skip (--gospider to enable)${NC}")"
echo -e "    scrapling    $([ $USE_STEALTH -eq 1 ] && echo -e "${GREEN}✓${NC} (stealth mode)" || echo -e "${DIM}skip (--stealth to enable)${NC}")"
echo ""

# ─── Helper: print phase header ───────────────────────────────────────────────
PHASE=0
phase() {
    PHASE=$((PHASE + 1))
    echo -e "${CYAN}[Phase $PHASE]${NC} ${BOLD}$1${NC}"
}

result() {
    local count="$1"; local label="$2"
    echo -e "          ${GREEN}✓${NC} ${BOLD}${count}${NC} URLs — ${label}"
    echo ""
}

skip() { echo -e "          ${DIM}skipped${NC}"; echo ""; }

# ─── PASSIVE: waybackurls ─────────────────────────────────────────────────────
phase "waybackurls (Wayback Machine CDX)"
if [[ $USE_WAYBACKURLS -eq 1 ]] && command -v waybackurls &>/dev/null; then
    cat "$DOMAINS_TMP" | waybackurls 2>/dev/null > "$WB_TMP"
    result "$(wc -l < "$WB_TMP" | tr -d ' ')" "waybackurls"
elif [[ $USE_WAYBACKURLS -eq 1 ]]; then
    echo -e "          ${YELLOW}warning:${NC} waybackurls not found in PATH"; echo ""
else
    skip
fi

# ─── PASSIVE: waymore ─────────────────────────────────────────────────────────
phase "waymore (Wayback + CommonCrawl + URLScan + OTX)"
if [[ $USE_WAYMORE -eq 1 ]] && command -v waymore &>/dev/null; then
    WAYMORE_OUT_DIR=$(mktemp -d /tmp/pr_waymore_out.XXXXXX)
    while IFS= read -r domain; do
        waymore -i "$domain" -mode U -oU "$WAYMORE_OUT_DIR/${domain}.txt" -xS virustotal 2>&1 | grep -v "^\s*$" >&2 || true
    done < "$WAYMORE_DOMAINS_TMP"
    # Scope filter: waymore returns subdomain URLs for every domain it queries.
    # For wildcard scope entries (roots in wild.txt) any subdomain is fine.
    # For exact scope entries (in WAYMORE_DOMAINS_TMP but NOT covered by wild.txt)
    # strip any URL whose hostname has extra subdomain labels beyond the queried host.
    cat "$WAYMORE_OUT_DIR"/*.txt 2>/dev/null | sort -u \
    | python3 - "$_proj/wild.txt" "$WAYMORE_DOMAINS_TMP" <<'SCOPE_FILTER'
import sys, re, os

def root2(h):
    p = h.split('.')
    return '.'.join(p[-2:]) if len(p) >= 2 else h

wild_f, domains_f = sys.argv[1], sys.argv[2]

# Wildcard roots: any subdomain of these is in scope
wild_roots = set()
if os.path.exists(wild_f):
    for line in open(wild_f):
        h = line.strip().lower()
        if h and '*' not in h:
            wild_roots.add(root2(h))

# Exact scope domains: hosts we queried that are NOT covered by a wildcard root
exact_domains = set()
if os.path.exists(domains_f):
    for line in open(domains_f):
        h = line.strip().lower()
        if h and root2(h) not in wild_roots:
            exact_domains.add(h)

for line in sys.stdin:
    url = line.strip()
    if not url:
        continue
    m = re.match(r'^https?://([^/\s:?#]+)', url)
    if not m:
        print(url)
        continue
    host = m.group(1).lower()
    if root2(host) in wild_roots or host in exact_domains:
        print(url)
SCOPE_FILTER
    > "$WAYMORE_TMP"
    rm -rf "$WAYMORE_OUT_DIR"
    result "$(wc -l < "$WAYMORE_TMP" | tr -d ' ')" "waymore (scope-filtered)"
elif [[ $USE_WAYMORE -eq 1 ]]; then
    echo -e "          ${YELLOW}warning:${NC} waymore not found — install: pipx install git+https://github.com/xnl-h4ck3r/waymore.git"; echo ""
else
    skip
fi

# ─── ACTIVE: katana ───────────────────────────────────────────────────────────
phase "katana (active crawler + JS parsing)"
if [[ $USE_KATANA -eq 1 ]] && command -v katana &>/dev/null; then
    cat "$INPUT" | katana \
        -silent \
        -jc \
        -d "$KATANA_DEPTH" \
        -rl "$RATE" \
        -ef "$EXT_FILTER" \
        2>/dev/null > "$KATANA_TMP"
    result "$(wc -l < "$KATANA_TMP" | tr -d ' ')" "katana"
elif [[ $USE_KATANA -eq 1 ]]; then
    echo -e "          ${YELLOW}warning:${NC} katana not found"; echo ""
else
    skip
fi

# ─── ACTIVE: xnLinkFinder ────────────────────────────────────────────────────
phase "xnLinkFinder (deep JS/HTML link + param extraction)"
if [[ $USE_XNLINKFINDER -eq 1 ]] && command -v xnLinkFinder &>/dev/null; then
    xnLinkFinder \
        -i "$INPUT" \
        -o "$XNLF_TMP" \
        -t 5 \
        2>/dev/null || true
    result "$(wc -l < "$XNLF_TMP" | tr -d ' ')" "xnLinkFinder"
elif [[ $USE_XNLINKFINDER -eq 1 ]]; then
    echo -e "          ${YELLOW}warning:${NC} xnLinkFinder not found — install: pipx install git+https://github.com/xnl-h4ck3r/xnLinkFinder.git"; echo ""
else
    skip
fi

# ─── ACTIVE: hakrawler ────────────────────────────────────────────────────────
phase "hakrawler (link + form crawler)"
if [[ $USE_HAKRAWLER -eq 1 ]] && command -v hakrawler &>/dev/null; then
    # hakrawler has no native rate limit flag; rate limiting is not applied here
    cat "$INPUT" | hakrawler \
        -d "$KATANA_DEPTH" \
        -subs \
        2>/dev/null | grep -v -E '\.(png|jpg|jpeg|gif|svg|ico|woff|woff2|css|eot|ttf|pdf|zip)$' \
        > "$HAK_TMP"
    result "$(wc -l < "$HAK_TMP" | tr -d ' ')" "hakrawler"
elif [[ $USE_HAKRAWLER -eq 1 ]]; then
    echo -e "          ${YELLOW}warning:${NC} hakrawler not found"; echo ""
else
    skip
fi

# ─── ACTIVE: gospider ─────────────────────────────────────────────────────────
phase "gospider (broad web spider)"
if [[ $USE_GOSPIDER -eq 1 ]] && command -v gospider &>/dev/null; then
    GOSPIDER_OUT=$(mktemp -d /tmp/pr_gospider_out.XXXXXX)
    # Convert req/s to ms delay for gospider
    GOSPIDER_DELAY=$(( 1000 / RATE ))
    # gospider takes one URL at a time; run on each unique base host
    while IFS= read -r domain; do
        # Try https first, gospider handles redirects
        gospider -s "https://$domain" \
            --depth "$KATANA_DEPTH" \
            --concurrent 1 \
            --delay "$GOSPIDER_DELAY" \
            -o "$GOSPIDER_OUT/$domain" \
            --no-redirect \
            --blacklist "png,jpg,jpeg,gif,svg,ico,woff,woff2,css,eot,ttf,pdf,zip" \
            -q 2>/dev/null || true
    done < "$DOMAINS_TMP"
    # gospider output has format: [200] - [text/html] - source -> url
    grep -hroP 'https?://[^\s\]]+' "$GOSPIDER_OUT"/ 2>/dev/null | sort -u > "$GOSPIDER_TMP"
    rm -rf "$GOSPIDER_OUT"
    result "$(wc -l < "$GOSPIDER_TMP" | tr -d ' ')" "gospider"
elif [[ $USE_GOSPIDER -eq 1 ]]; then
    echo -e "          ${YELLOW}warning:${NC} gospider not found — install: go install github.com/jaeles-project/gospider@latest"; echo ""
else
    skip
fi

# ─── ACTIVE: scrapling (stealth) ──────────────────────────────────────────────
phase "scrapling (stealth crawler — bot bypass)"
if [[ $USE_STEALTH -eq 1 ]]; then
    if python3 -c "import scrapling" 2>/dev/null; then
        # Write inline Python script that crawls each URL with scrapling
        cat > "$SCRAPLING_SCRIPT" <<'PYEOF'
import sys, re, asyncio
from scrapling import Fetcher

async def crawl(url):
    try:
        page = Fetcher().get(url, timeout=15, stealthy_headers=True)
        urls = set()
        # Extract all href and src attributes
        for tag in page.css('a[href], script[src], form[action], link[href]'):
            val = tag.attrib.get('href') or tag.attrib.get('src') or tag.attrib.get('action') or ''
            if val.startswith('http'):
                urls.add(val)
            elif val.startswith('/'):
                from urllib.parse import urljoin
                urls.add(urljoin(url, val))
        # Extract URLs from inline text
        for match in re.finditer(r'https?://[^\s\'"<>]+', page.text or ''):
            urls.add(match.group())
        for u in urls:
            print(u)
    except Exception:
        pass

urls = sys.argv[1:]
for u in urls:
    asyncio.run(crawl(u))
PYEOF
        # Run in batches of 10 URLs
        mapfile -t URL_LIST < "$INPUT"
        BATCH_SIZE=10
        for (( i=0; i<${#URL_LIST[@]}; i+=BATCH_SIZE )); do
            batch=("${URL_LIST[@]:i:BATCH_SIZE}")
            python3 "$SCRAPLING_SCRIPT" "${batch[@]}" 2>/dev/null >> "$SCRAPLING_TMP"
        done
        sort -u -o "$SCRAPLING_TMP" "$SCRAPLING_TMP"
        result "$(wc -l < "$SCRAPLING_TMP" | tr -d ' ')" "scrapling"
    else
        echo -e "          ${YELLOW}warning:${NC} scrapling not installed — pip3 install scrapling"; echo ""
    fi
else
    echo -e "          ${DIM}skipped (add --stealth to enable)${NC}"; echo ""
fi

# ─── Merge all → params_raw.txt ───────────────────────────────────────────────
phase "Merging all sources → params_raw.txt"
cat "$WB_TMP" "$WAYMORE_TMP" "$KATANA_TMP" "$XNLF_TMP" "$HAK_TMP" "$GOSPIDER_TMP" "$SCRAPLING_TMP" \
    2>/dev/null | sort -u > "$RAW_OUT"
RAW_COUNT=$(wc -l < "$RAW_OUT" | tr -d ' ')
echo -e "          ${GREEN}✓${NC} ${BOLD}${RAW_COUNT}${NC} unique URLs combined"
echo ""

# ─── uro → params.txt ─────────────────────────────────────────────────────────
phase "uro deduplication → params.txt"
DEDUP_COUNT=0
if command -v uro &>/dev/null && [[ "$RAW_COUNT" -gt 0 ]]; then
    uro -i "$RAW_OUT" -o "$DEDUP_OUT" 2>/dev/null
    DEDUP_COUNT=$(wc -l < "$DEDUP_OUT" 2>/dev/null | tr -d ' ')
    echo -e "          ${GREEN}✓${NC} ${BOLD}${DEDUP_COUNT}${NC} URLs after uro"
elif [[ "$RAW_COUNT" -eq 0 ]]; then
    echo -e "          ${YELLOW}warning:${NC} no URLs collected, nothing to deduplicate"
else
    echo -e "          ${YELLOW}warning:${NC} uro not found — copying raw to params.txt"
    cp "$RAW_OUT" "$DEDUP_OUT"
    DEDUP_COUNT=$RAW_COUNT
fi
echo ""

# ─── Summary ──────────────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - START_TIME ))

echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e " ${BOLD}Summary${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
printf "  %-28s %s\n" "Elapsed:" "$(( ELAPSED/60 ))m $(( ELAPSED%60 ))s"
echo ""
printf "  ${CYAN}%-28s${NC} %s\n" "waybackurls:"     "$(wc -l < "$WB_TMP"        | tr -d ' ')"
printf "  ${CYAN}%-28s${NC} %s\n" "waymore:"          "$(wc -l < "$WAYMORE_TMP"   | tr -d ' ')"
printf "  ${CYAN}%-28s${NC} %s\n" "katana:"           "$(wc -l < "$KATANA_TMP"    | tr -d ' ')"
printf "  ${CYAN}%-28s${NC} %s\n" "xnLinkFinder:"    "$(wc -l < "$XNLF_TMP"      | tr -d ' ')"
printf "  ${CYAN}%-28s${NC} %s\n" "hakrawler:"        "$(wc -l < "$HAK_TMP"       | tr -d ' ')"
printf "  ${CYAN}%-28s${NC} %s\n" "gospider:"         "$(wc -l < "$GOSPIDER_TMP"  | tr -d ' ')"
printf "  ${CYAN}%-28s${NC} %s\n" "scrapling:"        "$(wc -l < "$SCRAPLING_TMP" | tr -d ' ')"
echo ""
printf "  ${BOLD}%-28s${NC} %s\n" "params_raw.txt:"   "$RAW_COUNT"
printf "  ${GREEN}${BOLD}%-28s${NC} %s\n" "params.txt (uro):" "${DEDUP_COUNT}"
echo ""
echo -e "  ${GREEN}Done.${NC} Output: ${BOLD}$OUTDIR${NC}"
echo ""
