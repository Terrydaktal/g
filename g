#!/usr/bin/env bash
set -euo pipefail

MAIN_BASHPID="${BASHPID:-$$}"

BEFORE=10
AFTER=10
VERBOSE=0
LOUD=0
AUDIT=0
CHAT_MODE=0
CHAT_KEEP_TS=1

SEARCH_HIDDEN=0
SEARCH_UUU=0
SEARCH_BINARY=0
NO_IGNORE=0
UCOUNT=0

EXT_FILTER_MODE="all"  # all|whitelist|blacklist
DEBUG_LOG="${DEBUG_LOG:-g.debug.log}"

# ------------------------------------------------------------
# Parallelism defaults (override via env if desired)
# NVMe + 9950X defaults
# ------------------------------------------------------------
NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 4)"

PAR_TEXT="${G_PAR_TEXT:-28}"
PAR_RICH="${G_PAR_RICH:-10}"
PAR_XLSX="${G_PAR_XLSX:-4}"
PAR_PPTX="${G_PAR_PPTX:-4}"
PAR_DOC="${G_PAR_DOC:-3}"

BATCH_TEXT="${G_BATCH_TEXT:-64}"
BATCH_RICH="${G_BATCH_RICH:-8}"
BATCH_XLSX="${G_BATCH_XLSX:-16}"
BATCH_PPTX="${G_BATCH_PPTX:-16}"
BATCH_DOC="${G_BATCH_DOC:-16}"

usage() {
  cat <<'EOF'
Usage:
  g --audit [PATH...]
  g [--hidden] [--uuu] [-u|-uu|-uuu] [--no_ignore] [--binary] [--whitelist|--blacklist] [-B N] [-A N] [-C N] [-v] [--loud] PATTERN [PATH...]

Modes:
  --audit        Fast audit: counts hidden vs non-hidden by extension (fd + gawk only)
  search         Searches for PATTERN and prints token-windowed matches.

Search flags:
  --hidden       include hidden files/dirs (fd -H and rg --hidden)
  -u             include hidden
  -uu            include hidden + no ignore (maps to --no_ignore)
  -uuu           include hidden + no-ignore + binary/text + --uuu
  --uuu          pass rg -uuu
  --no_ignore    do not respect ignore files (rg --no-ignore, fd --no-ignore)
  --binary       treat binary files as text (rg --text)
  --whitelist    only scan extensions in the hardcoded list
  --blacklist    scan everything EXCEPT extensions in the hardcoded list

Options:
  -B N           words before match (default 10)
  -A N           words after match  (default 10)
  -C N           set both -B and -A to N
  -v             verbose (debug log + end-of-run per-extension scan summary)
  --loud         show extractor/preprocessor messages
  --chat         normalize supported chat exports before searching
  --chat-ts=VAL  keep (keep) or drop (drop) timestamps in chat output (default: keep)
  -h, --help     help
EOF
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' not found in PATH." >&2; exit 127; }; }

# ------------------------------------------------------------
# Dependency bootstrap (Codex Web environments may not preinstall fd/ripgrep)
# ------------------------------------------------------------
APT_UPDATED=0

apt_update_once() {
  if [[ "$APT_UPDATED" -eq 0 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      APT_UPDATED=1
    else
      echo "Warning: apt-get not available; unable to auto-install missing deps." >&2
      APT_UPDATED=-1
    fi
  fi
}

install_if_missing() {
  local cmd="$1"
  local pkg="$2"
  local alt_cmd="${3:-}"

  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -n "$alt_cmd" && -x "$(command -v "$alt_cmd" 2>/dev/null)" ]]; then
    ln -sf "$(command -v "$alt_cmd")" "/usr/local/bin/$cmd"
    if command -v "$cmd" >/dev/null 2>&1; then
      return 0
    fi
  fi

  apt_update_once
  if [[ "$APT_UPDATED" -ge 0 ]]; then
    apt-get install -y "$pkg"
  fi

  if [[ -n "$alt_cmd" && -x "$(command -v "$alt_cmd" 2>/dev/null)" && ! -x "$(command -v "$cmd" 2>/dev/null)" ]]; then
    ln -sf "$(command -v "$alt_cmd")" "/usr/local/bin/$cmd"
  fi
}

# ------------------------------------------------------------
# Pre-scan argv for anywhere flags (including options that take args)
# ------------------------------------------------------------
args=("$@")
filtered=()
skip_next=0
for idx in "${!args[@]}"; do
  if [[ "$skip_next" -eq 1 ]]; then
    skip_next=0
    continue
  fi

  arg="${args[$idx]}"
  case "$arg" in
    --)
      filtered+=("${args[@]:$idx}")
      break
      ;;
    -B|-A|-C)
      next_idx=$((idx + 1))
      next_val="${args[$next_idx]:-}"
      if [[ -z "$next_val" ]]; then
        echo "Error: option $arg requires an argument" >&2
        exit 2
      fi
      case "$arg" in
        -B) BEFORE="$next_val" ;;
        -A) AFTER="$next_val" ;;
        -C) BEFORE="$next_val"; AFTER="$next_val" ;;
      esac
      skip_next=1
      continue
      ;;
    --audit) AUDIT=1; continue ;;
    --hidden) SEARCH_HIDDEN=1; continue ;;
    --uuu|-uuu|---uuu) SEARCH_UUU=1; continue ;;
    --binary|--text) SEARCH_BINARY=1; continue ;;
    --no_ignore|--no-ignore) NO_IGNORE=1; continue ;;
    --whitelist) EXT_FILTER_MODE="whitelist"; continue ;;
    --blacklist) EXT_FILTER_MODE="blacklist"; continue ;;
    --chat) CHAT_MODE=1; continue ;;
    --chat-ts=*)
      val="${arg#*=}"
      case "$val" in
        keep) CHAT_KEEP_TS=1 ;;
        drop) CHAT_KEEP_TS=0 ;;
        *) echo "Error: unknown value for --chat-ts (use keep|drop)" >&2; exit 2 ;;
      esac
      continue ;;
  esac
  filtered+=("$arg")
done
set -- "${filtered[@]}"

while getopts ":B:A:C:vhu-:" opt; do
  case "$opt" in
    B) BEFORE="$OPTARG" ;;
    A) AFTER="$OPTARG" ;;
    C) BEFORE="$OPTARG"; AFTER="$OPTARG" ;;
    v) VERBOSE=1 ;;
    h) usage; exit 0 ;;
    u) UCOUNT=$((UCOUNT + 1)) ;;
    -)
      case "${OPTARG}" in
        help) usage; exit 0 ;;
        loud) LOUD=1 ;;
        audit) AUDIT=1 ;;
        hidden) SEARCH_HIDDEN=1 ;;
        uuu) SEARCH_UUU=1 ;;
        binary|text) SEARCH_BINARY=1 ;;
        no_ignore|no-ignore) NO_IGNORE=1 ;;
        whitelist) EXT_FILTER_MODE="whitelist" ;;
        blacklist) EXT_FILTER_MODE="blacklist" ;;
        chat) CHAT_MODE=1 ;;
        chat-ts=*)
          val="${OPTARG#*=}"
          case "$val" in
            keep) CHAT_KEEP_TS=1 ;;
            drop) CHAT_KEEP_TS=0 ;;
            *) echo "Error: unknown value for --chat-ts (use keep|drop)" >&2; usage; exit 2 ;;
          esac
          ;;
        *) echo "Error: unknown option --${OPTARG}" >&2; usage; exit 2 ;;
      esac
      ;;
    \?) echo "Error: unknown option -$OPTARG" >&2; usage; exit 2 ;;
    :)  echo "Error: option -$OPTARG requires an argument" >&2; usage; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# Apply -u/-uu/-uuu semantics
