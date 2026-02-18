#!/usr/bin/env bash
set -euo pipefail

MAIN_BASHPID="${BASHPID:-$$}"

BEFORE=10
AFTER=10
VERBOSE=0
AUDIT=0
AUDIT_SIZES=0
CHAT_MODE=0
CHAT_KEEP_TS=1
CHAT_PREFILTER="${G_CHAT_PREFILTER:-1}"
CHAT_CACHE_DIR=""
MERGE_MODE=0
PAGE=0
PAGE_SIZE=10
ALLOW_BROKEN_PIPE=0
NOCHAT=0

SEARCH_HIDDEN=0
SEARCH_UUU=0
SEARCH_BINARY=0
FIXED_STRINGS=0
NO_IGNORE=0
UCOUNT=0
CASE_SENSITIVE=0
COUNTS_ONLY=0
A_GIVEN=0
B_GIVEN=0
BEFORE_TO_LINE_START=0

EXT_FILTER_MODE="all"  # all|whitelist|blacklist

# Resolve true script directory (handling symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

LOG_DIR="${G_LOG_DIR:-$SCRIPT_DIR}"
FAIL_LOG="${G_FAIL_LOG:-$LOG_DIR/g.fail.log}"
SKIP_LOG="${G_SKIP_LOG:-$LOG_DIR/g.skipped.log}"
MATCH_FILES_LOG="${G_MATCH_FILES_LOG:-$LOG_DIR/g.match_files.log}"

case "${CHAT_PREFILTER,,}" in
  0|false|no|off) CHAT_PREFILTER=0 ;;
  *) CHAT_PREFILTER=1 ;;
esac

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
  g --audit [--sizes] [PATH...]
  g [--hidden] [-l|--literal] [-u|-uu|-uuu] [--no_ignore] [--binary] [--nochat] [--whitelist|--blacklist] [--counts] [--chat-cache[=DIR]] [--page N] [--page-size N] [-B N] [-A N] [-C N] [-v] PATTERN [PATH...]

Modes:
  --audit        Fast audit: counts hidden vs non-hidden by extension (fd + gawk only)
  --sizes        (audit-only) include apparent-size byte totals per extension (uses du; no content reads)
  search         Searches for PATTERN and prints token-windowed matches.

Search flags:
  --hidden       include hidden files/dirs (fd -H and rg --hidden)
  -l, --literal  make search term literal rather than regex (regex is default)
  -u             include hidden
  -uu            include hidden + no ignore (maps to --no_ignore)
  -uuu           include hidden + no-ignore + binary/text
  --no_ignore    do not respect ignore files (rg --no-ignore, fd --no-ignore)
  --binary       treat binary files as text (rg --text)
  --counts       output only per-file match counts (tsv: count<TAB>path)
  --case-sensitive    force case sensitive search (default: case-insensitive)
  --nochat       exclude files classified as chat from normal search
  --whitelist    only scan extensions in the hardcoded list
  --blacklist    scan everything EXCEPT extensions in the hardcoded list

Pattern:
  PATTERN is a regex (ripgrep); quote backslashes in your shell.
  \x expands to a word token (\b\w+\b).
  Example: '\bayman\b' matches the word ayman.

Options:
  -B N|start     chars before match (default 10; use 'start' for line start)
  -A N           chars after match  (default 10)
  -C N           set both -B and -A to N
                 if only -A is provided, -B defaults to 0
                 if only -B is provided, -A defaults to 0
  -v             verbose (end-of-run per-extension scan summary)
  --chat         search chat exports only (in chat mode -B/-A/-C are numeric message counts)
  --chat-cache[=DIR]  cache parsed chat text for repeated --chat searches (default: /tmp/g_chat_cache)
  --merge        (chat-only) merge repeated hits in the same message; output 1 block per matching message (format like -C 0)
                (deprecated alias: --chat-lines)
  --page N       (chat-only, requires --merge and -C 0) show only page N (default page-size 10); stops search early
  --page-size N  (chat-only) page size for --page (default 10)
  --chat-ts=VAL  keep (keep) or drop (drop) timestamps in chat output (default: keep)
  --chat-prefilter    prefilter chat files with raw rg before parsing (default: on)
  --no-chat-prefilter disable chat prefilter
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
    --audit) AUDIT=1; continue ;;
    --sizes) AUDIT_SIZES=1; continue ;;
    --help) usage; exit 0 ;;
    --hidden) SEARCH_HIDDEN=1; continue ;;
    --binary|--text) SEARCH_BINARY=1; continue ;;
    --no_ignore|--no-ignore) NO_IGNORE=1; continue ;;
    --nochat) NOCHAT=1; continue ;;
    --whitelist) EXT_FILTER_MODE="whitelist"; continue ;;
    --blacklist) EXT_FILTER_MODE="blacklist"; continue ;;
    --chat) CHAT_MODE=1; continue ;;
    --counts) COUNTS_ONLY=1; continue ;;
    --case-sensitive) CASE_SENSITIVE=1; continue ;;
    --literal) FIXED_STRINGS=1; continue ;;
    --chat-prefilter) CHAT_PREFILTER=1; continue ;;
    --no-chat-prefilter) CHAT_PREFILTER=0; continue ;;
    --chat-cache) CHAT_CACHE_DIR="/tmp/g_chat_cache"; continue ;;
	    --chat-cache=*)
	      CHAT_CACHE_DIR="${arg#*=}"
	      [[ -z "$CHAT_CACHE_DIR" ]] && CHAT_CACHE_DIR="/tmp/g_chat_cache"
	      continue ;;
	    --merge) MERGE_MODE=1; continue ;;
	    --chat-lines) MERGE_MODE=1; continue ;;
	    --page)
	      PAGE="${args[$((idx + 1))]:-}"
	      skip_next=1
	      continue ;;
	    --page=*)
	      PAGE="${arg#*=}"
	      continue ;;
	    --page-size)
	      PAGE_SIZE="${args[$((idx + 1))]:-}"
	      skip_next=1
	      continue ;;
	    --page-size=*)
	      PAGE_SIZE="${arg#*=}"
	      continue ;;
	    --chat-prefilter=*)
	      val="${arg#*=}"
	      case "$val" in
	        1|true|yes|on) CHAT_PREFILTER=1 ;;
        0|false|no|off) CHAT_PREFILTER=0 ;;
        *) echo "Error: unknown value for --chat-prefilter (use on|off)" >&2; exit 2 ;;
      esac
      continue ;;
    --chat-ts=*)
      val="${arg#*=}"
      case "$val" in
        keep) CHAT_KEEP_TS=1 ;;
        drop) CHAT_KEEP_TS=0 ;;
        *) echo "Error: unknown value for --chat-ts (use keep|drop)" >&2; exit 2 ;;
      esac
      continue ;;
    --*)
      echo "Error: unknown option $arg" >&2
      usage
      exit 2
      ;;
    -)
      filtered+=("$arg")
      continue
      ;;
    -*)
      short="${arg#-}"
      i=0
      while [[ $i -lt ${#short} ]]; do
        ch="${short:$i:1}"
        case "$ch" in
          u) UCOUNT=$((UCOUNT + 1)) ;;
          l) FIXED_STRINGS=1 ;;
          v) VERBOSE=1 ;;
          h) usage; exit 0 ;;
          B|A|C)
            if [[ $((i + 1)) -lt ${#short} ]]; then
              next_val="${short:$((i + 1))}"
              case "$ch" in
                B)
                  if [[ "${next_val,,}" == "start" ]]; then
                    BEFORE=0
                    BEFORE_TO_LINE_START=1
                  else
                    BEFORE="$next_val"
                    BEFORE_TO_LINE_START=0
                  fi
                  B_GIVEN=1
                  ;;
                A) AFTER="$next_val"; A_GIVEN=1 ;;
                C) BEFORE="$next_val"; AFTER="$next_val"; A_GIVEN=1; B_GIVEN=1; BEFORE_TO_LINE_START=0 ;;
              esac
              i=${#short}
              continue
            fi
            next_idx=$((idx + 1))
            next_val="${args[$next_idx]:-}"
            if [[ -z "$next_val" ]]; then
              echo "Error: option -$ch requires an argument" >&2
              usage
              exit 2
            fi
            case "$ch" in
              B)
                if [[ "${next_val,,}" == "start" ]]; then
                  BEFORE=0
                  BEFORE_TO_LINE_START=1
                else
                  BEFORE="$next_val"
                  BEFORE_TO_LINE_START=0
                fi
                B_GIVEN=1
                ;;
              A) AFTER="$next_val"; A_GIVEN=1 ;;
              C) BEFORE="$next_val"; AFTER="$next_val"; A_GIVEN=1; B_GIVEN=1; BEFORE_TO_LINE_START=0 ;;
            esac
            skip_next=1
            ;;
          *)
            echo "Error: unknown option -$ch" >&2
            usage
            exit 2
            ;;
        esac
        i=$((i + 1))
      done
      continue
      ;;
  esac
  filtered+=("$arg")
done
set -- "${filtered[@]}"

while getopts ":B:A:C:vhul-:" opt; do
  case "$opt" in
    B)
      if [[ "${OPTARG,,}" == "start" ]]; then
        BEFORE=0
        BEFORE_TO_LINE_START=1
      else
        BEFORE="$OPTARG"
        BEFORE_TO_LINE_START=0
      fi
      B_GIVEN=1
      ;;
    A) AFTER="$OPTARG"; A_GIVEN=1 ;;
    C) BEFORE="$OPTARG"; AFTER="$OPTARG"; A_GIVEN=1; B_GIVEN=1; BEFORE_TO_LINE_START=0 ;;
    v) VERBOSE=1 ;;
    h) usage; exit 0 ;;
    u) UCOUNT=$((UCOUNT + 1)) ;;
    l) FIXED_STRINGS=1 ;;
		    -)
		      case "${OPTARG}" in
        help) usage; exit 0 ;;
        audit) AUDIT=1 ;;
        sizes) AUDIT_SIZES=1 ;;
        hidden) SEARCH_HIDDEN=1 ;;
        literal) FIXED_STRINGS=1 ;;
        binary|text) SEARCH_BINARY=1 ;;
        no_ignore|no-ignore) NO_IGNORE=1 ;;
        nochat) NOCHAT=1 ;;
        whitelist) EXT_FILTER_MODE="whitelist" ;;
        blacklist) EXT_FILTER_MODE="blacklist" ;;
        chat) CHAT_MODE=1 ;;
        counts) COUNTS_ONLY=1 ;;
        case-sensitive) CASE_SENSITIVE=1 ;;
	        chat-prefilter) CHAT_PREFILTER=1 ;;
	        no-chat-prefilter) CHAT_PREFILTER=0 ;;
	        chat-cache) CHAT_CACHE_DIR="/tmp/g_chat_cache" ;;
		        chat-cache=*)
		          CHAT_CACHE_DIR="${OPTARG#*=}"
		          [[ -z "$CHAT_CACHE_DIR" ]] && CHAT_CACHE_DIR="/tmp/g_chat_cache"
		          ;;
			        merge) MERGE_MODE=1 ;;
			        chat-lines) MERGE_MODE=1 ;;
			        chat-prefilter=*)
			          val="${OPTARG#*=}"
			          case "$val" in
	            1|true|yes|on) CHAT_PREFILTER=1 ;;
            0|false|no|off) CHAT_PREFILTER=0 ;;
            *) echo "Error: unknown value for --chat-prefilter (use on|off)" >&2; usage; exit 2 ;;
          esac
          ;;
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

# One-sided context: explicitly requested side + opposite side = 0.
# If neither -A nor -B is provided, keep both defaults.
if [[ "$A_GIVEN" -eq 1 && "$B_GIVEN" -eq 0 ]]; then
  BEFORE=0