if [[ "$UCOUNT" -ge 1 ]]; then SEARCH_HIDDEN=1; fi
if [[ "$UCOUNT" -ge 2 ]]; then NO_IGNORE=1; fi
if [[ "$UCOUNT" -ge 3 ]]; then SEARCH_BINARY=1; SEARCH_UUU=1; fi

install_if_missing rg ripgrep
install_if_missing fd fd-find fdfind
install_if_missing gawk gawk

need_cmd rg
need_cmd python3
need_cmd mktemp
need_cmd date
need_cmd fd

# Optional extractors
HAVE_RGA_PREPROC=0
RGA_PREPROC=""
if command -v rga-preproc >/dev/null 2>&1; then
  HAVE_RGA_PREPROC=1
  RGA_PREPROC="$(command -v rga-preproc)"
fi

HAVE_XLSX2CSV=0
python3 -c "import xlsx2csv" >/dev/null 2>&1 && HAVE_XLSX2CSV=1

HAVE_PPTX=0
python3 -c "import pptx" >/dev/null 2>&1 && HAVE_PPTX=1

HAVE_DOC=0
command -v antiword >/dev/null 2>&1 && HAVE_DOC=1
command -v catdoc   >/dev/null 2>&1 && HAVE_DOC=1

FILTER_EXTS=(
  txt md rst log csv tsv json yaml yml toml ini conf cfg xml html htm css
  py sh bash zsh fish c h cpp hpp cc cxx java kt go rs js mjs cjs ts tsx jsx php rb pl
  pdf docx doc xlsx xls pptx ppt sqlite sqlite3 db db3
)

CTX_LINES=$((BEFORE + AFTER + 20))