fi
if [[ "$B_GIVEN" -eq 1 && "$A_GIVEN" -eq 0 ]]; then
  AFTER=0
fi
if [[ "$CHAT_MODE" -eq 1 && "$BEFORE_TO_LINE_START" -eq 1 ]]; then
  echo "Error: -B start is only supported outside --chat mode." >&2
  exit 2
fi

if [[ "$PAGE" != "0" ]]; then
  if [[ "$CHAT_MODE" -ne 1 || "$MERGE_MODE" -ne 1 ]]; then
    echo "Error: --page requires --chat --merge" >&2
    exit 2
  fi
  if [[ "$COUNTS_ONLY" -eq 1 ]]; then
    echo "Error: --page is not compatible with --counts" >&2
    exit 2
  fi
  if ! [[ "$PAGE" =~ ^[0-9]+$ ]] || [[ "$PAGE" -lt 1 ]]; then
    echo "Error: --page must be an integer >= 1" >&2
    exit 2
  fi
  if ! [[ "$PAGE_SIZE" =~ ^[0-9]+$ ]] || [[ "$PAGE_SIZE" -lt 1 ]]; then
    echo "Error: --page-size must be an integer >= 1" >&2
    exit 2
  fi
  if [[ "$BEFORE" -ne 0 || "$AFTER" -ne 0 ]]; then
    echo "Error: --page requires -C 0 (or -B 0 -A 0) so it can stop early after printing a page." >&2
    exit 2
  fi
  ALLOW_BROKEN_PIPE=1
fi

# Apply -u/-uu/-uuu semantics
if [[ "$UCOUNT" -ge 1 ]]; then SEARCH_HIDDEN=1; fi
if [[ "$UCOUNT" -ge 2 ]]; then NO_IGNORE=1; fi
if [[ "$UCOUNT" -ge 3 ]]; then SEARCH_BINARY=1; SEARCH_UUU=1; fi
export CHAT_KEEP_TS
export G_CHAT_CACHE_DIR="$CHAT_CACHE_DIR"
if [[ -n "$CHAT_CACHE_DIR" ]]; then
  mkdir -p "$CHAT_CACHE_DIR" 2>/dev/null || true
fi

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
  txt md rst log csv tsv json jsonl yaml yml toml ini conf cfg xml html htm css
  py sh bash zsh fish c h cpp hpp cc cxx java kt go rs js mjs cjs ts tsx jsx php rb pl
  pdf docx doc xlsx xls pptx ppt sqlite sqlite3 db db3
  "(none)" "(dotfile)"
  cmake mk mak properties lock
  cs ps1 sql proto asm awk sed reg
  inc inl hxx cuh cu
  svg xsd xsl resx manifest
  sln csproj
  spec src ver po config
  pom vcproj vcxproj targets
  diff patch
  tpl tmpl template jinja
  plist xhtml dtd wsdl
  lua swift
  glsl hlsl wgsl shader
  ninja make map lst
)
FD_EXCLUDE_PATTERNS=(
  "remote-server"
)

# rg context lines:
# - non-chat mode uses extra slack so snippet extraction can span multiple lines.
# - chat mode should be tight, otherwise every match carries huge context payload.
if [[ "$CHAT_MODE" -eq 1 ]]; then
  if [[ "$MERGE_MODE" -eq 1 && "$BEFORE" -eq 0 && "$AFTER" -eq 0 ]]; then
    CTX_LINES=0
  else
    CTX_LINES=$(( BEFORE > AFTER ? BEFORE : AFTER ))
  fi
else
  CTX_LINES=$((BEFORE + AFTER + 20))
fi

# -----------------------------
# FAST AUDIT MODE
# -----------------------------
if [[ "$AUDIT" -eq 1 ]]; then
  need_cmd gawk
  [[ "$AUDIT_SIZES" -eq 0 ]] || need_cmd du

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
  for pat in "${FD_EXCLUDE_PATTERNS[@]}"; do
    FD_ARGS+=(--exclude "$pat")
  done
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
  } | {
    if [[ "$AUDIT_SIZES" -eq 1 ]]; then
      # Convert NUL-separated file list to NUL-separated "bytes<TAB>path" lines.
      # --apparent-size uses logical file size (st_size), not blocks used.
      du --files0-from=- --null --apparent-size --block-size=1 -0 2>/dev/null || true
    else
      cat
    fi
  } | gawk -v RS='\0' -v FS='\t' -v MODE="$EXT_FILTER_MODE" -v WLIST="$FILTER_LIST" -v TOPN="1000" -v SIZES="$AUDIT_SIZES" '
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

function bytes_total(e) { return (b_non[e] + b_hid[e]) + 0 }