# -----------------------------
# FAST AUDIT MODE
# -----------------------------
if [[ "$AUDIT" -eq 1 ]]; then
  need_cmd gawk

  PATHS=("$@")
  if [[ ${#PATHS[@]} -ge 2 ]]; then
    if [[ ! -e "${PATHS[0]}" && -e "${PATHS[1]}" ]]; then
      PATHS=("${PATHS[@]:1}")
    fi
  fi

  AUDIT_TARGETS=()
  for p in "${PATHS[@]}"; do [[ -e "$p" ]] && AUDIT_TARGETS+=("$p"); done
  [[ ${#AUDIT_TARGETS[@]} -gt 0 ]] || AUDIT_TARGETS=(".")

  FD_ARGS=(-0 -t f -H)
  [[ "$NO_IGNORE" -eq 1 ]] && FD_ARGS+=(--no-ignore)

  FILTER_LIST="$(IFS=' '; echo "${FILTER_EXTS[*]}")"

  {
    for p in "${AUDIT_TARGETS[@]}"; do
      if [[ -f "$p" ]]; then
        printf '%s\0' "$p"
      elif [[ -d "$p" ]]; then
        fd "${FD_ARGS[@]}" . "$p" 2>/dev/null || true
      fi
    done
  } | gawk -v RS='\0' -v MODE="$EXT_FILTER_MODE" -v WLIST="$FILTER_LIST" -v TOPN="300" '
BEGIN {
  EXT_W = 10
  n = split(WLIST, wl_words, /[[:space:]]+/)
  for (i=1; i<=n; i++) if (wl_words[i] != "") wl[wl_words[i]] = 1

  # Buckets (must match search splitter semantics)
  bucket["pdf"]="rich"; bucket["docx"]="rich";
  bucket["sqlite"]="rich"; bucket["sqlite3"]="rich"; bucket["db"]="rich"; bucket["db3"]="rich";

  bucket["xlsx"]="xlsx"; bucket["xls"]="xlsx";
  bucket["pptx"]="pptx"; bucket["ppt"]="pptx";
  bucket["doc"]="doc";
}
function is_hidden_path(p) { return (p ~ /(^|\/)\.[^\/]/) }
function ext_of(p, base, dotpos, ext) {
  base = p; sub(/^.*\//, "", base)
  if (base ~ /^\.[^\.]+$/) return "(dotfile)"
  dotpos = match(base, /\.[^\.]*$/); if (dotpos == 0) return "(none)"
  ext = substr(base, dotpos + 1); if (ext == "") return "(none)"
  return tolower(ext)
}
function allowed_for_table(ext) {
  if (MODE == "all") return 1
  if (MODE == "whitelist") return (ext in wl)
  if (MODE == "blacklist") return !(ext in wl)
  return 1
}
function wl_yes(e) { return (e in wl) ? "yes" : "" }
function bucket_of(e) { return (e in bucket) ? bucket[e] : "text" }

function cmp(i1, v1, i2, v2,    t1,t2,n1,n2,h1,h2) {
  t1 = (non[i1] + hid[i1]) + 0; t2 = (non[i2] + hid[i2]) + 0
  if (t1 != t2) return (t2 - t1)
  n1 = non[i1] + 0; n2 = non[i2] + 0; if (n1 != n2) return (n2 - n1)
  h1 = hid[i1] + 0; h2 = hid[i2] + 0; if (h1 != h2) return (h2 - h1)
  return (i1 < i2 ? -1 : (i1 > i2 ? 1 : 0))
}
{
  p = $0; if (p == "") next
  e = ext_of(p); hidden = is_hidden_path(p)

  if (hidden) { if (e in wl) wl_hid++; else bl_hid++; } else { if (e in wl) wl_non++; else bl_non++; }

  if (!allowed_for_table(e)) next
  if (hidden) hid[e]++; else non[e]++
  seen[e] = 1
}
END {
  total = (wl_non + wl_hid + bl_non + bl_hid)
  print "---- audit ----"
  printf "whitelist_non_hidden: %d\n", wl_non+0
  printf "whitelist_hidden:     %d\n", wl_hid+0
  printf "blacklist_non_hidden: %d\n", bl_non+0
  printf "blacklist_hidden:     %d\n", bl_hid+0
  printf "total:               %d\n\n", total+0

  printf "%-*s %-5s %-6s %12s %12s %12s\n", EXT_W, "ext", "wlist", "bucket", "non_hidden", "hidden", "total"

  nkeys = asorti(seen, ord, "cmp")
  other_non = other_hid = 0
  for (i=1; i<=nkeys; i++) {
    e = ord[i]
    nh = non[e] + 0; hh = hid[e] + 0; tot = nh + hh
    if (i <= TOPN) {
      printf "%-*s %-5s %-6s %12d %12d %12d\n", EXT_W, e, wl_yes(e), bucket_of(e), nh, hh, tot
    } else { other_non += nh; other_hid += hh }
  }
  if (nkeys > TOPN) {
    printf "%-*s %-5s %-6s %12d %12d %12d\n", EXT_W, "other", "", "", other_non+0, other_hid+0, (other_non+other_hid)
  }
  print "---- end audit ----"
}'
  exit 0
fi

# -----------------------------
# Search mode
# -----------------------------
[[ $# -ge 1 ]] || { usage; exit 2; }
PATTERN="$1"; shift
PATHS=("$@")
[[ ${#PATHS[@]} -gt 0 ]] || PATHS=(".")

RG_COMMON=()
[[ "$SEARCH_HIDDEN" -eq 1 ]] && RG_COMMON+=(--hidden)
[[ "$NO_IGNORE" -eq 1 ]] && RG_COMMON+=(--no-ignore)
[[ "$SEARCH_UUU" -eq 1 ]] && RG_COMMON+=(-uuu)
[[ "$SEARCH_BINARY" -eq 1 ]] && RG_COMMON+=(--text)

tmp_fmt="$(mktemp -t g_fmt.XXXXXX.py)"
tmp_split="$(mktemp -t g_split.XXXXXX.py)"
tmp_xlsx="$(mktemp -t g_xlsx.XXXXXX.py)"
tmp_pptx="$(mktemp -t g_pptx.XXXXXX.py)"
tmp_doc="$(mktemp -t g_doc.XXXXXX.sh)"
tmp_chat="$(mktemp -t g_chat.XXXXXX.py)"
tmp_vsum="$(mktemp -t g_vsum.XXXXXX.py)"
tmp_failparse="$(mktemp -t g_failparse.XXXXXX.py)"

tmp_all="$(mktemp -t g_all.XXXXXX.bin)"
tmp_text="$(mktemp -t g_text.XXXXXX.bin)"
tmp_rich="$(mktemp -t g_rich.XXXXXX.bin)"
tmp_chat_list="$(mktemp -t g_chat_list.XXXXXX.bin)"
tmp_xlsx_list="$(mktemp -t g_xlsx_list.XXXXXX.bin)"
tmp_pptx_list="$(mktemp -t g_pptx_list.XXXXXX.bin)"
tmp_doc_list="$(mktemp -t g_doc_list.XXXXXX.bin)"

tmp_bad_rich="$(mktemp -t g_bad_rich.XXXXXX.txt)"
tmp_stats_json="$(mktemp -t g_stats.XXXXXX.json)"

tmp_rc2="$(mktemp -t g_rc2.XXXXXX)"
tmp_mc="$(mktemp -t g_mc.XXXXXX)"
tmp_shards_root="$(mktemp -d -t g_shards_root.XXXXXX)"

tmp_err_text="$(mktemp -t g_err_text.XXXXXX.txt)"
tmp_err_rich="$(mktemp -t g_err_rich.XXXXXX.txt)"
tmp_err_chat="$(mktemp -t g_err_chat.XXXXXX.txt)"
tmp_err_xlsx="$(mktemp -t g_err_xlsx.XXXXXX.txt)"
tmp_err_pptx="$(mktemp -t g_err_pptx.XXXXXX.txt)"
tmp_err_doc="$(mktemp -t g_err_doc.XXXXXX.txt)"

BAD_RICH_PERSIST="${DEBUG_LOG}.bad_rich.txt"

FAIL_TEXT_PERSIST="${DEBUG_LOG}.fail_text.txt"
FAIL_CHAT_PERSIST="${DEBUG_LOG}.fail_chat.txt"
FAIL_RICH_PERSIST="${DEBUG_LOG}.fail_rich.txt"
FAIL_XLSX_PERSIST="${DEBUG_LOG}.fail_xlsx.txt"
FAIL_PPTX_PERSIST="${DEBUG_LOG}.fail_pptx.txt"
FAIL_DOC_PERSIST="${DEBUG_LOG}.fail_doc.txt"

cleanup() {
  [[ "${BASHPID:-$$}" -eq "$MAIN_BASHPID" ]] || return 0
  rm -f "$tmp_fmt" "$tmp_split" "$tmp_xlsx" "$tmp_pptx" "$tmp_doc" "$tmp_vsum" "$tmp_failparse" \
        "$tmp_chat" \
        "$tmp_all" "$tmp_text" "$tmp_rich" "$tmp_chat_list" "$tmp_xlsx_list" "$tmp_pptx_list" "$tmp_doc_list" \
        "$tmp_bad_rich" "$tmp_stats_json" "$tmp_rc2" "$tmp_mc" \
        "$tmp_err_text" "$tmp_err_rich" "$tmp_err_chat" "$tmp_err_xlsx" "$tmp_err_pptx" "$tmp_err_doc"
  rm -rf "$tmp_shards_root"
}
trap cleanup EXIT

# Formatter: prints matches and writes match_count
cat >"$tmp_fmt" <<'PY'
import json, re, sys

before = int(sys.argv[1])
after  = int(sys.argv[2])
ctx_lines = int(sys.argv[3])
match_count_path = sys.argv[4]

token_re = re.compile(r"\S+")
RED   = "\x1b[31m"
GREEN = "\x1b[32m"
RESET = "\x1b[0m"

match_no = 0

def byte_to_char_index(s: str, byte_idx: int) -> int:
  if byte_idx <= 0:
    return 0
  b = 0
  for i, ch in enumerate(s):
    b += len(ch.encode("utf-8"))
    if b >= byte_idx:
      return i + 1
  return len(s)

def tokens_with_spans(s: str):
  return [(m.start(), m.end()) for m in token_re.finditer(s)]

files = {}

def get_path(obj):
  d = obj.get("data", {})
  p = d.get("path", {})
  return p.get("text")

for raw in sys.stdin:
  raw = raw.strip()
  if not raw:
    continue
  try:
    obj = json.loads(raw)
  except json.JSONDecodeError:
    continue

  typ = obj.get("type")
  path = get_path(obj)
  if not path:
    continue

  if typ == "begin":
    files[path] = {"lines": {}, "matches": []}
    continue

  if path not in files:
    files[path] = {"lines": {}, "matches": []}

  data = obj.get("data", {})

  if typ in ("match", "context"):
    line_no = data.get("line_number")
    text = data.get("lines", {}).get("text", "")
    if line_no is not None:
      files[path]["lines"][int(line_no)] = text.rstrip("\n")

    if typ == "match":
      for sub in data.get("submatches", []):
        files[path]["matches"].append({
          "line_no": int(line_no) if line_no is not None else None,
          "start_b": int(sub.get("start", 0)),
          "end_b": int(sub.get("end", 0)),
          "mtxt": sub.get("match", {}).get("text", "") or "",
        })

  elif typ == "end":
    buf = files.get(path)
    if not buf:
      continue

    lines_map = buf["lines"]
    matches = buf["matches"]
    all_line_nos = sorted(lines_map.keys())

    for m in matches:
      ln = m["line_no"]
      if ln is None:
        continue

      local_nos = [n for n in all_line_nos if abs(n - ln) <= ctx_lines]
      if not local_nos:
        continue

      starts = {}
      parts = []
      pos = 0
      for n in local_nos:
        starts[n] = pos
        t = lines_map.get(n, "")
        parts.append(t)
        pos += len(t) + 1
      combined = " ".join(parts)

      line_text = lines_map.get(ln, "")
      s_char = byte_to_char_index(line_text, m["start_b"])
      e_char = byte_to_char_index(line_text, m["end_b"])
      if e_char < s_char:
        s_char, e_char = e_char, s_char

      base = starts.get(ln, 0)
      m_start = base + s_char
      m_end   = base + e_char

      toks = tokens_with_spans(combined)
      if not toks:
        continue

      idx = None
      for i, (a, b) in enumerate(toks):
        if b > m_start and a < m_end:
          idx = i
          break
      if idx is None:
        idx = 0
        for i, (a, _) in enumerate(toks):
          if a >= m_start:
            idx = i
            break

      lo = max(0, idx - before)
      hi = min(len(toks), idx + after + 1)

      snippet = " ".join(combined[a:b] for (a, b) in toks[lo:hi])

      mtxt = m.get("mtxt", "")
      if mtxt:
        snippet = snippet.replace(mtxt, f"{RED}{mtxt}{RESET}", 1)

      match_no += 1
      print(f"{GREEN}{match_no}{RESET} {path}:{ln}: {snippet}\n")

    files.pop(path, None)

try:
  with open(match_count_path, "w", encoding="utf-8") as f:
    f.write(str(match_no))
except Exception:
  pass
PY

# XLSX extractor: prints traceback and returns nonzero on failure
cat >"$tmp_xlsx" <<'PY'
import sys, traceback

def main():
  try:
    from xlsx2csv import Xlsx2csv
  except Exception:
    traceback.print_exc()
    return 2

  if len(sys.argv) != 2:
    print("xlsx-preproc: expected exactly 1 arg: path", file=sys.stderr)
    return 2

  try:
    Xlsx2csv(sys.argv[1]).convert(sys.stdout, sheetid=0)
  except Exception:
    traceback.print_exc()
    return 2
  return 0

if __name__ == "__main__":
  raise SystemExit(main())
PY

# PPTX extractor: prints traceback and returns nonzero on failure
cat >"$tmp_pptx" <<'PY'
import sys, traceback

def main():
  try:
    from pptx import Presentation
  except Exception:
    traceback.print_exc()
    return 2

  if len(sys.argv) != 2:
    print("pptx-preproc: expected exactly 1 arg: path", file=sys.stderr)
    return 2

  try:
    prs = Presentation(sys.argv[1])
  except Exception:
    traceback.print_exc()
    return 2

  out = sys.stdout
  try:
    for si, slide in enumerate(prs.slides, start=1):
      out.write(f"--- slide {si} ---\n")
      for shape in slide.shapes:
        text = getattr(shape, "text", None)
        if text:
          out.write(text)
          if not text.endswith("\n"):
            out.write("\n")
  except Exception:
    traceback.print_exc()
    return 2
  return 0

if __name__ == "__main__":
  raise SystemExit(main())
PY

# DOC extractor: do not suppress stderr so failure logs can capture it
cat >"$tmp_doc" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
f="${1:-}"
[[ -n "$f" ]] || exit 2

if command -v antiword >/dev/null 2>&1; then
  antiword "$f"
  exit 0
fi
if command -v catdoc >/dev/null 2>&1; then
  catdoc "$f"
  exit 0
fi

echo "doc-preproc: neither antiword nor catdoc available" >&2
exit 2
SH
chmod +x "$tmp_doc"

cat >"$tmp_chat" <<'PY'
import os, sys, json, re, html
from html.parser import HTMLParser
from datetime import datetime, timezone

KEEP_TS = os.environ.get("CHAT_KEEP_TS", "1").lower() not in {"0", "false", "no", "off"}

def norm_text(s: str) -> str:
  return " ".join((s or "").replace("\r", "").replace("\n", " ").split())

def emit_line(ts: str, sender: str, source: str, text: str, msg_id=None):
  pieces = []
  if KEEP_TS and ts:
    pieces.append(ts)
  if sender:
    pieces.append(sender)
  tag = source
  if msg_id:
    tag = f"{source}:id={msg_id}"
  if tag:
    pieces.append(tag)
  pieces.append(text if text is not None else "")
  print(" | ".join(pieces))

# ---------- Telegram HTML ----------
class TelegramHTMLParser(HTMLParser):
  def __init__(self):
    super().__init__()
    self.in_msg = False
    self.msg_depth = 0
    self.depth = 0
    self.cur = None
    self.field = None
    self.emitted = 0

  def handle_starttag(self, tag, attrs):
    self.depth += 1
    attrs = dict(attrs)
    cls = attrs.get("class", "") or ""
    if tag == "div" and ((" message" in f" {cls} ") or cls.startswith("message")) and attrs.get("id", "").startswith("message"):
      self.flush()
      self.in_msg = True
      self.msg_depth = self.depth
      self.cur = {"id": attrs.get("id"), "sender": [], "text": [], "ts": None}
      self.field = None
      return
    if not self.in_msg:
      return
    if self.in_msg and tag in {"img", "video", "audio"}:
      if self.cur is not None:
        self.cur["text"].append(f"[{tag}]")
    if self.in_msg and "media_wrap" in cls:
      if self.cur is not None:
        self.cur["text"].append("[media]")
    if tag == "div":
      if "from_name" in cls:
        self.field = "sender"
      elif cls.strip() == "text" or "text " in f"{cls} ":
        self.field = "text"
      elif "date" in cls and attrs.get("title"):
        self.cur["ts"] = attrs.get("title")
    if tag == "br" and self.field == "text":
      self.cur["text"].append("\n")

  def handle_endtag(self, tag):
    if self.in_msg and self.depth == self.msg_depth:
      self.flush()
      self.in_msg = False
      self.field = None
    self.depth = max(0, self.depth - 1)
    if self.field and tag == "div":
      self.field = None

  def handle_data(self, data):
    if not (self.in_msg and self.field):
      return
    if self.field == "sender":
      self.cur["sender"].append(data)
    elif self.field == "text":
      self.cur["text"].append(data)

  def flush(self):
    if not self.cur:
      return
    sender = norm_text("".join(self.cur.get("sender", [])))
    text = norm_text("".join(self.cur.get("text", [])))
    msg_id = self.cur.get("id")
    ts = self.cur.get("ts") or ""
    if ts and " " in ts and "T" not in ts:
      ts = ts.replace(" ", "T", 1)
    emit_line(ts, sender, "telegram_html", text, msg_id=msg_id)
    self.emitted += 1
    self.cur = None

def parse_telegram_html(path: str) -> bool:
  try:
    raw = open(path, "r", encoding="utf-8", errors="ignore").read()
  except Exception:
    return False
  if 'class="message' not in raw and "class='message" not in raw:
    return False
  parser = TelegramHTMLParser()
  parser.feed(raw)
  parser.close()
  return parser.emitted > 0

# ---------- Telegram JSON ----------
def flatten_telegram_text(text_field):
  if isinstance(text_field, str):
    return text_field
  if isinstance(text_field, list):
    parts = []
    for item in text_field:
      if isinstance(item, str):
        parts.append(item)
      elif isinstance(item, dict):
        val = item.get("text")
        if val:
          parts.append(str(val))
    return "".join(parts)
  return ""

def parse_telegram_json(path: str) -> bool:
  try:
    obj = json.load(open(path, "r", encoding="utf-8"))
  except Exception:
    return False
  msgs = obj.get("messages")
  if not isinstance(msgs, list):
    return False
  emitted = 0
  for msg in msgs:
    if not isinstance(msg, dict):
      continue
    text = flatten_telegram_text(msg.get("text", ""))
    if not text:
      mt = msg.get("media_type") or msg.get("type")
      if mt:
        text = f"[{mt}]"
    sender = msg.get("from", "") or msg.get("actor", "")
    ts = msg.get("date")
    emit_line(ts or "", sender or "", "telegram_json", norm_text(text), msg.get("id"))
    emitted += 1
  return emitted > 0

# ---------- Messenger JSON ----------
def ts_from_ms(ms):
  try:
    dt = datetime.fromtimestamp(int(ms)/1000, tz=timezone.utc)
    return dt.isoformat().replace("+00:00", "Z")
  except Exception:
    return ""

def parse_messenger_json(path: str) -> bool:
  try:
    obj = json.load(open(path, "r", encoding="utf-8"))
  except Exception:
    return False
  msgs = obj.get("messages")
  if not isinstance(msgs, list):
    return False
  emitted = 0
  for msg in reversed(msgs):
    if not isinstance(msg, dict):
      continue
    sender = msg.get("sender_name", "")
    text = msg.get("content")
    attachments = msg.get("photos") or msg.get("videos") or msg.get("files") or []
    if attachments and not text:
      labels = []
      for att in attachments:
        if isinstance(att, dict) and att.get("uri"):
          labels.append(f"[{att.get('uri').split('/')[-1]}]")
      text = " ".join(labels) if labels else "[attachment]"
    emit_line(ts_from_ms(msg.get("timestamp_ms")), sender or "", "messenger_json", norm_text(text or ""), msg.get("message_id"))
    emitted += 1
  return emitted > 0

# ---------- WhatsApp TXT ----------
WA_RE = re.compile(r"^\[?(\d{1,2}/\d{1,2}/\d{2,4}),\s+([^\]]+?)\]?\s+-\s+([^:]+):\s*(.*)$")

def parse_wa_ts(datestr, timestr):
  for fmt in ("%m/%d/%y %I:%M %p", "%d/%m/%Y %H:%M", "%m/%d/%Y %I:%M %p", "%d/%m/%y %I:%M %p", "%m/%d/%y %H:%M"):
    try:
      dt = datetime.strptime(f"{datestr} {timestr}".strip(), fmt)
      return dt.isoformat()
    except Exception:
      continue
  return f"{datestr} {timestr}"

def parse_whatsapp_txt(path: str) -> bool:
  try:
    lines = open(path, "r", encoding="utf-8", errors="ignore").read().splitlines()
  except Exception:
    return False
  messages = []
  cur = None
  for line in lines:
    m = WA_RE.match(line)
    if m:
      if cur:
        messages.append(cur)
      cur = {
        "ts": parse_wa_ts(m.group(1), m.group(2)),
        "sender": m.group(3).strip(),
        "text": m.group(4).strip()
      }
    else:
      if cur:
        cur["text"] += " " + line.strip()
  if cur:
    messages.append(cur)
  if len(messages) < 2:
    return False
  for msg in messages:
    emit_line(msg.get("ts", ""), msg.get("sender", ""), "whatsapp_txt", norm_text(msg.get("text", "")))
  return True

def main():
  if len(sys.argv) != 2:
    print("chat-preproc: expected exactly 1 arg: path", file=sys.stderr)
    return 2
  path = sys.argv[1]
  handlers = (parse_telegram_json, parse_telegram_html, parse_messenger_json, parse_whatsapp_txt)
  for fn in handlers:
    try:
      if fn(path):
        return 0
    except Exception:
      continue
  # Fallback: pass-through
  try:
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
      for line in f:
        sys.stdout.write(line)
    return 0
  except Exception:
    return 2

if __name__ == "__main__":
  raise SystemExit(main())
PY

# Enumerate all files (always include hidden, so verbose can report hidden-excluded counts)
: >"$tmp_all"
for p in "${PATHS[@]}"; do
  if [[ -f "$p" ]]; then
    printf '%s\0' "$p" >>"$tmp_all"
  elif [[ -d "$p" ]]; then
    FD_ARGS=(-0 -t f -H)
    [[ "$NO_IGNORE" -eq 1 ]] && FD_ARGS+=(--no-ignore)
    fd "${FD_ARGS[@]}" . "$p" 2>/dev/null >>"$tmp_all" || true
  fi
done

# Split + stats
cat >"$tmp_split" <<'PY'
import os, sys, json

all_path = sys.argv[1]
out_text = sys.argv[2]
out_rich = sys.argv[3]
out_chat = sys.argv[4]
out_xlsx = sys.argv[5]
out_pptx = sys.argv[6]
out_doc  = sys.argv[7]
bad_rich_txt = sys.argv[8]
stats_json = sys.argv[9]

mode = sys.argv[10]
filter_exts = set([x.strip().lower() for x in sys.argv[11].split(",") if x.strip()])
have_rga_preproc = (sys.argv[12] == "1")
min_rich_size = int(sys.argv[13])
search_hidden = (sys.argv[14] == "1")
chat_mode = (sys.argv[15] == "1")

RICH_EXTS = {"pdf","docx","sqlite","sqlite3","db","db3"}
XLSX_EXTS = {"xlsx","xls"}
PPTX_EXTS = {"pptx","ppt"}
DOC_EXTS  = {"doc"}

OFFICE_TEMP_EXTS = {"docx","xlsx","pptx","xls","ppt"}
CHAT_HTML_EXTS = {"html","htm"}
CHAT_JSON_EXTS = {"json"}
CHAT_TXT_EXTS = {"txt"}

def is_hidden_path(p: str) -> bool:
  # Same semantics as your audit: any path segment starting with "."
  parts = p.split(os.sep)
  for part in parts:
    if part and part not in (".", "..") and part.startswith("."):
      return True
  return False

def get_ext(path: str) -> str:
  base = os.path.basename(path)
  if base.startswith(".") and base.count(".") == 1:
    return "(dotfile)"
  _, ext = os.path.splitext(base)
  return ext[1:].lower() if ext else "(none)"

def allowed(ext: str) -> bool:
  if mode == "all":
    return True
  if mode == "whitelist":
    return ext in filter_exts
  if mode == "blacklist":
    return ext not in filter_exts
  return True

def is_office_temp(path: str, ext: str) -> bool:
  base = os.path.basename(path)
  return base.startswith("~$") and (ext in OFFICE_TEMP_EXTS)

def size_ok(path: str) -> bool:
  try:
    return os.path.getsize(path) >= min_rich_size
  except Exception:
    return False

def write_nul(fh, s: str):
  fh.write(s.encode("utf-8", "surrogateescape"))
  fh.write(b"\0")

SNIFF_LIMIT = 65536
sniff_cache = {}
def sniff(path: str) -> bytes:
  if path in sniff_cache:
    return sniff_cache[path]
  data = b""
  try:
    with open(path, "rb") as f:
      data = f.read(SNIFF_LIMIT)
  except Exception:
    data = b""
  sniff_cache[path] = data
  return data

def looks_like_telegram_html(s: bytes) -> bool:
  t = s.lower()
  return (b'class=\"message' in t and b'id=\"message' in t)

def looks_like_telegram_json(obj) -> bool:
  return isinstance(obj, dict) and isinstance(obj.get("messages"), list)

def looks_like_messenger_json(obj) -> bool:
  if not (isinstance(obj, dict) and isinstance(obj.get("messages"), list)):
    return False
  msgs = obj.get("messages") or []
  if not msgs:
    return False
  first = msgs[0]
  return isinstance(first, dict) and "timestamp_ms" in first and "sender_name" in first

def looks_like_whatsapp_txt(s: bytes) -> bool:
  # Look for typical WhatsApp prefix "[1/1/23, 10:00 AM] Name: ..."
  first = s.splitlines()[:10]
  for line in first:
    l = line.decode("utf-8", "ignore")
    if l.startswith("[") or l[:2].isdigit():
      if ":" in l and "-" in l:
        return True
  return False

def should_route_chat(path: str, ext: str, lazy_sniff) -> bool:
  p_low = path.lower()
  base = os.path.basename(p_low)

  if ext in CHAT_HTML_EXTS:
    return True

  if ext in CHAT_JSON_EXTS:
    if base.startswith(("message", "messages", "result")) or "messages" in p_low:
      return True
    try:
      import json as _json
      data = lazy_sniff()
      obj = _json.loads(data.decode("utf-8", "ignore"))
      if looks_like_telegram_json(obj) or looks_like_messenger_json(obj):
        return True
    except Exception:
      pass
    return False

  if ext in CHAT_TXT_EXTS:
    if "whatsapp" in p_low or "chat" in base:
      return True
    if looks_like_whatsapp_txt(lazy_sniff()):
      return True
  return False

stats = {}
def st(ext: str):
  d = stats.get(ext)
  if d is None:
    d = {
      "seen": 0,
      "attempted": 0,          # will be passed to rg/preproc
      "hidden_skipped": 0,     # excluded because hidden and SEARCH_HIDDEN=0
      "blacklisted": 0,        # extension-filtered (blisted) among eligible (non-hidden when SEARCH_HIDDEN=0)
      "skipped_own": 0,        # skipped by our heuristics
      "skipped_bad_rich": 0,
      "skipped_encrypted": 0,
    }
    stats[ext] = d
  return d

raw = b""
try:
  raw = open(all_path, "rb").read()
except Exception:
  pass

paths = [p for p in raw.split(b"\0") if p]
bad = []

with open(out_text, "wb") as ft, open(out_rich, "wb") as fr, open(out_chat, "wb") as fc, open(out_xlsx, "wb") as fx, open(out_pptx, "wb") as fp, open(out_doc, "wb") as fd:
  for pb in paths:
    try:
      p = pb.decode("utf-8", "surrogateescape")
    except Exception:
      continue
    if not p:
      continue

    ext = get_ext(p)
    sd = st(ext)
    sd["seen"] += 1

    # IMPORTANT ORDERING FIX:
    # If SEARCH_HIDDEN=0, count ALL hidden files here (regardless of whitelist/blacklist),
    # and do NOT also count them as blacklisted.
    if (not search_hidden) and is_hidden_path(p):
      sd["hidden_skipped"] += 1
      continue

    # Now apply extension mode filtering to the remaining (non-hidden when SEARCH_HIDDEN=0).
    if not allowed(ext):
      sd["blacklisted"] += 1
      continue

    # Ignore Office temp/lock files for docx/xlsx/pptx (only after hidden gate, so they don't distort hidden)
    if is_office_temp(p, ext):
      sd["skipped_own"] += 1
      sd["skipped_bad_rich"] += 1
      bad.append(f"skip-office-temp(~$): {p}")
      continue

    sniff_data = [None]
    def lazy_sniff():
      if sniff_data[0] is None:
        sniff_data[0] = sniff(p)
      return sniff_data[0]

    if chat_mode and should_route_chat(p, ext, lazy_sniff):
      sd["attempted"] += 1
      write_nul(fc, p)
      continue

    if ext in XLSX_EXTS:
      write_nul(fx, p); sd["attempted"] += 1; continue
    if ext in PPTX_EXTS:
      write_nul(fp, p); sd["attempted"] += 1; continue
    if ext in DOC_EXTS:
      write_nul(fd, p); sd["attempted"] += 1; continue

    if ext in RICH_EXTS:
      if not have_rga_preproc:
        write_nul(ft, p); sd["attempted"] += 1; continue

      # <128-byte check applies to ALL rich types, INCLUDING PDF
      if not size_ok(p):
        sd["skipped_own"] += 1; sd["skipped_bad_rich"] += 1
        bad.append(f"skip-rich(small<{min_rich_size}): {p}")
        continue

      # PDF validation/encryption heuristics remain disabled; pass to rga-preproc
      write_nul(fr, p); sd["attempted"] += 1; continue

    write_nul(ft, p); sd["attempted"] += 1

with open(bad_rich_txt, "w", encoding="utf-8", errors="replace") as bf:
  for line in bad:
    bf.write(line + "\n")

out = {
  "mode": mode,
  "have_rga_preproc": have_rga_preproc,
  "min_rich_size": min_rich_size,
  "search_hidden": search_hidden,
  "ext_stats": stats
}
try:
  with open(stats_json, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False)
except Exception:
  pass

print("split: done", file=sys.stderr)
if bad:
  print(f"split: skipped_bad_rich={len(bad)} (see {bad_rich_txt})", file=sys.stderr)
PY

if [[ "$VERBOSE" -eq 1 ]]; then
  {
    echo "window: -B $BEFORE -A $AFTER ; ctx_lines=$CTX_LINES"
    echo "search flags: hidden=$SEARCH_HIDDEN uuu=$SEARCH_UUU binary=$SEARCH_BINARY no_ignore=$NO_IGNORE ucount=$UCOUNT"
    echo "ext filter: mode=$EXT_FILTER_MODE"
    echo "have_rga_preproc=$HAVE_RGA_PREPROC have_xlsx2csv=$HAVE_XLSX2CSV have_pptx=$HAVE_PPTX have_doc=$HAVE_DOC"
    echo "parallel: text=$PAR_TEXT rich=$PAR_RICH xlsx=$PAR_XLSX pptx=$PAR_PPTX doc=$PAR_DOC"
    echo "batch:    text=$BATCH_TEXT rich=$BATCH_RICH xlsx=$BATCH_XLSX pptx=$BATCH_PPTX doc=$BATCH_DOC"
    echo "paths: ${PATHS[*]}"
  } | tee -a "$DEBUG_LOG" >&2
fi

MIN_RICH_SIZE=128
if [[ "$VERBOSE" -eq 1 || "$LOUD" -eq 1 ]]; then
  python3 "$tmp_split" "$tmp_all" "$tmp_text" "$tmp_rich" "$tmp_xlsx_list" "$tmp_pptx_list" "$tmp_doc_list" "$tmp_bad_rich" "$tmp_stats_json" \
    "$EXT_FILTER_MODE" "$(IFS=,; echo "${FILTER_EXTS[*]}")" "$HAVE_RGA_PREPROC" "$MIN_RICH_SIZE" "$SEARCH_HIDDEN" "$CHAT_MODE" 2>&1 | tee -a "$DEBUG_LOG" >&2
else
  python3 "$tmp_split" "$tmp_all" "$tmp_text" "$tmp_rich" "$tmp_xlsx_list" "$tmp_pptx_list" "$tmp_doc_list" "$tmp_bad_rich" "$tmp_stats_json" \
    "$EXT_FILTER_MODE" "$(IFS=,; echo "${FILTER_EXTS[*]}")" "$HAVE_RGA_PREPROC" "$MIN_RICH_SIZE" "$SEARCH_HIDDEN" "$CHAT_MODE" 2>>"$DEBUG_LOG" >/dev/null || true
fi

# Persist bad-rich list to a stable path
if [[ -s "$tmp_bad_rich" ]]; then
  cp -f "$tmp_bad_rich" "$BAD_RICH_PERSIST" 2>/dev/null || true
fi

split_nul_to_shards() {
  local in_list="$1" out_dir="$2" k="$3"
  python3 - "$in_list" "$out_dir" "$k" <<'PY'
import os, sys
in_list, out_dir = sys.argv[1], sys.argv[2]
k = max(1, int(sys.argv[3]))
data = b""
try:
  data = open(in_list, "rb").read()
except Exception:
  pass
paths = [p for p in data.split(b"\0") if p]
fps = [open(os.path.join(out_dir, f"shard_{i}.bin"), "wb") for i in range(k)]
for i, p in enumerate(paths):
  fp = fps[i % k]
  fp.write(p); fp.write(b"\0")
for fp in fps:
  fp.close()
PY
}

supports_wait_np_args() {
  local pidvar=""
  ( sleep 0.01 ) & local p=$!
  if wait -n -p pidvar "$p" 2>/dev/null; then return 0; fi
  wait "$p" 2>/dev/null || true
  return 1
}

RUNNER_HAS_WAIT_NP=0
supports_wait_np_args && RUNNER_HAS_WAIT_NP=1

remove_pid_from_array() {
  local -n _arr="$1"
  local _pid="$2"
  local _new=()
  local x
  for x in "${_arr[@]}"; do
    [[ "$x" == "$_pid" ]] && continue
    _new+=("$x")
  done
  _arr=("${_new[@]}")
}

run_rg_json_parallel() {
  local listfile="$1" par="$2" batch="$3" errfile="$4"
  shift 4
  local -a cmd=("$@")

  [[ -s "$listfile" ]] || return 0
  [[ "$par" -ge 1 ]] || par=1
  [[ "$batch" -ge 1 ]] || batch=64

  local gdir
  gdir="$(mktemp -d -p "$tmp_shards_root" g_shards.XXXXXX)"
  split_nul_to_shards "$listfile" "$gdir" "$par"

  local cmd_q
  cmd_q="$(printf '%q ' "${cmd[@]}")"

  [[ "$VERBOSE" -eq 1 ]] && {
    {
      echo "run_rg_json_parallel: par=$par batch=$batch list=$listfile errfile=$errfile"
      printf '  cmd: %s\n' "$cmd_q"
    } >>"$DEBUG_LOG"
  }

  local -a pids=()
  local -A out_by_pid=()

  local i
  for ((i=0; i<par; i++)); do
    local shard="$gdir/shard_${i}.bin"
    [[ -s "$shard" ]] || continue

    local out="$gdir/out_${i}.jsonl"
    : >"$out"

    (
      xargs -0 -a "$shard" -r -n "$batch" -- bash -c "
        ${cmd_q} \"\$@\"
        ec=\$?
        if [ \"\$ec\" -eq 1 ]; then exit 0; fi
        exit \"\$ec\"
      " bash 1>>"$out" 2>>"$errfile"
    ) &

    local pid="$!"
    pids+=("$pid")
    out_by_pid["$pid"]="$out"
  done

  local any_err=0
  if [[ "$RUNNER_HAS_WAIT_NP" -eq 1 ]]; then
    local -a active=("${pids[@]}")
    local donepid=""
    while [[ "${#active[@]}" -gt 0 ]]; do
      if wait -n -p donepid "${active[@]}"; then :; else any_err=1; fi
      local out="${out_by_pid[$donepid]:-}"
      if [[ -n "$out" && -s "$out" ]]; then
        cat "$out"
        : >"$out"
      fi
      remove_pid_from_array active "$donepid"
    done
  else
    local pid
    for pid in "${pids[@]}"; do
      wait "$pid" || any_err=1
    done
    local pid2
    for pid2 in "${pids[@]}"; do
      local out="${out_by_pid[$pid2]:-}"
      [[ -n "$out" && -s "$out" ]] && cat "$out"
    done
  fi

  rm -rf "$gdir"
  [[ "$any_err" -eq 1 ]] && return 2
  return 0
}

start_ns="$(date +%s%N)"

RG_BASE=(rg "${RG_COMMON[@]}" --json --no-heading -C "$CTX_LINES" --context-separator "")
if [[ "$LOUD" -eq 0 && "$VERBOSE" -eq 0 ]]; then
  RG_BASE+=(--no-messages)
fi

RG_CHAT=("${RG_BASE[@]}" --pre "CHAT_KEEP_TS=$CHAT_KEEP_TS python3 $tmp_chat" -- "$PATTERN")
RG_TEXT=("${RG_BASE[@]}" -- "$PATTERN")
RG_RICH=("${RG_BASE[@]}" --pre "$RGA_PREPROC" -- "$PATTERN")

RG_XLSX=()
[[ "$HAVE_XLSX2CSV" -eq 1 ]] && RG_XLSX=("${RG_BASE[@]}" --pre "python3 $tmp_xlsx" -- "$PATTERN")

RG_PPTX=()
[[ "$HAVE_PPTX" -eq 1 ]] && RG_PPTX=("${RG_BASE[@]}" --pre "python3 $tmp_pptx" -- "$PATTERN")

RG_DOC=()
[[ "$HAVE_DOC" -eq 1 ]] && RG_DOC=("${RG_BASE[@]}" --pre "$tmp_doc" -- "$PATTERN")

(
  set +e
  set +o pipefail

  warn_groups=0

  if [[ "$CHAT_MODE" -eq 1 ]]; then
    run_rg_json_parallel "$tmp_chat_list" "$PAR_TEXT" "$BATCH_TEXT" "$tmp_err_chat" "${RG_CHAT[@]}"; r=$?
    [[ "$r" -ge 2 ]] && warn_groups=$((warn_groups+1))
  fi

  run_rg_json_parallel "$tmp_text" "$PAR_TEXT" "$BATCH_TEXT" "$tmp_err_text" "${RG_TEXT[@]}"; r=$?
  [[ "$r" -ge 2 ]] && warn_groups=$((warn_groups+1))

  if [[ -s "$tmp_rich" && "$HAVE_RGA_PREPROC" -eq 1 ]]; then
    run_rg_json_parallel "$tmp_rich" "$PAR_RICH" "$BATCH_RICH" "$tmp_err_rich" "${RG_RICH[@]}"; r=$?
    [[ "$r" -ge 2 ]] && warn_groups=$((warn_groups+1))
  fi

  if [[ ${#RG_XLSX[@]} -gt 0 ]]; then
    run_rg_json_parallel "$tmp_xlsx_list" "$PAR_XLSX" "$BATCH_XLSX" "$tmp_err_xlsx" "${RG_XLSX[@]}"; r=$?
    [[ "$r" -ge 2 ]] && warn_groups=$((warn_groups+1))
  fi

  if [[ ${#RG_PPTX[@]} -gt 0 ]]; then
    run_rg_json_parallel "$tmp_pptx_list" "$PAR_PPTX" "$BATCH_PPTX" "$tmp_err_pptx" "${RG_PPTX[@]}"; r=$?
    [[ "$r" -ge 2 ]] && warn_groups=$((warn_groups+1))
  fi

  if [[ ${#RG_DOC[@]} -gt 0 ]]; then
    run_rg_json_parallel "$tmp_doc_list" "$PAR_DOC" "$BATCH_DOC" "$tmp_err_doc" "${RG_DOC[@]}"; r=$?
    [[ "$r" -ge 2 ]] && warn_groups=$((warn_groups+1))
  fi

  echo "$warn_groups" >"$tmp_rc2"
  exit 0
) | python3 "$tmp_fmt" "$BEFORE" "$AFTER" "$CTX_LINES" "$tmp_mc"

end_ns="$(date +%s%N)"

python3 - <<PY
start = int("$start_ns")
end = int("$end_ns")
elapsed = max(0, end - start)
print(f"Time taken: {elapsed / 1_000_000_000:.3f}s")
PY

match_count=0
[[ -s "$tmp_mc" ]] && match_count="$(cat "$tmp_mc" 2>/dev/null || echo 0)"

warn_groups=0
[[ -s "$tmp_rc2" ]] && warn_groups="$(cat "$tmp_rc2" 2>/dev/null || echo 0)"

# ------------------------------------------------------------
# Fail logs: include multi-line detail blocks
# ------------------------------------------------------------
cat >"$tmp_failparse" <<'PY'
import sys, re

in_err, out_fail = sys.argv[1], sys.argv[2]
rx_start = re.compile(r'^\s*rg:\s+(.*?):\s+(.*)$', re.IGNORECASE)

records = []
cur_path = None
cur_lines = []

def flush():
  global cur_path, cur_lines
  if cur_path is not None:
    seen = set()
    out = []
    for ln in cur_lines:
      if ln not in seen:
        seen.add(ln)
        out.append(ln)
    records.append((cur_path, out))
  cur_path = None
  cur_lines = []

try:
  with open(in_err, "r", encoding="utf-8", errors="replace") as f:
    for raw in f:
      line = raw.rstrip("\n")
      m = rx_start.match(line)
      if m:
        flush()
        cur_path = m.group(1).strip()
        cur_lines.append(m.group(2).strip())
      else:
        if cur_path is not None and line.strip() != "":
          cur_lines.append(line)
except FileNotFoundError:
  pass
except Exception:
  pass

flush()

with open(out_fail, "w", encoding="utf-8", errors="replace") as out:
  for p, lines in records:
    out.write(p + "\n")
    for ln in lines:
      out.write("  " + ln + "\n")
    out.write("----\n")
PY

python3 "$tmp_failparse" "$tmp_err_text" "$FAIL_TEXT_PERSIST" || true
python3 "$tmp_failparse" "$tmp_err_chat" "$FAIL_CHAT_PERSIST" || true
python3 "$tmp_failparse" "$tmp_err_rich" "$FAIL_RICH_PERSIST" || true
python3 "$tmp_failparse" "$tmp_err_xlsx" "$FAIL_XLSX_PERSIST" || true
python3 "$tmp_failparse" "$tmp_err_pptx" "$FAIL_PPTX_PERSIST" || true
python3 "$tmp_failparse" "$tmp_err_doc"  "$FAIL_DOC_PERSIST"  || true

if [[ -s "$BAD_RICH_PERSIST" && ( "$LOUD" -eq 1 || "$VERBOSE" -eq 1 ) ]]; then
  echo "[g] note: some files were skipped by heuristics; see: $BAD_RICH_PERSIST" >&2
fi
if [[ "$warn_groups" -gt 0 ]]; then
  echo "[g] warnings: ${warn_groups} group(s) reported rc>=2 at least once (extraction/IO errors). Matches (if any) were still reported." >&2
  echo "[g] failed-file logs:" >&2
  echo "  $FAIL_TEXT_PERSIST" >&2
  echo "  $FAIL_CHAT_PERSIST" >&2
  echo "  $FAIL_RICH_PERSIST" >&2
  echo "  $FAIL_XLSX_PERSIST" >&2
  echo "  $FAIL_PPTX_PERSIST" >&2
  echo "  $FAIL_DOC_PERSIST" >&2
fi

# ------------------------------------------------------------
# Verbose end-of-run summary
# ------------------------------------------------------------
if [[ "$VERBOSE" -eq 1 ]]; then
cat >"$tmp_vsum" <<'PY'
import json, os, sys
from collections import defaultdict

stats_path, fail_text, fail_chat, fail_rich, fail_doc, fail_xlsx, fail_pptx = sys.argv[1:8]

def ext_of(path: str) -> str:
  base = os.path.basename(path)
  if base.startswith(".") and base.count(".") == 1:
    return "(dotfile)"
  _, ext = os.path.splitext(base)
  return ext[1:].lower() if ext else "(none)"

ext_stats = {}
try:
  with open(stats_path, "r", encoding="utf-8") as f:
    obj = json.load(f)
  ext_stats = obj.get("ext_stats", {}) or {}
except Exception:
  ext_stats = {}

fail = defaultdict(int)
def ingest_fail(p):
  try:
    with open(p, "r", encoding="utf-8", errors="replace") as f:
      while True:
        path = f.readline()
        if not path:
          break
        path = path.rstrip("\n")
        if not path:
          continue
        fail[ext_of(path)] += 1
        for line in f:
          if line.strip() == "----":
            break
  except Exception:
    pass

ingest_fail(fail_text)
ingest_fail(fail_chat)
ingest_fail(fail_rich)
ingest_fail(fail_doc)
ingest_fail(fail_xlsx)
ingest_fail(fail_pptx)

rows = []
tot_scanned = tot_hidden = tot_blisted = tot_skipped = tot_skipped_rg = tot_failed = 0
tot_files = 0

all_exts = set(ext_stats.keys()) | set(fail.keys())

for ext in all_exts:
  d = ext_stats.get(ext, {}) or {}

  seen = int(d.get("seen", 0) or 0)
  tot_files += seen

  scanned = int(d.get("attempted", 0) or 0)
  hidden  = int(d.get("hidden_skipped", 0) or 0)
  blisted = int(d.get("blacklisted", 0) or 0)
  skipped = int(d.get("skipped_own", 0) or 0)
  skipped_rg = 0
  failed  = int(fail.get(ext, 0) or 0)

  if (scanned + hidden + blisted + skipped + failed + skipped_rg) <= 0:
    continue

  rows.append((ext, scanned, hidden, blisted, skipped, skipped_rg, failed))

  tot_scanned += scanned
  tot_hidden  += hidden
  tot_blisted += blisted
  tot_skipped += skipped
  tot_skipped_rg += skipped_rg
  tot_failed += failed

def key(r):
  ext, scn, hid, bl, sk, skr, fl = r
  tot = scn + hid + bl + sk + skr
  return (-tot, -scn, -hid, -bl, -sk, -skr, -fl, ext)

rows.sort(key=key)

TOPN = 100
other = [0,0,0,0,0,0]
W = 7

def fmt_cell(s): return f"{s:>{W}}"
def fmt_ext(s): return (s[:W]).ljust(W)

print("\n---- scan totals ----")
print(f"files:     {tot_files}")
print(f"scanned:   {tot_scanned}")
print(f"hidden:    {tot_hidden}")
print(f"blisted:   {tot_blisted}")
print(f"skipped:   {tot_skipped}")
print(f"skipped_rg:{tot_skipped_rg}")
print(f"failed:    {tot_failed}")
print("---- end scan totals ----\n")

print("---- per-extension scan summary (top 100) ----")
print(f"{'ext':<{W}} {fmt_cell('scanned')} {fmt_cell('hidden')} {fmt_cell('blisted')} {fmt_cell('skipped')} {fmt_cell('skp_rg')} {fmt_cell('failed')}")

for i, (ext, scn, hid, bl, sk, skr, fl) in enumerate(rows, start=1):
  if i <= TOPN:
    print(f"{fmt_ext(ext)} {scn:>{W}d} {hid:>{W}d} {bl:>{W}d} {sk:>{W}d} {skr:>{W}d} {fl:>{W}d}")
  else:
    other[0] += scn
    other[1] += hid
    other[2] += bl
    other[3] += sk
    other[4] += skr
    other[5] += fl

if len(rows) > TOPN:
  print(f"{fmt_ext('other')} {other[0]:>{W}d} {other[1]:>{W}d} {other[2]:>{W}d} {other[3]:>{W}d} {other[4]:>{W}d} {other[5]:>{W}d}")

print("---- end per-extension scan summary ----\n")
PY

  python3 "$tmp_vsum" "$tmp_stats_json" "$FAIL_TEXT_PERSIST" "$FAIL_CHAT_PERSIST" "$FAIL_RICH_PERSIST" "$FAIL_DOC_PERSIST" "$FAIL_XLSX_PERSIST" "$FAIL_PPTX_PERSIST" \
    | tee -a "$DEBUG_LOG" >&2
fi

if [[ "$match_count" -gt 0 ]]; then
  echo "Search exit code (overall): 0"
  exit 0
else
  echo "Search exit code (overall): 1"
  exit 1
fi