function cmp(i1, v1, i2, v2,    t1,t2,n1,n2,h1,h2,b1,b2) {
  t1 = (non[i1] + hid[i1]) + 0; t2 = (non[i2] + hid[i2]) + 0
  if (SIZES + 0) {
    b1 = bytes_total(i1); b2 = bytes_total(i2)
    if (b1 != b2) return (b2 > b1) ? 1 : -1
  }
  if (t1 != t2) return (t2 - t1)
  n1 = non[i1] + 0; n2 = non[i2] + 0; if (n1 != n2) return (n2 - n1)
  h1 = hid[i1] + 0; h2 = hid[i2] + 0; if (h1 != h2) return (h2 - h1)
  return (i1 < i2 ? -1 : (i1 > i2 ? 1 : 0))
}
{
  rec = $0; if (rec == "") next
  sz = 0
  p = rec
  if (SIZES + 0) {
    # rec is "bytes<TAB>path" (from du). Strip the first field to recover full path.
    sz = $1 + 0
    sub(/^[0-9]+\t/, "", p)
  }
  e = ext_of(p); hidden = is_hidden_path(p)

  if (hidden) { if (e in wl) wl_hid++; else bl_hid++; } else { if (e in wl) wl_non++; else bl_non++; }

  if (!allowed_for_table(e)) next
  if (hidden) hid[e]++; else non[e]++
  if (SIZES + 0) {
    if (hidden) b_hid[e] += sz; else b_non[e] += sz
  }
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

  if (SIZES + 0) {
    printf "%-*s %-5s %-6s %12s %12s %12s %14s\n", EXT_W, "ext", "wlist", "bucket", "non_hidden", "hidden", "total", "bytes_total"
  } else {
    printf "%-*s %-5s %-6s %12s %12s %12s\n", EXT_W, "ext", "wlist", "bucket", "non_hidden", "hidden", "total"
  }

  nkeys = asorti(seen, ord, "cmp")
  other_non = other_hid = 0
  other_b_non = other_b_hid = 0
  for (i=1; i<=nkeys; i++) {
    e = ord[i]
    nh = non[e] + 0; hh = hid[e] + 0; tot = nh + hh
    if (i <= TOPN) {
      if (SIZES + 0) {
        bt = bytes_total(e)
        printf "%-*s %-5s %-6s %12d %12d %12d %14.0f\n", EXT_W, e, wl_yes(e), bucket_of(e), nh, hh, tot, bt
      } else {
        printf "%-*s %-5s %-6s %12d %12d %12d\n", EXT_W, e, wl_yes(e), bucket_of(e), nh, hh, tot
      }
    } else {
      other_non += nh; other_hid += hh
      if (SIZES + 0) { other_b_non += b_non[e] + 0; other_b_hid += b_hid[e] + 0 }
    }
  }
  if (nkeys > TOPN) {
    if (SIZES + 0) {
      printf "%-*s %-5s %-6s %12d %12d %12d %14.0f\n", EXT_W, "other", "", "", other_non+0, other_hid+0, (other_non+other_hid), (other_b_non+other_b_hid)
    } else {
      printf "%-*s %-5s %-6s %12d %12d %12d\n", EXT_W, "other", "", "", other_non+0, other_hid+0, (other_non+other_hid)
    }
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
if [[ "$FIXED_STRINGS" -eq 0 ]]; then
  PATTERN="$(python3 - "$PATTERN" <<'PY'
import re, sys

pat = sys.argv[1]
pat = re.sub(r'(?<!\\)\\x(?![0-9A-Fa-f{])', r'\\b\\w+\\b', pat)
print(pat)
PY
)"
fi
PATHS=("$@")
[[ ${#PATHS[@]} -gt 0 ]] || PATHS=(".")

if [[ "$FIXED_STRINGS" -eq 1 ]]; then
  RG_COMMON=(--fixed-strings)
else
  RG_COMMON=(--no-fixed-strings)
fi

if [[ "$CASE_SENSITIVE" -eq 0 ]]; then
  RG_COMMON+=(--ignore-case)
fi
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
tmp_aichat_list="$(mktemp -t g_aichat_list.XXXXXX.bin)"
tmp_chat_all="$(mktemp -t g_chat_all.XXXXXX.bin)"
tmp_chat_text_list="$(mktemp -t g_chat_text_list.XXXXXX.bin)"
tmp_chat_bin_list="$(mktemp -t g_chat_bin_list.XXXXXX.bin)"
tmp_chat_prefilter="$(mktemp -t g_chat_prefilter.XXXXXX.bin)"
tmp_xlsx_list="$(mktemp -t g_xlsx_list.XXXXXX.bin)"
tmp_pptx_list="$(mktemp -t g_pptx_list.XXXXXX.bin)"
tmp_doc_list="$(mktemp -t g_doc_list.XXXXXX.bin)"

tmp_bad_rich="$(mktemp -p "$LOG_DIR" g_bad_rich.XXXXXX.txt)"
tmp_stats_json="$(mktemp -p "$LOG_DIR" g_stats.XXXXXX.json)"

tmp_rc2="$(mktemp -t g_rc2.XXXXXX)"
tmp_mc="$(mktemp -t g_mc.XXXXXX)"
tmp_shards_root="$(mktemp -d -t g_shards_root.XXXXXX)"

tmp_err_text="$(mktemp -p "$LOG_DIR" g_err_text.XXXXXX.txt)"
tmp_err_rich="$(mktemp -p "$LOG_DIR" g_err_rich.XXXXXX.txt)"
tmp_err_chat="$(mktemp -p "$LOG_DIR" g_err_chat.XXXXXX.txt)"
tmp_err_chat_prefilter="$(mktemp -p "$LOG_DIR" g_err_chat_prefilter.XXXXXX.txt)"
tmp_err_xlsx="$(mktemp -p "$LOG_DIR" g_err_xlsx.XXXXXX.txt)"
tmp_err_pptx="$(mktemp -p "$LOG_DIR" g_err_pptx.XXXXXX.txt)"
tmp_err_doc="$(mktemp -p "$LOG_DIR" g_err_doc.XXXXXX.txt)"
tmp_skip_rg="$(mktemp -p "$LOG_DIR" g_skip_rg.XXXXXX.txt)"
tmp_fail_out="$(mktemp -p "$LOG_DIR" g_fail_out.XXXXXX.txt)"

FAIL_PERSIST="$FAIL_LOG"
SKIP_PERSIST="$SKIP_LOG"
MATCH_FILES_PERSIST="$MATCH_FILES_LOG"
# Ensure per-run output is never stale (rg --json emits nothing on no matches).
: >"$MATCH_FILES_PERSIST" 2>/dev/null || true

cleanup() {
  [[ "${BASHPID:-$$}" -eq "$MAIN_BASHPID" ]] || return 0
  rm -f "$tmp_fmt" "$tmp_split" "$tmp_xlsx" "$tmp_pptx" "$tmp_doc" "$tmp_vsum" "$tmp_failparse" \
        "$tmp_chat" \
        "$tmp_all" "$tmp_text" "$tmp_rich" "$tmp_chat_list" "$tmp_aichat_list" "$tmp_chat_all" "$tmp_chat_text_list" "$tmp_chat_bin_list" "$tmp_chat_prefilter" "$tmp_xlsx_list" "$tmp_pptx_list" "$tmp_doc_list" \
        "$tmp_bad_rich" "$tmp_stats_json" "$tmp_rc2" "$tmp_mc" "$tmp_skip_rg" \
        "$tmp_err_text" "$tmp_err_rich" "$tmp_err_chat" "$tmp_err_chat_prefilter" "$tmp_err_xlsx" "$tmp_err_pptx" "$tmp_err_doc" "$tmp_fail_out"
  rm -rf "$tmp_shards_root"
}
trap cleanup EXIT

# Formatter: prints matches and writes match_count
cat >"$tmp_fmt" <<'PY'
import json, re, sys, os, subprocess, html
import signal
from html.parser import HTMLParser

signal.signal(signal.SIGPIPE, signal.SIG_DFL)

before = int(sys.argv[1])
after  = int(sys.argv[2])
ctx_lines = int(sys.argv[3])
match_count_path = sys.argv[4]
match_files_path = sys.argv[5] if len(sys.argv) > 5 else ""
chat_mode = (len(sys.argv) > 6 and sys.argv[6] == "1")
counts_only = (len(sys.argv) > 7 and sys.argv[7] == "1")
before_to_line_start = (len(sys.argv) > 10 and sys.argv[10] == "1")
merge_mode = (len(sys.argv) > 11 and sys.argv[11] == "1")
page = int(sys.argv[12]) if len(sys.argv) > 12 else 0
page_size = int(sys.argv[13]) if len(sys.argv) > 13 else 10

page_enabled = (page > 0)
page_size = max(1, int(page_size))
page_start = ((page - 1) * page_size + 1) if page_enabled else 1
page_end = (page * page_size) if page_enabled else 0

RED        = "\x1b[31m"
GREEN      = "\x1b[32m"
LIGHT_BLUE = "\x1b[38;2;122;218;247m"
RESET      = "\x1b[0m"

match_no = 0
match_files = {}
CHAT_PREFIX = "\x1eCHAT\t"
preproc_path = sys.argv[8] if len(sys.argv) > 8 else ""
skip_rg_path = sys.argv[9] if len(sys.argv) > 9 else ""
skipped_rg = set()

printed_chat_line_keys = set()

def _write_outputs():
  if skip_rg_path:
    try:
      with open(skip_rg_path, "w", encoding="utf-8", errors="replace") as f:
        for p in sorted(skipped_rg):
          f.write(f"skip-rg(binary): {p}\n")
    except Exception:
      pass

  if match_files_path:
    try:
      items = [(cnt, path) for path, cnt in match_files.items() if cnt > 0]
      items.sort(key=lambda x: (-x[0], x[1]))
      with open(match_files_path, "w", encoding="utf-8", errors="replace") as f:
        for cnt, path in items:
          f.write(f"{cnt}\t{path}\n")
    except Exception:
      pass

  try:
    with open(match_count_path, "w", encoding="utf-8") as f:
      f.write(str(match_no))
  except Exception:
    pass

def _finish_and_exit():
  _write_outputs()
  raise SystemExit(0)

def byte_to_char_index(s: str, byte_idx: int) -> int:
  if byte_idx <= 0:
    return 0
  b = 0
  for i, ch in enumerate(s):
    b += len(ch.encode("utf-8"))
    if b >= byte_idx:
      return i + 1
  return len(s)

def highlight_spans(s: str, spans):
  if not spans:
    return s
  ranges = []
  for sb, eb in spans:
    if eb <= 0:
      continue
    if sb < 0:
      sb = 0
    if eb < sb:
      sb, eb = eb, sb
    if sb == eb:
      continue
    s_char = byte_to_char_index(s, sb)
    e_char = byte_to_char_index(s, eb)
    if e_char < s_char:
      s_char, e_char = e_char, s_char
    if s_char == e_char:
      continue
    ranges.append((s_char, e_char))

  if not ranges:
    return s
  ranges.sort()
  merged = []
  for a, b in ranges:
    if not merged or a > merged[-1][1]:
      merged.append([a, b])
    elif b > merged[-1][1]:
      merged[-1][1] = b

  out = []
  last = 0
  for a, b in merged:
    if a < last:
      a = last
    out.append(s[last:a])
    out.append(f"{RED}{s[a:b]}{RESET}")
    last = b
  out.append(s[last:])
  return "".join(out)

files = {}

def split_chat_line(s: str):
  if s.startswith(CHAT_PREFIX):
    payload = s[len(CHAT_PREFIX):]
    parts = payload.split("\t", 2)
    if len(parts) == 3:
      ts, sender, msg = parts
      prefix = f"{CHAT_PREFIX}{ts}\t{sender}\t"
      return msg, ts, sender, len(prefix.encode("utf-8")), True
  return s, "", "", 0, False

next_path_cache = {}
next_chat_cache = {}

class _StopParse(Exception):
  pass

def _norm_text(s: str) -> str:
  return " ".join((s or "").replace("\r", "").replace("\n", " ").split())

class _FacebookHTMLParser(HTMLParser):
  def __init__(self, limit: int):
    super().__init__()
    self.limit = max(0, int(limit))
    self.depth = 0
    self.in_header = False
    self.header_depth = 0
    self.field = None
    self.header_user = []
    self.header_ts = []
    self.pending_header = None
    self.in_p = False
    self.p_text = []
    self.messages = []

  def handle_starttag(self, tag, attrs):
    self.depth += 1
    attrs = dict(attrs)
    cls = attrs.get("class", "") or ""
    if tag == "div" and "message_header" in f" {cls} ":
      self.in_header = True
      self.header_depth = self.depth
      self.field = None
      self.header_user = []
      self.header_ts = []
      return
    if self.in_header and tag == "span":
      if "user" in f" {cls} ":
        self.field = "user"
      elif "meta" in f" {cls} ":
        self.field = "meta"
    if self.pending_header and tag == "p" and not self.in_p:
      self.in_p = True
      self.p_text = []
      return
    if self.in_p:
      if tag == "br":
        self.p_text.append("\n")
      elif tag in {"img", "video", "audio"}:
        self.p_text.append(f"[{tag}]")
      elif tag == "a":
        href = attrs.get("href")
        if href:
          self.p_text.append(f" {html.unescape(href)} ")

  def handle_endtag(self, tag):
    if self.in_header and tag == "div" and self.depth == self.header_depth:
      sender = _norm_text(html.unescape("".join(self.header_user)))
      ts = _norm_text(html.unescape("".join(self.header_ts)))
      if sender or ts:
        self.pending_header = (ts, sender)
      else:
        self.pending_header = None
      self.in_header = False
      self.field = None
    if self.in_p and tag == "p":
      text = _norm_text(html.unescape("".join(self.p_text)))
      ts, sender = self.pending_header or ("", "")
      self.messages.append((text, sender, ts))
      if self.limit and len(self.messages) >= self.limit:
        raise _StopParse()
      self.in_p = False
      self.p_text = []
      self.pending_header = None
    if self.field and tag == "span":
      self.field = None
    self.depth = max(0, self.depth - 1)

  def handle_data(self, data):
    if self.in_header and self.field:
      if self.field == "user":
        self.header_user.append(data)
      elif self.field == "meta":
        self.header_ts.append(data)
    elif self.in_p:
      self.p_text.append(data)

def next_html_path(path: str) -> str:
  cached = next_path_cache.get(path)
  if cached is not None:
    return cached
  base = os.path.basename(path)
  m = re.match(r"^(.*?)(\d+)(\.[^.]+)$", base)
  if not m:
    next_path_cache[path] = ""
    return ""
  prefix, num, ext = m.group(1), m.group(2), m.group(3)
  if ext.lower() not in (".html", ".htm"):
    next_path_cache[path] = ""
    return ""
  try:
    next_num = str(int(num) + 1).zfill(len(num))
  except Exception:
    next_path_cache[path] = ""
    return ""
  next_base = f"{prefix}{next_num}{ext}"
  next_path = os.path.join(os.path.dirname(path), next_base)
  if not os.path.isfile(next_path):
    next_path_cache[path] = ""
    return ""
  next_path_cache[path] = next_path
  return next_path

def read_next_chat_lines(path: str, want: int):
  if want <= 0 or not preproc_path:
    return []
  next_path = next_html_path(path)
  if not next_path:
    return []
  cached = next_chat_cache.get(next_path)
  if cached is None:
    lines = []
    try:
      proc = subprocess.run([sys.executable, preproc_path, next_path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False)
      for line in proc.stdout.splitlines():
        msg, ts, sender, _, is_chat = split_chat_line(line)
        if is_chat:
          lines.append((msg, sender, ts))
    except Exception:
      lines = []
    if not lines and next_path.lower().endswith((".html", ".htm")):
      try:
        parser = _FacebookHTMLParser(want)
        with open(next_path, "r", encoding="utf-8", errors="ignore") as f:
          try:
            parser.feed(f.read())
            parser.close()
          except _StopParse:
            pass
        lines = parser.messages
      except Exception:
        lines = []
    next_chat_cache[next_path] = lines
    cached = lines
  return cached[:want]

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
  data = obj.get("data", {})

  if typ == "binary":
    skipped_rg.add(path)
    continue

  # Fast path: in --chat --merge -C 0 mode, print each matching message as it arrives.
  # This avoids per-file buffering and improves time-to-first-result, and enables early exit for --page.
  if typ == "match" and chat_mode and merge_mode and before == 0 and after == 0:
    line_no = data.get("line_number")
    text = data.get("lines", {}).get("text", "")
    if line_no is None:
      continue

    ln = int(line_no)
    raw_text = text.rstrip("\n").replace("\r", "")
    msg, ts, sender, prefix_b, is_chat = split_chat_line(raw_text)
    if not is_chat:
      continue

    # Track total match counts per file (submatches), consistent with non-streaming mode.
    try:
      match_files[path] = match_files.get(path, 0) + len(data.get("submatches", []))
    except Exception:
      pass

    key = (path, ln)
    if key in printed_chat_line_keys:
      continue
    printed_chat_line_keys.add(key)

    match_no += 1
    if page_enabled and match_no < page_start:
      continue

    if not counts_only:
      spans = []
      for sub in data.get("submatches", []):
        try:
          sb = int(sub.get("start", 0)) - int(prefix_b or 0)
          eb = int(sub.get("end", 0)) - int(prefix_b or 0)
        except Exception:
          continue
        if eb <= 0:
          continue
        if sb < 0:
          sb = 0
        if sb == eb:
          continue
        spans.append((sb, eb))
      out_msg = highlight_spans(msg, spans) if spans else msg
      print(f"{GREEN}{match_no}{RESET} {LIGHT_BLUE}{path} {ln}:{RESET}")
      print(f"{{{out_msg},{sender},{ts}}}")

    if page_enabled and match_no >= page_end:
      _finish_and_exit()
    continue

  if typ == "begin":
    files[path] = {"lines": {}, "matches": [], "ts": {}, "senders": {}, "prefix_b": {}, "chat_lines": set()}
    continue

  if path not in files:
    files[path] = {"lines": {}, "matches": [], "ts": {}, "senders": {}, "prefix_b": {}, "chat_lines": set()}

  if typ in ("match", "context"):
    line_no = data.get("line_number")
    text = data.get("lines", {}).get("text", "")
    if line_no is not None:
      raw_text = text.rstrip("\n").replace("\r", "")
      clean_text, ts, sender, prefix_b, is_chat = split_chat_line(raw_text)
      ln = int(line_no)
      files[path]["lines"][ln] = clean_text
      files[path]["prefix_b"][ln] = prefix_b if is_chat else 0
      if is_chat:
        files[path]["chat_lines"].add(ln)
      if is_chat and ts:
        files[path]["ts"][ln] = ts
      if is_chat and sender:
        files[path]["senders"][ln] = sender

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
    ts_map = buf.get("ts", {})
    sender_map = buf.get("senders", {})
    prefix_map = buf.get("prefix_b", {})
    chat_lines = buf.get("chat_lines", set())
    all_line_nos = sorted(lines_map.keys())

    chat_spans = {}
    if chat_mode and matches:
      for m in matches:
        ln = m.get("line_no")
        if ln is None or ln not in chat_lines:
          continue
        prefix_b = prefix_map.get(ln, 0)
        start_b = m.get("start_b", 0) - prefix_b
        end_b = m.get("end_b", 0) - prefix_b
        if end_b <= 0:
          continue
        if start_b < 0:
          start_b = 0
        if start_b == end_b:
          continue
        chat_spans.setdefault(ln, []).append((start_b, end_b))

    printed_chat_lines = set()
    for m in matches:
      ln = m["line_no"]
      if ln is None:
        continue

      line_text = lines_map.get(ln, "")
      prefix_b = prefix_map.get(ln, 0)
      if prefix_b and m["start_b"] < prefix_b:
        continue
      mtxt = m.get("mtxt", "")
      if chat_mode and ln in chat_lines and merge_mode:
        if ln in printed_chat_lines:
          continue
        printed_chat_lines.add(ln)
        start_ln = ln - before
        end_ln = ln + after
        match_no += 1
        if not counts_only:
          print(f"{GREEN}{match_no}{RESET} {LIGHT_BLUE}{path} {ln}:{RESET}")
          for n in all_line_nos:
            if n < start_ln or n > end_ln:
              continue
            msg = lines_map.get(n, "")
            spans = chat_spans.get(n)
            if spans:
              msg = highlight_spans(msg, spans)
            sender = sender_map.get(n, "")
            ts = ts_map.get(n, "")
            print(f"{{{msg},{sender},{ts}}}")
          max_ln = max(all_line_nos) if all_line_nos else 0
          missing_after = max(0, end_ln - max_ln)
          if missing_after:
            for msg, sender, ts in read_next_chat_lines(path, missing_after):
              print(f"{{{msg},{sender},{ts}}}")
        continue

      if chat_mode and ln in chat_lines:
        start_ln = ln - before
        end_ln = ln + after
        match_no += 1
        if not counts_only:
          print(f"{GREEN}{match_no}{RESET} {LIGHT_BLUE}{path} {ln}:{RESET}")
          for n in all_line_nos:
            if n < start_ln or n > end_ln:
              continue
            msg = lines_map.get(n, "")
            spans = chat_spans.get(n)
            if spans:
              msg = highlight_spans(msg, spans)
            sender = sender_map.get(n, "")
            ts = ts_map.get(n, "")
            print(f"{{{msg},{sender},{ts}}}")
          max_ln = max(all_line_nos) if all_line_nos else 0
          missing_after = max(0, end_ln - max_ln)
          if missing_after:
            for msg, sender, ts in read_next_chat_lines(path, missing_after):
              print(f"{{{msg},{sender},{ts}}}")
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

      adj_start = m["start_b"] - prefix_b
      adj_end = m["end_b"] - prefix_b
      if adj_end < 0:
        continue
      if adj_start < 0:
        adj_start = 0
      s_char = byte_to_char_index(line_text, adj_start)
      e_char = byte_to_char_index(line_text, adj_end)
      if e_char < s_char:
        s_char, e_char = e_char, s_char

      base = starts.get(ln, 0)
      m_start = base + s_char
      m_end   = base + e_char

      if before_to_line_start:
        lo = base
      else:
        lo = max(0, m_start - before)
      hi = min(len(combined), m_end + after)
      snippet_text = combined[lo:hi]
      rel_start = m_start - lo
      rel_end = m_end - lo
      snippet = snippet_text[:rel_start] + RED + snippet_text[rel_start:rel_end] + RESET + snippet_text[rel_end:]

      ts = ts_map.get(ln, "")
      ts_prefix = f"{ts} | " if ts else ""
      match_no += 1
      if not counts_only:
        print(f"{GREEN}{match_no}{RESET} {LIGHT_BLUE}{path} {ln}:{RESET} {ts_prefix}{snippet}")

    if matches:
      match_files[path] = len(matches)
    files.pop(path, None)

_write_outputs()
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
#!/usr/bin/env python3
import os, sys, json, re, html, sqlite3, hashlib, tempfile
from html.parser import HTMLParser
from datetime import datetime, timezone

KEEP_TS = os.environ.get("CHAT_KEEP_TS", "1").lower() not in {"0", "false", "no", "off"}
CHAT_PREFIX = "\x1eCHAT\t"

# Optional cache: speeds up repeated --chat searches by avoiding re-parsing large exports.
CACHE_DIR = (os.environ.get("G_CHAT_CACHE_DIR") or "").strip()
CACHE_ENABLED = bool(CACHE_DIR)
CACHE_VERSION = "1"
CACHE_FH = None
CACHE_TMP_PATH = ""
CACHE_FINAL_PATH = ""
CACHE_META_PATH = ""

def _cache_key(path: str) -> str:
  h = hashlib.sha1()
  h.update(path.encode("utf-8", "surrogatepass"))
  return h.hexdigest()[:16]

def _cache_paths(path: str):
  k = _cache_key(path)
  return (
    os.path.join(CACHE_DIR, f"{k}.chat.txt"),
    os.path.join(CACHE_DIR, f"{k}.chat.meta.json"),
  )

def _cache_meta_ok(path: str, meta: dict) -> bool:
  try:
    st = os.stat(path)
  except Exception:
    return False
  if not isinstance(meta, dict):
    return False
  if str(meta.get("v") or "") != CACHE_VERSION:
    return False
  if bool(meta.get("keep_ts", True)) != KEEP_TS:
    return False
  if int(meta.get("mtime_ns", -1)) != int(getattr(st, "st_mtime_ns", int(st.st_mtime * 1e9))):
    return False
  if int(meta.get("size", -1)) != int(st.st_size):
    return False
  return True

def _try_emit_cache(path: str) -> bool:
  global CACHE_FINAL_PATH, CACHE_META_PATH
  if not CACHE_ENABLED:
    return False
  try:
    final_path, meta_path = _cache_paths(path)
    if not (os.path.exists(final_path) and os.path.exists(meta_path)):
      return False
    with open(meta_path, "r", encoding="utf-8", errors="replace") as mf:
      meta = json.load(mf)
    if not _cache_meta_ok(path, meta):
      return False
    with open(final_path, "rb") as f:
      sys.stdout.buffer.write(f.read())
    return True
  except Exception:
    return False

def norm_text(s: str) -> str:
  return " ".join((s or "").replace("\r", "").replace("\n", " ").split())

def emit_chat_line(ts: str, sender: str, text: str):
  if not KEEP_TS:
    ts = ""
  ts = norm_text(ts) if ts else ""
  sender = norm_text(sender) if sender else ""
  out_text = norm_text(text) if text is not None else ""
  b = (f"{CHAT_PREFIX}{ts}\t{sender}\t{out_text}\n").encode("utf-8", "surrogateescape")
  sys.stdout.buffer.write(b)
  if CACHE_FH is not None:
    try:
      CACHE_FH.write(b)
    except Exception:
      pass

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
    self.last_sender = ""

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
    if tag == "a" and self.field == "text":
      href = attrs.get("href")
      if href:
        self.cur["text"].append(f" {href} ")

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
    sender_raw = norm_text("".join(self.cur.get("sender", [])))
    sender = sender_raw or self.last_sender
    if sender_raw:
      self.last_sender = sender_raw
    text = norm_text("".join(self.cur.get("text", [])))
    msg_id = self.cur.get("id")
    ts = self.cur.get("ts") or ""
    if ts and " " in ts and "T" not in ts:
      ts = ts.replace(" ", "T", 1)
    emit_chat_line(ts, sender, text)
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

# ---------- Facebook Messenger HTML (legacy exports) ----------
class FacebookHTMLParser(HTMLParser):
  def __init__(self):
    super().__init__()
    self.depth = 0
    self.in_header = False
    self.header_depth = 0
    self.field = None
    self.header_user = []
    self.header_ts = []
    self.pending_header = None
    self.in_p = False
    self.p_text = []
    self.emitted = 0

  def handle_starttag(self, tag, attrs):
    self.depth += 1
    attrs = dict(attrs)
    cls = attrs.get("class", "") or ""
    if tag == "div" and "message_header" in f" {cls} ":
      self.in_header = True
      self.header_depth = self.depth
      self.field = None
      self.header_user = []
      self.header_ts = []
      return
    if self.in_header and tag == "span":
      if "user" in f" {cls} ":
        self.field = "user"
      elif "meta" in f" {cls} ":
        self.field = "meta"
    if self.pending_header and tag == "p" and not self.in_p:
      self.in_p = True
      self.p_text = []
      return
    if self.in_p:
      if tag == "br":
        self.p_text.append("\n")
      elif tag in {"img", "video", "audio"}:
        self.p_text.append(f"[{tag}]")
      elif tag == "a":
        href = attrs.get("href")
        if href:
          self.p_text.append(f" {html.unescape(href)} ")

  def handle_endtag(self, tag):
    if self.in_header and tag == "div" and self.depth == self.header_depth:
      sender = norm_text("".join(self.header_user))
      ts = norm_text("".join(self.header_ts))
      if sender or ts:
        self.pending_header = (ts, sender)
      else:
        self.pending_header = None
      self.in_header = False
      self.field = None
    if self.in_p and tag == "p":
      text = norm_text("".join(self.p_text))
      ts, sender = self.pending_header or ("", "")
      emit_chat_line(ts, sender, text)
      self.emitted += 1
      self.in_p = False
      self.p_text = []
      self.pending_header = None
    if self.field and tag == "span":
      self.field = None
    self.depth = max(0, self.depth - 1)

  def handle_data(self, data):
    if self.in_header and self.field:
      if self.field == "user":
        self.header_user.append(data)
      elif self.field == "meta":
        self.header_ts.append(data)
    elif self.in_p:
      self.p_text.append(data)

def parse_facebook_html(path: str) -> bool:
  try:
    raw = open(path, "r", encoding="utf-8", errors="ignore").read()
  except Exception:
    return False
  if 'class="message_header"' not in raw and "class='message_header'" not in raw:
    return False
  parser = FacebookHTMLParser()
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

def emit_telegram_messages(msgs):
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
    emit_chat_line(ts or "", sender or "", norm_text(text))
    emitted += 1
  return emitted

def parse_telegram_json(path: str) -> bool:
  try:
    obj = json.load(open(path, "r", encoding="utf-8"))
  except Exception:
    return False
  msgs = obj.get("messages")
  if not isinstance(msgs, list):
    return False
  return emit_telegram_messages(msgs) > 0

# ---------- Messenger JSON ----------
def ts_from_ms(ms):
  try:
    dt = datetime.fromtimestamp(int(ms)/1000, tz=timezone.utc)
    return dt.isoformat().replace("+00:00", "Z")
  except Exception:
    return ""

def ts_from_sec(sec):
  try:
    dt = datetime.fromtimestamp(int(sec), tz=timezone.utc)
    return dt.isoformat().replace("+00:00", "Z")
  except Exception:
    return ""

def emit_messenger_messages(msgs):
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
    emit_chat_line(ts_from_ms(msg.get("timestamp_ms")), sender or "", norm_text(text or ""))
    emitted += 1
  return emitted

def parse_messenger_json(path: str) -> bool:
  try:
    obj = json.load(open(path, "r", encoding="utf-8"))
  except Exception:
    return False
  msgs = obj.get("messages")
  if not isinstance(msgs, list):
    return False
  return emit_messenger_messages(msgs) > 0

# ---------- Telegram TXT ----------
TG_RE = re.compile(r"^\s*[.\-]*\s*(\d{1,2}\.\d{1,2}\.\d{2,4})\s+(\d{1,2}:\d{2}:\d{2}),\s+([^:]+):\s*(.*)$")

def parse_tg_ts(datestr, timestr):
  for fmt in ("%d.%m.%Y %H:%M:%S", "%d.%m.%y %H:%M:%S"):
    try:
      dt = datetime.strptime(f"{datestr} {timestr}".strip(), fmt)
      return dt.isoformat()
    except Exception:
      continue
  return f"{datestr} {timestr}"

def parse_telegram_txt(path: str) -> bool:
  try:
    lines = open(path, "r", encoding="utf-8", errors="ignore").read().splitlines()
  except Exception:
    return False
  messages = []
  cur = None
  saw_header = False
  for raw in lines:
    line = raw.strip("\r")
    if not line:
      continue
    if line and ord(line[0]) == 0xfeff:
      line = line[1:]
    if line.startswith("Your Telegram History"):
      saw_header = True
      continue
    m = TG_RE.match(line)
    if m:
      if cur:
        messages.append(cur)
      cur = {
        "ts": parse_tg_ts(m.group(1), m.group(2)),
        "sender": m.group(3).strip(),
        "text": m.group(4).strip(),
      }
    else:
      if cur:
        cur["text"] += " " + line.strip()
  if cur:
    messages.append(cur)
  if len(messages) < 2 and not saw_header:
    return False
  for msg in messages:
    emit_chat_line(msg.get("ts", ""), msg.get("sender", ""), norm_text(msg.get("text", "")))
  return True

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
    emit_chat_line(msg.get("ts", ""), msg.get("sender", ""), norm_text(msg.get("text", "")))
  return True

# ---------- Generic JSON (list of dict messages) ----------
def emit_generic_messages(items):
  emitted = 0
  for item in items:
    if not isinstance(item, dict):
      continue
    txt = item.get("message") or item.get("text") or item.get("content")
    if isinstance(txt, list):
      txt = " ".join(str(x) for x in txt if x)
    if txt is None:
      continue
    sender = item.get("from") or item.get("sender") or item.get("author") or item.get("name") or ""
    ts = item.get("sent_date") or item.get("date") or item.get("timestamp") or ""
    emit_chat_line(str(ts), str(sender), norm_text(str(txt)))
    emitted += 1
  return emitted

def parse_generic_json(path: str) -> bool:
  try:
    obj = json.load(open(path, "r", encoding="utf-8"))
  except Exception:
    return False
  if not isinstance(obj, list) or not obj:
    return False
  return emit_generic_messages(obj) > 0

def parse_gemini_json(path: str) -> bool:
  try:
    obj = json.load(open(path, "r", encoding="utf-8"))
  except Exception:
    return False
  if not isinstance(obj, dict) or "messages" not in obj:
    return False
  msgs = obj.get("messages")
  if not isinstance(msgs, list):
    return False
  if "projectHash" not in obj and "sessionId" not in obj:
    return False

  emitted = 0
  for msg in msgs:
    if not isinstance(msg, dict):
      continue
    ts = msg.get("timestamp", "")
    typ = msg.get("type", "")
    content = msg.get("content", "")

    tcs = msg.get("toolCalls", [])
    if tcs:
        call_names = [f"[{tc.get('name', 'tool')}]" for tc in tcs]
        t_str = " ".join(call_names)
        content = (content + " " + t_str).strip()

    sender = typ
    if typ == "gemini":
        model = msg.get("model")
        if model:
            sender = model

    emit_chat_line(ts, sender, norm_text(content))
    emitted += 1
  return emitted > 0

def _ts_from_epoch_seconds(ts):
  try:
    return datetime.fromtimestamp(float(ts), tz=timezone.utc).isoformat()
  except Exception:
    return ""

def _chatgpt_content_text(content) -> str:
  if not isinstance(content, dict):
    return ""
  ctype = content.get("content_type") or ""
  if ctype == "text":
    parts = content.get("parts") or []
    if isinstance(parts, list):
      return " ".join(str(p) for p in parts if p)
  # Many non-text types store their payload in "text".
  txt = content.get("text")
  if isinstance(txt, str) and txt.strip():
    return txt
  parts = content.get("parts")
  if isinstance(parts, list):
    return " ".join(str(p) for p in parts if p)
  return ""

def _emit_chatgpt_export(convs) -> bool:
  # convs: list of conversations (ChatGPT export)
  if not isinstance(convs, list) or not convs:
    return False
  emitted = 0
  for conv in convs:
    if not isinstance(conv, dict):
      continue
    mapping = conv.get("mapping")
    if not isinstance(mapping, dict) or not mapping:
      continue
    # Find roots (parent == null). Most roots are structural and have message=null.
    roots = []
    for nid, node in mapping.items():
      if isinstance(node, dict) and node.get("parent") is None:
        roots.append(str(nid))
    if not roots:
      roots = [str(next(iter(mapping.keys())))]

    # Iterative walk (avoid Python recursion depth limits on long threads).
    seen = set()
    stack = list(roots)
    while stack:
      nid = stack.pop()
      if nid in seen:
        continue
      seen.add(nid)
      node = mapping.get(nid)
      if not isinstance(node, dict):
        continue
      msg = node.get("message")
      if isinstance(msg, dict):
        md = msg.get("metadata") or {}
        if isinstance(md, dict) and md.get("is_visually_hidden_from_conversation"):
          pass
        else:
          author = msg.get("author") or {}
          role = ""
          if isinstance(author, dict):
            role = str(author.get("role") or "")
          sender = role or (str(author) if author else "")
          # Prefer message-level create_time; fall back to conversation create_time.
          ts = _ts_from_epoch_seconds(msg.get("create_time")) or _ts_from_epoch_seconds(conv.get("create_time")) or ""
          content = msg.get("content")
          text = _chatgpt_content_text(content)
          # Some exports/HTML embed HTML entities inside JSON strings.
          text = html.unescape(text or "")
          if text and text.strip():
            emit_chat_line(ts, sender, norm_text(text))
            emitted += 1
      children = node.get("children") or []
      if isinstance(children, list) and children:
        # Preserve original ordering as much as possible.
        for c in reversed(children):
          stack.append(str(c))
  return emitted > 0

def parse_chatgpt_json(path: str) -> bool:
  try:
    obj = json.load(open(path, "r", encoding="utf-8"))
  except Exception:
    return False
  # conversations.json: list[conversation]
  if isinstance(obj, list):
    return _emit_chatgpt_export(obj)
  return False

def parse_chatgpt_html(path: str) -> bool:
  # ChatGPT Data Export chat.html embeds JS: "var jsonData = [...]"
  try:
    raw = open(path, "r", encoding="utf-8", errors="ignore").read()
  except Exception:
    return False
  if "ChatGPT Data Export" not in raw and "var jsonData" not in raw:
    return False
  i = raw.find("var jsonData")
  if i < 0:
    return False

  def _extract_json_array(s: str, start: int) -> str:
    # Find the JSON array starting at/after `start`, using bracket matching.
    k = s.find("[", start)
    if k < 0:
      return ""
    depth = 0
    in_str = False
    esc = False
    for idx in range(k, len(s)):
      ch = s[idx]
      if in_str:
        if esc:
          esc = False
        elif ch == "\\":
          esc = True
        elif ch == "\"":
          in_str = False
        continue
      if ch == "\"":
        in_str = True
        continue
      if ch == "[":
        depth += 1
      elif ch == "]":
        depth -= 1
        if depth == 0:
          return s[k:idx+1]
    return ""

  arr = _extract_json_array(raw, i)
  if not arr:
    return False
  try:
    convs = json.loads(arr)
  except Exception:
    return False
  return _emit_chatgpt_export(convs)

def parse_deepseek_json(path: str) -> bool:
  try:
    obj = json.load(open(path, "r", encoding="utf-8"))
  except Exception:
    return False
  if not isinstance(obj, list) or not obj:
    return False
  emitted = 0
  for conv in obj:
    if not isinstance(conv, dict):
      continue
    mapping = conv.get("mapping")
    if not isinstance(mapping, dict) or not mapping:
      continue
    root = mapping.get("root")
    if not isinstance(root, dict):
      # Some exports use numeric roots; fall back.
      root = next((v for v in mapping.values() if isinstance(v, dict) and v.get("parent") is None), None)
    if not isinstance(root, dict):
      continue
    stack = [str(x) for x in (root.get("children") or []) if x is not None]
    seen = set()
    while stack:
      nid = stack.pop(0)
      if nid in seen:
        continue
      seen.add(nid)
      node = mapping.get(nid)
      if not isinstance(node, dict):
        continue
      msg = node.get("message")
      if isinstance(msg, dict):
        ts = str(msg.get("inserted_at") or conv.get("inserted_at") or "")
        frags = msg.get("fragments") or []
        if isinstance(frags, list):
          for frag in frags:
            if not isinstance(frag, dict):
              continue
            ftyp = str(frag.get("type") or "")
            txt = frag.get("content")
            if not isinstance(txt, str) or not txt.strip():
              continue
            if ftyp.upper() == "REQUEST":
              sender = "USER"
            elif ftyp.upper() == "RESPONSE":
              sender = "ASSISTANT"
            elif ftyp.upper() == "THINK":
              # Skip internal reasoning fragments by default.
              continue
            else:
              sender = ftyp
            emit_chat_line(ts, sender, norm_text(txt))
            emitted += 1
      children = node.get("children") or []
      if isinstance(children, list):
        for c in children:
          if c is not None:
            stack.append(str(c))
  return emitted > 0

def _mongo_date_to_iso(v) -> str:
  # {"$date":{"$numberLong":"1760743150274"}} (ms since epoch)
  try:
    if isinstance(v, dict) and "$date" in v:
      d = v.get("$date")
      if isinstance(d, dict) and "$numberLong" in d:
        return ts_from_ms(d.get("$numberLong"))
      if isinstance(d, (int, float, str)):
        return ts_from_ms(d)
  except Exception:
    pass
  return ""

def parse_grok_json(path: str) -> bool:
  try:
    obj = json.load(open(path, "r", encoding="utf-8"))
  except Exception:
    return False
  if not isinstance(obj, dict):
    return False
  convs = obj.get("conversations")
  if not isinstance(convs, list) or not convs:
    return False
  emitted = 0
  for item in convs:
    if not isinstance(item, dict):
      continue
    responses = item.get("responses") or []
    if not isinstance(responses, list):
      continue
    for r in responses:
      if not isinstance(r, dict):
        continue
      resp = r.get("response")
      if not isinstance(resp, dict):
        continue
      msg = resp.get("message")
      if not isinstance(msg, str) or not msg.strip():
        continue
      sender = str(resp.get("sender") or resp.get("model") or "")
      ts = _mongo_date_to_iso(resp.get("create_time")) or str(resp.get("create_time") or "")
      emit_chat_line(ts, sender, norm_text(msg))
      emitted += 1
  return emitted > 0

class _HTMLText(HTMLParser):
  def __init__(self):
    super().__init__()
    self.parts = []
  def handle_data(self, data):
    if data:
      self.parts.append(data)
  def get_text(self):
    return "".join(self.parts)

def _strip_html(s: str) -> str:
  try:
    p = _HTMLText()
    p.feed(s or "")
    p.close()
    return p.get_text()
  except Exception:
    return re.sub(r"<[^>]+>", " ", s or "")

def parse_google_gemini_myactivity_json(path: str) -> bool:
  # Google Takeout "My Activity/Gemini Apps/MyActivity.json"
  try:
    obj = json.load(open(path, "r", encoding="utf-8"))
  except Exception:
    return False
  if not isinstance(obj, list) or not obj:
    return False
  emitted = 0
  for it in obj:
    if not isinstance(it, dict):
      continue
    ts = str(it.get("time") or "")
    title = str(it.get("title") or "")
    prompt = title
    if prompt.lower().startswith("prompted "):
      prompt = prompt[len("prompted "):]
    prompt = prompt.strip()
    # Attached file hints (URLs point to sibling exported TXT files).
    subs = it.get("subtitles") or []
    attached = []
    if isinstance(subs, list):
      for s in subs:
        if isinstance(s, dict) and s.get("url"):
          attached.append(str(s.get("url")))
    if prompt:
      suffix = f" [attached: {', '.join(attached)}]" if attached else ""
      emit_chat_line(ts, "USER", norm_text(prompt + suffix))
      emitted += 1
    safe = it.get("safeHtmlItem") or []
    parts = []
    if isinstance(safe, list):
      for s in safe:
        if isinstance(s, dict):
          h = s.get("html")
          if isinstance(h, str) and h.strip():
            parts.append(_strip_html(html.unescape(h)))
    resp = norm_text(" ".join(parts))
    if resp:
      emit_chat_line(ts, "GEMINI", resp)
      emitted += 1
  return emitted > 0

def _codex_text_from_content(content):
  parts = []
  if isinstance(content, list):
    for item in content:
      if isinstance(item, dict):
        txt = item.get("text")
        if txt:
          parts.append(str(txt))
      elif isinstance(item, str):
        parts.append(item)
  elif isinstance(content, dict):
    txt = content.get("text")
    if txt:
      parts.append(str(txt))
  elif isinstance(content, str):
    parts.append(content)
  return " ".join(parts)

def parse_codex_jsonl(path: str) -> bool:
  try:
    f = open(path, "r", encoding="utf-8", errors="ignore")
  except Exception:
    return False

  resp_msgs = []
  event_msgs = []
  saw_codex = False
  line_no = 0
  with f:
    for raw in f:
      line_no += 1
      line = raw.strip()
      if not line or not line.startswith("{"):
        continue
      try:
        obj = json.loads(line)
      except Exception:
        continue
      if not isinstance(obj, dict):
        continue
      ts = obj.get("timestamp", "") or ""
      typ = obj.get("type")
      if typ in ("response_item", "event_msg", "turn_context", "session_meta"):
        saw_codex = True
      payload = obj.get("payload", {})
      if typ == "response_item" and isinstance(payload, dict) and payload.get("type") == "message":
        text = _codex_text_from_content(payload.get("content"))
        if not text:
          text = payload.get("text") or ""
        if text:
          role = payload.get("role") or ""
          resp_msgs.append((text, role, ts, line_no))
        continue
      if typ == "event_msg" and isinstance(payload, dict):
        et = payload.get("type")
        if et in ("user_message", "agent_message"):
          text = payload.get("message") or ""
          if text:
            role = "user" if et == "user_message" else "assistant"
            event_msgs.append((str(text), role, ts, line_no))

  msgs = resp_msgs if resp_msgs else event_msgs
  if not msgs:
    return saw_codex
  for text, sender, ts, ln in msgs:
    msg = f"L{ln}: {text}"
    emit_chat_line(ts, sender, msg)
  return True

def looks_like_messenger_messages(msgs) -> bool:
  for msg in msgs[:20]:
    if isinstance(msg, dict) and ("sender_name" in msg or "timestamp_ms" in msg):
      return True
  return False

def looks_like_telegram_messages(msgs) -> bool:
  for msg in msgs[:20]:
    if isinstance(msg, dict) and any(k in msg for k in ("from", "actor", "date", "text", "media_type")):
      return True
  return False

def parse_json_any(path: str) -> bool:
  try:
    obj = json.load(open(path, "r", encoding="utf-8"))
  except Exception:
    return False

  if isinstance(obj, dict) and isinstance(obj.get("messages"), list):
    msgs = obj.get("messages") or []
    if looks_like_messenger_messages(msgs):
      return emit_messenger_messages(msgs) > 0
    if looks_like_telegram_messages(msgs):
      return emit_telegram_messages(msgs) > 0
    return emit_generic_messages(msgs) > 0

  if isinstance(obj, list):
    return emit_generic_messages(obj) > 0

  return False

# ---------- Telegram SQLite (unofficial backups) ----------
def parse_telegram_sqlite(path: str) -> bool:
  try:
    conn = sqlite3.connect(path)
  except Exception:
    return False
  emitted = 0
  try:
    cur = conn.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    tables = {r[0] for r in cur.fetchall()}
    if "messages" not in tables:
      return False

    cur.execute("PRAGMA table_info(messages)")
    cols = {r[1] for r in cur.fetchall()}
    needed = {"message_id", "text", "sender_id", "time"}
    if not needed.issubset(cols):
      return False

    try:
      cur.execute("SELECT message_id, sender_id, text, time FROM messages WHERE message_type IS NULL OR message_type='message'")
    except Exception:
      cur.execute("SELECT message_id, sender_id, text, time FROM messages")

    for mid, sender, text, ts in cur:
      if text is None or str(text).strip() == "":
        continue
      emit_chat_line(ts_from_sec(ts), str(sender), norm_text(str(text)))
      emitted += 1
  except Exception:
    return False
  finally:
    try:
      conn.close()
    except Exception:
      pass
  return emitted > 0

def handlers_for_path(path: str):
  ext = os.path.splitext(path)[1].lower()
  if ext in (".html", ".htm"):
    return (parse_chatgpt_html, parse_telegram_html, parse_facebook_html)
  if ext in (".jsonl",):
    return (parse_codex_jsonl,)
  if ext in (".json",):
    return (parse_chatgpt_json, parse_deepseek_json, parse_grok_json, parse_google_gemini_myactivity_json, parse_gemini_json, parse_json_any)
  if ext in (".txt",):
    return (parse_telegram_txt, parse_whatsapp_txt, parse_json_any)
  if ext in (".sqlite", ".sqlite3", ".db"):
    return (parse_telegram_sqlite,)
  return (parse_json_any, parse_telegram_html, parse_telegram_txt, parse_whatsapp_txt, parse_telegram_sqlite)

def main():
  if len(sys.argv) != 2:
    print("chat-preproc: expected exactly 1 arg: path", file=sys.stderr)
    return 2
  path = sys.argv[1]
  if _try_emit_cache(path):
    return 0

  global CACHE_FH, CACHE_TMP_PATH, CACHE_FINAL_PATH, CACHE_META_PATH
  if CACHE_ENABLED:
    try:
      os.makedirs(CACHE_DIR, exist_ok=True)
      CACHE_FINAL_PATH, CACHE_META_PATH = _cache_paths(path)
      fd, CACHE_TMP_PATH = tempfile.mkstemp(prefix=os.path.basename(CACHE_FINAL_PATH) + ".", dir=CACHE_DIR)
      CACHE_FH = os.fdopen(fd, "wb")
    except Exception:
      CACHE_FH = None
      CACHE_TMP_PATH = ""
      CACHE_FINAL_PATH = ""
      CACHE_META_PATH = ""

  handlers = handlers_for_path(path)
  for fn in handlers:
    try:
      if fn(path):
        if CACHE_FH is not None and CACHE_TMP_PATH and CACHE_FINAL_PATH and CACHE_META_PATH:
          try:
            CACHE_FH.close()
          except Exception:
            pass
          try:
            os.replace(CACHE_TMP_PATH, CACHE_FINAL_PATH)
          except Exception:
            pass
          try:
            st = os.stat(path)
            meta = {
              "v": CACHE_VERSION,
              "keep_ts": KEEP_TS,
              "mtime_ns": int(getattr(st, "st_mtime_ns", int(st.st_mtime * 1e9))),
              "size": int(st.st_size),
            }
            tmp_meta = CACHE_META_PATH + ".tmp"
            with open(tmp_meta, "w", encoding="utf-8") as mf:
              json.dump(meta, mf, ensure_ascii=False)
            os.replace(tmp_meta, CACHE_META_PATH)
          except Exception:
            pass
        return 0
    except Exception:
      continue

  if CACHE_FH is not None:
    try:
      CACHE_FH.close()
    except Exception:
      pass
    if CACHE_TMP_PATH:
      try:
        os.unlink(CACHE_TMP_PATH)
      except Exception:
        pass
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
chmod +x "$tmp_chat"

# Enumerate all files (always include hidden, so verbose can report hidden-excluded counts)
: >"$tmp_all"
for p in "${PATHS[@]}"; do
  if [[ -f "$p" ]]; then
    printf '%s\0' "$p" >>"$tmp_all"
  elif [[ -d "$p" ]]; then
    FD_ARGS=(-0 -t f -H)
    for pat in "${FD_EXCLUDE_PATTERNS[@]}"; do
      FD_ARGS+=(--exclude "$pat")
    done
    [[ "$NO_IGNORE" -eq 1 ]] && FD_ARGS+=(--no-ignore)
    fd "${FD_ARGS[@]}" . "$p" 2>/dev/null >>"$tmp_all" || true
  fi
done

# Split + stats
cat >"$tmp_split" <<'PY'
import os, sys, json, re

all_path = sys.argv[1]
out_text = sys.argv[2]
out_rich = sys.argv[3]
out_chat = sys.argv[4]
out_aichat = sys.argv[5]
out_xlsx = sys.argv[6]
out_pptx = sys.argv[7]
out_doc  = sys.argv[8]
bad_rich_txt = sys.argv[9]
stats_json = sys.argv[10]

mode = sys.argv[11]
filter_exts = set([x.strip().lower() for x in sys.argv[12].split(",") if x.strip()])
have_rga_preproc = (sys.argv[13] == "1")
min_rich_size = int(sys.argv[14])
search_hidden = (sys.argv[15] == "1")
chat_mode = (sys.argv[16] == "1")
no_chat_mode = (sys.argv[17] == "1")

RICH_EXTS = {"pdf","docx","sqlite","sqlite3","db","db3"}
XLSX_EXTS = {"xlsx","xls"}
PPTX_EXTS = {"pptx","ppt"}
DOC_EXTS  = {"doc"}

OFFICE_TEMP_EXTS = {"docx","xlsx","pptx","xls","ppt"}
CHAT_HTML_EXTS = {"html","htm"}
CHAT_JSON_EXTS = {"json"}
CHAT_JSONL_EXTS = {"jsonl"}
CHAT_TXT_EXTS = {"txt"}
CHAT_SQLITE_EXTS = {"sqlite","sqlite3","db"}

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

TG_TXT_RE = re.compile(r"^\s*[.\-]*\s*\d{1,2}\.\d{1,2}\.\d{2,4}\s+\d{1,2}:\d{2}:\d{2},\s+[^:]+:\s*")

def looks_like_telegram_txt(s: bytes) -> bool:
  text = s.decode("utf-8", "ignore")
  hits = 0
  for raw in text.splitlines()[:40]:
    line = raw.strip()
    if not line:
      continue
    if line and ord(line[0]) == 0xfeff:
      line = line[1:]
    if "your telegram history" in line.lower():
      return True
    if TG_TXT_RE.match(line):
      hits += 1
      if hits >= 2:
        return True
  return False

def looks_like_generic_chat_json(obj) -> bool:
  if not isinstance(obj, list):
    return False
  for item in obj[:10]:
    if isinstance(item, dict) and any(k in item for k in ("message","text","content")):
      return True
  return False

def looks_like_gemini_json(obj) -> bool:
  return isinstance(obj, dict) and isinstance(obj.get("messages"), list) and ("sessionId" in obj or "projectHash" in obj)

def looks_like_chatgpt_export(obj) -> bool:
  # ChatGPT "conversations.json" export: list of conversations w/ "mapping".
  if not isinstance(obj, list) or not obj:
    return False
  first = obj[0]
  if not (isinstance(first, dict) and isinstance(first.get("mapping"), dict)):
    return False
  # Heuristic: some combination of these fields tends to exist.
  if "title" in first and ("create_time" in first or "update_time" in first):
    return True
  # Some exports nest under "conversation_id" etc; still treat mapping-driven list as ChatGPT-like.
  return True

def looks_like_deepseek_export(obj) -> bool:
  # DeepSeek export: list of conversations with mapping nodes containing message.fragments.
  if not isinstance(obj, list) or not obj:
    return False
  first = obj[0]
  if not (isinstance(first, dict) and isinstance(first.get("mapping"), dict)):
    return False
  m = first.get("mapping") or {}
  # Root node is often "root" and child nodes have message.fragments with REQUEST/RESPONSE.
  for k in ("root", "1", 1):
    node = m.get(k)
    if isinstance(node, dict):
      msg = node.get("message")
      if isinstance(msg, dict) and isinstance(msg.get("fragments"), list):
        return True
  # Scan a few nodes for fragments
  for node in list(m.values())[:10]:
    if isinstance(node, dict):
      msg = node.get("message")
      if isinstance(msg, dict) and isinstance(msg.get("fragments"), list):
        return True
  return False

def looks_like_grok_export(obj) -> bool:
  # Grok export: {"conversations":[{"conversation":{...},"responses":[{"response":{...}}]}]}
  if not isinstance(obj, dict):
    return False
  convs = obj.get("conversations")
  if not isinstance(convs, list) or not convs:
    return False
  first = convs[0]
  if not isinstance(first, dict):
    return False
  if isinstance(first.get("conversation"), dict) and isinstance(first.get("responses"), list):
    return True
  return False

def looks_like_google_gemini_myactivity(obj) -> bool:
  # Google Takeout "My Activity/Gemini Apps/MyActivity.json"
  if not isinstance(obj, list) or not obj:
    return False
  first = obj[0]
  if not isinstance(first, dict):
    return False
  if ("safeHtmlItem" in first or "safeHtmlItem".lower() in (k.lower() for k in first.keys())) and ("time" in first or "title" in first):
    # Further refine to Gemini Apps header/product when present.
    hdr = str(first.get("header") or "")
    prods = first.get("products") or []
    if "gemini" in hdr.lower():
      return True
    if any("gemini" in str(p).lower() for p in prods if p):
      return True
    # Some takeouts omit header/products; safeHtmlItem+title+time is strong enough.
    return True
  return False

def looks_like_codex_jsonl(s: bytes, p_low: str) -> bool:
  if b'"type":"response_item"' in s or b'"type":"event_msg"' in s:
    if b'"payload"' in s and b'"timestamp"' in s:
      return True
  if b'"type":"session_meta"' in s and b'"payload"' in s and b'"timestamp"' in s:
    return True
  if "/.codex/sessions/" in p_low and b'"payload"' in s and b'"timestamp"' in s:
    return True
  return False

def should_route_chat(path: str, ext: str, lazy_sniff):
  p_low = path.lower()
  base = os.path.basename(p_low)

  if ext in CHAT_JSONL_EXTS:
    t = lazy_sniff().lower()
    if looks_like_codex_jsonl(t, p_low):
      return "aichat"
    return False

  if ext in CHAT_HTML_EXTS:
    if "telegram" in p_low or "facebook" in p_low or "messenger" in p_low:
      return "chat"
    t = lazy_sniff().lower()
    if b"chatgpt data export" in t and b"var jsondata" in t:
      return "aichat"
    if b"message" in t:
      return "chat"
    return False

  if ext in CHAT_JSON_EXTS:
    try:
      import json as _json
      data = lazy_sniff()
      t = data.lower()
      # Fast-path: require *some* chat/LLM-ish structure before parsing.
      if (
        b'"messages"' not in t and b'"message"' not in t and b'"text"' not in t and b'"content"' not in t and
        b'"mapping"' not in t and b'"fragments"' not in t and b'"conversations"' not in t and b'"safehtmlitem"' not in t
      ):
        return False
      if not (
        base.startswith(("message", "messages", "result", "conversation", "conversations")) or
        "messages" in p_low or "telegram" in p_low or "facebook" in p_low or "messenger" in p_low or
        "chat" in p_low or "whatsapp" in p_low or "chatgpt" in p_low or "deepseek" in p_low or "grok" in p_low or "gemini" in p_low
      ):
        if (
          b'"sender"' not in t and b'"sender_name"' not in t and b'"from"' not in t and b'"actor"' not in t and
          b'"timestamp"' not in t and b'"date"' not in t and b'"mapping"' not in t and b'"fragments"' not in t and b'"conversations"' not in t
        ):
          return False

      # Heuristics that work on prefix sniffs (large exports won't fit in SNIFF_LIMIT).
      if b'"messages"' in t and (b'"sessionid"' in t or b'"projecthash"' in t):
        return "aichat"
      # ChatGPT export: list of convs w/ mapping/author/create_time.
      if b'"mapping"' in t and b'"author"' in t and (b'"create_time"' in t or b'"update_time"' in t):
        return "aichat"
      # DeepSeek export: mapping + fragments REQUEST/RESPONSE.
      if b'"fragments"' in t and b'"inserted_at"' in t and (b'"request"' in t or b'"response"' in t):
        return "aichat"
      # Grok export: conversations + responses (+ response/conversation metadata).
      # Some exports don't include "sender" early in the file, so don't require it here.
      if b'"conversations"' in t and b'"responses"' in t and (b'"response"' in t or b'"conversation"' in t or b'"create_time"' in t):
        return "aichat"
      # Google Takeout Gemini Apps activity.
      if b'"safehtmlitem"' in t and b'"title"' in t and (b'"gemini apps"' in t or b'"prompted' in t):
        return "aichat"

      # If the JSON fits entirely in the sniff buffer, parse it to detect chat apps.
      tail = t.strip()
      if len(data) < SNIFF_LIMIT and (tail.endswith(b"}") or tail.endswith(b"]")):
        obj = _json.loads(data.decode("utf-8", "ignore"))
        if looks_like_gemini_json(obj) or looks_like_chatgpt_export(obj) or looks_like_deepseek_export(obj) or looks_like_grok_export(obj) or looks_like_google_gemini_myactivity(obj):
          return "aichat"
        if looks_like_telegram_json(obj) or looks_like_messenger_json(obj) or looks_like_generic_chat_json(obj):
          return "chat"
    except Exception:
      pass
    return False

  if ext in CHAT_SQLITE_EXTS:
    if "telegram" in p_low or "database" in base or "messenger" in p_low or "whatsapp" in p_low:
      return "chat"
    t = lazy_sniff().lower()
    if b"messages" in t and (b"sender" in t or b"text" in t or b"time" in t):
      return "chat"
    return False

  if ext in CHAT_TXT_EXTS:
    if "whatsapp" in p_low or "chat" in base or "messages" in p_low:
      return "chat"
    if looks_like_whatsapp_txt(lazy_sniff()):
      return "chat"
    if looks_like_telegram_txt(lazy_sniff()):
      return "chat"
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
      "excluded": 0,           # excluded by mode (chat/nochat)
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

with open(out_text, "wb") as ft, open(out_rich, "wb") as fr, open(out_chat, "wb") as fc, open(out_aichat, "wb") as fa, open(out_xlsx, "wb") as fx, open(out_pptx, "wb") as fp, open(out_doc, "wb") as fd:
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

    if chat_mode or no_chat_mode:
      sniff_data = [None]
      def lazy_sniff():
        if sniff_data[0] is None:
          sniff_data[0] = sniff(p)
        return sniff_data[0]

      route = should_route_chat(p, ext, lazy_sniff)
      if route:
        if chat_mode:
          sd["attempted"] += 1
          if route == "aichat":
            write_nul(fa, p)
          else:
            write_nul(fc, p)
        else:
          sd["excluded"] += 1
        continue
      if chat_mode:
        sd["excluded"] += 1
        continue

    # Ignore Office temp/lock files for docx/xlsx/pptx (only after hidden gate, so they don't distort hidden)
    if is_office_temp(p, ext):
      sd["skipped_own"] += 1
      sd["skipped_bad_rich"] += 1
      bad.append(f"skip-office-temp(~$): {p}")
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
    echo "search flags: hidden=$SEARCH_HIDDEN uuu=$SEARCH_UUU binary=$SEARCH_BINARY no_ignore=$NO_IGNORE ucount=$UCOUNT case_sensitive=$CASE_SENSITIVE"
    echo "ext filter: mode=$EXT_FILTER_MODE"
    echo "have_rga_preproc=$HAVE_RGA_PREPROC have_xlsx2csv=$HAVE_XLSX2CSV have_pptx=$HAVE_PPTX have_doc=$HAVE_DOC"
    echo "parallel: text=$PAR_TEXT rich=$PAR_RICH xlsx=$PAR_XLSX pptx=$PAR_PPTX doc=$PAR_DOC"
    echo "batch:    text=$BATCH_TEXT rich=$BATCH_RICH xlsx=$BATCH_XLSX pptx=$BATCH_PPTX doc=$BATCH_DOC"
    echo "paths: ${PATHS[*]}"
  } >&2
fi

MIN_RICH_SIZE=128
if [[ "$VERBOSE" -eq 1 ]]; then
  python3 "$tmp_split" "$tmp_all" "$tmp_text" "$tmp_rich" "$tmp_chat_list" "$tmp_aichat_list" "$tmp_xlsx_list" "$tmp_pptx_list" "$tmp_doc_list" "$tmp_bad_rich" "$tmp_stats_json" \
    "$EXT_FILTER_MODE" "$(IFS=,; echo "${FILTER_EXTS[*]}")" "$HAVE_RGA_PREPROC" "$MIN_RICH_SIZE" "$SEARCH_HIDDEN" "$CHAT_MODE" "$NOCHAT" 1>&2
else
  python3 "$tmp_split" "$tmp_all" "$tmp_text" "$tmp_rich" "$tmp_chat_list" "$tmp_aichat_list" "$tmp_xlsx_list" "$tmp_pptx_list" "$tmp_doc_list" "$tmp_bad_rich" "$tmp_stats_json" \
    "$EXT_FILTER_MODE" "$(IFS=,; echo "${FILTER_EXTS[*]}")" "$HAVE_RGA_PREPROC" "$MIN_RICH_SIZE" "$SEARCH_HIDDEN" "$CHAT_MODE" "$NOCHAT" 2>/dev/null >/dev/null || true
fi

: >"$tmp_chat_all"
[[ -s "$tmp_chat_list" ]] && cat "$tmp_chat_list" >>"$tmp_chat_all"
[[ -s "$tmp_aichat_list" ]] && cat "$tmp_aichat_list" >>"$tmp_chat_all"

# Skip list persisted after rg run (heuristics + rg skips)

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

  if [[ "$VERBOSE" -eq 1 ]]; then
    {
      echo "run_rg_json_parallel: par=$par batch=$batch list=$listfile errfile=$errfile"
      printf '  cmd: %s\n' "$cmd_q"
    } >&2
  fi

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
	        if [ \"\$ec\" -eq 1 ] || { [ ${ALLOW_BROKEN_PIPE} -eq 1 ] && [ \"\$ec\" -eq 141 ]; }; then exit 0; fi
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
	      local st=0
	      if wait -n -p donepid "${active[@]}"; then st=0; else st=$?; fi
	      if [[ "$st" -ne 0 ]]; then
	        if [[ "$ALLOW_BROKEN_PIPE" -eq 1 && "$st" -eq 141 ]]; then :; else any_err=1; fi
	      fi
	      local out="${out_by_pid[$donepid]:-}"
	      if [[ -n "$out" && -s "$out" ]]; then
	        if [[ "$ALLOW_BROKEN_PIPE" -eq 1 ]]; then
	          cat "$out" 2>/dev/null || true
	        else
	          cat "$out"
	        fi
	        : >"$out"
	      fi
	      remove_pid_from_array active "$donepid"
	    done
	  else
	    local pid
	    for pid in "${pids[@]}"; do
	      local st=0
	      if wait "$pid"; then st=0; else st=$?; fi
	      if [[ "$st" -ne 0 ]]; then
	        if [[ "$ALLOW_BROKEN_PIPE" -eq 1 && "$st" -eq 141 ]]; then :; else any_err=1; fi
	      fi
	    done
	    local pid2
	    for pid2 in "${pids[@]}"; do
	      local out="${out_by_pid[$pid2]:-}"
	      if [[ -n "$out" && -s "$out" ]]; then
	        if [[ "$ALLOW_BROKEN_PIPE" -eq 1 ]]; then
	          cat "$out" 2>/dev/null || true
	        else
	          cat "$out"
	        fi
	      fi
	    done
	  fi

  rm -rf "$gdir"
  [[ "$any_err" -eq 1 ]] && return 2
  return 0
}

# Optional chat prefilter: skip parsing chat files without raw matches
if [[ "$CHAT_MODE" -eq 1 && "$CHAT_PREFILTER" -eq 1 && -s "$tmp_chat_all" ]]; then
  python3 - "$tmp_chat_all" "$tmp_chat_text_list" "$tmp_chat_bin_list" <<'PY'
import os, sys

in_path, out_text, out_bin = sys.argv[1:4]
BIN_EXTS = {b".sqlite", b".sqlite3", b".db"}

try:
  data = open(in_path, "rb").read()
except Exception:
  data = b""

paths = [p for p in data.split(b"\0") if p]
text_paths = []
bin_paths = []
for p in paths:
  base = os.path.basename(p)
  ext = os.path.splitext(base)[1].lower()
  if ext in BIN_EXTS:
    bin_paths.append(p)
  else:
    text_paths.append(p)

def write_list(path, items):
  with open(path, "wb") as f:
    for p in items:
      f.write(p)
      f.write(b"\0")

write_list(out_text, text_paths)
write_list(out_bin, bin_paths)
PY

  prefilter_failed=0
  : >"$tmp_chat_prefilter"

  if [[ -s "$tmp_chat_text_list" ]]; then
    RG_CHAT_PREFILTER=(rg "${RG_COMMON[@]}" --files-with-matches --null -- "$PATTERN")
    if [[ "$VERBOSE" -eq 0 ]]; then
      RG_CHAT_PREFILTER+=(--no-messages)
    fi
    if ! run_rg_json_parallel "$tmp_chat_text_list" "$PAR_TEXT" "$BATCH_TEXT" "$tmp_err_chat_prefilter" "${RG_CHAT_PREFILTER[@]}" >"$tmp_chat_prefilter"; then
      prefilter_failed=1
    fi
  fi

  if [[ "$prefilter_failed" -eq 0 ]]; then
    python3 - "$tmp_chat_prefilter" "$tmp_chat_bin_list" "$tmp_chat_all" <<'PY'
import sys

prefilter_path, bin_path, out_path = sys.argv[1:4]

def read_paths(path):
  try:
    data = open(path, "rb").read()
  except Exception:
    return []
  return [p for p in data.split(b"\0") if p]

paths = read_paths(prefilter_path) + read_paths(bin_path)

with open(out_path, "wb") as f:
  for p in paths:
    f.write(p)
    f.write(b"\0")
PY
  elif [[ "$VERBOSE" -eq 1 ]]; then
    echo "chat prefilter: failed; using full chat list" >&2
  fi
fi

start_ns="$(date +%s%N)"

RG_BASE=(rg "${RG_COMMON[@]}" --json --no-heading -C "$CTX_LINES" --context-separator "")
if [[ "$VERBOSE" -eq 0 ]]; then
  RG_BASE+=(--no-messages)
fi

RG_CHAT=("${RG_BASE[@]}" --pre "$tmp_chat" -- "$PATTERN")
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
    run_rg_json_parallel "$tmp_chat_all" "$PAR_TEXT" "$BATCH_TEXT" "$tmp_err_chat" "${RG_CHAT[@]}"; r=$?
    [[ "$r" -ge 2 ]] && warn_groups=$((warn_groups+1))
  else
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
  fi

  echo "$warn_groups" >"$tmp_rc2"
  exit 0
) | python3 "$tmp_fmt" "$BEFORE" "$AFTER" "$CTX_LINES" "$tmp_mc" "$MATCH_FILES_PERSIST" "$CHAT_MODE" "$COUNTS_ONLY" "$tmp_chat" "$tmp_skip_rg" "$BEFORE_TO_LINE_START" "$MERGE_MODE" "$PAGE" "$PAGE_SIZE"

end_ns="$(date +%s%N)"

if [[ "$COUNTS_ONLY" -eq 1 ]]; then
  python3 - <<PY 1>&2
start = int("$start_ns")
end = int("$end_ns")
elapsed = max(0, end - start)
print(f"Time taken: {elapsed / 1_000_000_000:.3f}s")
PY
else
  python3 - <<PY
start = int("$start_ns")
end = int("$end_ns")
elapsed = max(0, end - start)
print(f"Time taken: {elapsed / 1_000_000_000:.3f}s")
PY
fi

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

: >"$FAIL_PERSIST"
for err in "$tmp_err_text" "$tmp_err_chat" "$tmp_err_rich" "$tmp_err_xlsx" "$tmp_err_pptx" "$tmp_err_doc"; do
  python3 "$tmp_failparse" "$err" "$tmp_fail_out" || true
  if [[ -s "$tmp_fail_out" ]]; then
    cat "$tmp_fail_out" >>"$FAIL_PERSIST"
  fi
done

# Persist skip list (heuristics + rg skips)
: >"$SKIP_PERSIST"
if [[ -s "$tmp_bad_rich" ]]; then
  cat "$tmp_bad_rich" >>"$SKIP_PERSIST"
fi
if [[ -s "$tmp_skip_rg" ]]; then
  cat "$tmp_skip_rg" >>"$SKIP_PERSIST"
fi

if [[ -s "$SKIP_PERSIST" && "$VERBOSE" -eq 1 ]]; then
  echo "[g] note: some files were skipped; see: $SKIP_PERSIST" >&2
fi
if [[ "$warn_groups" -gt 0 ]]; then
  echo "[g] warnings: ${warn_groups} group(s) reported rc>=2 at least once (extraction/IO errors). Matches (if any) were still reported." >&2
  echo "[g] failed-file logs:" >&2
  echo "  $FAIL_PERSIST" >&2
fi

# ------------------------------------------------------------
# Verbose end-of-run summary
# ------------------------------------------------------------
if [[ "$VERBOSE" -eq 1 ]]; then
cat >"$tmp_vsum" <<'PY'
import json, os, sys
from collections import defaultdict

stats_path, fail_path, skip_rg_path = sys.argv[1:4]

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

ingest_fail(fail_path)

skip_rg = defaultdict(int)
def ingest_skip_rg(p):
  try:
    with open(p, "r", encoding="utf-8", errors="replace") as f:
      for raw in f:
        line = raw.strip()
        if not line:
          continue
        path = line
        if ":" in line:
          _, path = line.split(":", 1)
          path = path.strip()
        if path:
          skip_rg[ext_of(path)] += 1
  except Exception:
    pass

ingest_skip_rg(skip_rg_path)

rows = []
tot_scanned = tot_hidden = tot_blisted = tot_excluded = tot_skipped = tot_failed = 0
tot_files = 0

all_exts = set(ext_stats.keys()) | set(fail.keys()) | set(skip_rg.keys())

for ext in all_exts:
  d = ext_stats.get(ext, {}) or {}

  seen = int(d.get("seen", 0) or 0)
  tot_files += seen

  scanned = int(d.get("attempted", 0) or 0)
  hidden  = int(d.get("hidden_skipped", 0) or 0)
  blisted = int(d.get("blacklisted", 0) or 0)
  excluded = int(d.get("excluded", 0) or 0)
  skipped_own = int(d.get("skipped_own", 0) or 0)
  skipped_rg = int(skip_rg.get(ext, 0) or 0)
  skipped = skipped_own + skipped_rg
  failed  = int(fail.get(ext, 0) or 0)

  if (scanned + hidden + blisted + excluded + skipped + failed) <= 0:
    continue

  rows.append((ext, scanned, hidden, blisted, excluded, skipped, failed))

  tot_scanned += scanned
  tot_hidden  += hidden
  tot_blisted += blisted
  tot_excluded += excluded
  tot_skipped += skipped
  tot_failed += failed

def key(r):
  ext, scn, hid, bl, ex, sk, fl = r
  tot = scn + hid + bl + ex + sk
  return (-tot, -scn, -hid, -bl, -ex, -sk, -fl, ext)

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
print(f"excluded:  {tot_excluded}")
print(f"skipped:   {tot_skipped}")
print(f"failed:    {tot_failed}")
print("---- end scan totals ----\n")

print("---- per-extension scan summary (top 100) ----")
print(f"{'ext':<{W}} {fmt_cell('scanned')} {fmt_cell('hidden')} {fmt_cell('blisted')} {fmt_cell('exclude')} {fmt_cell('skipped')} {fmt_cell('failed')}")

for i, (ext, scn, hid, bl, ex, sk, fl) in enumerate(rows, start=1):
  if i <= TOPN:
    print(f"{fmt_ext(ext)} {scn:>{W}d} {hid:>{W}d} {bl:>{W}d} {ex:>{W}d} {sk:>{W}d} {fl:>{W}d}")
  else:
    other[0] += scn
    other[1] += hid
    other[2] += bl
    other[3] += ex
    other[4] += sk
    other[5] += fl

if len(rows) > TOPN:
  print(f"{fmt_ext('other')} {other[0]:>{W}d} {other[1]:>{W}d} {other[2]:>{W}d} {other[3]:>{W}d} {other[4]:>{W}d} {other[5]:>{W}d}")

print("---- end per-extension scan summary ----\n")
PY

  python3 "$tmp_vsum" "$tmp_stats_json" "$FAIL_PERSIST" "$tmp_skip_rg" 1>&2
fi

if [[ "$COUNTS_ONLY" -eq 1 ]]; then
  # Machine-friendly: stdout is only the TSV counts.
  [[ -s "$MATCH_FILES_PERSIST" ]] && cat "$MATCH_FILES_PERSIST"
  [[ "$match_count" -gt 0 ]] && exit 0
  exit 1
fi

if [[ "$match_count" -gt 0 ]]; then
  echo "Search exit code (overall): 0"
  exit 0
else
  echo "Search exit code (overall): 1"
  exit 1
fi
