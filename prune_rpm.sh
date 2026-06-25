#!/usr/bin/env bash
set -euo pipefail
###############################################################################
# prune_and_push_rpms.sh (PRODUCTION-READY - Complete RPM resolver)
# OPTIMIZED VERSION - Fast RPM discovery with caching
#
# 1) Auto-discover manifest pairs from root image directory
# 2) Compute diffs per target, resolve deps (full transitive closure)
# 3) Copy RPMs intelligently (armv8_2a vs target-specific)
# 4) Build deps.xlsx with per-target sheets
# 5) Optionally push to Artifactory
###############################################################################

# ─── Colours ──────────────────────────────────────────────────────────────────
if [[ -t 2 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ─── Logging ──────────────────────────────────────────────────────────────────
LOG_FILE=""

_log(){
  local lvl="$1" colour="$2"; shift 2
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf "${colour}[%s] [%-7s] %s${RESET}\n" "$ts" "$lvl" "$*" >&2
  if [[ -n "$LOG_FILE" ]]; then
    printf "[%s] [%-7s] %s\n" "$ts" "$lvl" "$*" >> "$LOG_FILE" || true
  fi
}

die()    { _log "ERROR"   "$RED"    "$*"; exit 1; }
warn()   { _log "WARN"    "$YELLOW" "$*"; }
note()   { _log "INFO"    "$CYAN"   "$*"; }
ok()     { _log "OK"      "$GREEN"  "$*"; }

header() {
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}" >&2
  echo -e "${BOLD}${CYAN}  $*${RESET}" >&2
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}" >&2
  if [[ -n "$LOG_FILE" ]]; then
    echo "=== $* ===" >> "$LOG_FILE" || true
  fi
}

need(){
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: '$1'."
}

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
cat <<USAGE
${BOLD}Usage:${RESET}
  $0 --image-dir <dir> --repo-dir <dir> [options]

${BOLD}Global options:${RESET}
  --repo-dir      DIR    Required: RPM repo root
  --image-dir     DIR    Image root with target subdirs
  --outdir        DIR    Output root              (default: ./out)
  --workdir       DIR    Working directory        (default: ./manifest_compare_out)
  --prefer-arch   ARCH   Preferred arch           (default: aarch64)
  --armv8_2a-arches ARCHES Colon-separated arch dirs (default: noarch:armv8_2a)
  --no-xlsx              Skip building deps.xlsx
  --no-copy              Skip RPM copy step
  --dry-run              Show what would happen without doing it
  --push                 Enable push to Artifactory
  --arti-url      URL    Artifactory URL
  --arti-repo     REPO   Artifactory repo name
  --arti-path     PATH   Artifactory path
  --arti-user     USER   Artifactory username
  --arti-token    TOKEN  Artifactory token
  -h|--help              Show this help
USAGE
}

# ─── Requirements (checked early) ──────────────────────────────────────────────
for _cmd in sed grep sort python3 find cp wc date timeout curl; do 
  need "$_cmd"
done

# ─── Defaults ─────────────────────────────────────────────────────────────────
WORKDIR="./manifest_compare_out"
OUTDIR="./out"
REPO_DIR=""
PREFER_ARCH="aarch64"
armv8_2a_ARCHES="noarch:armv8_2a"
NO_XLSX=false
NO_COPY=false
DRY_RUN=false
PUSH=false
ARTI_URL="https://artifacts.codelinaro.org/artifactory"
ARTI_REPO="clo-555-signed-rpm-packages"
ARTI_PATH=""
ARTI_USER=""
ARTI_TOKEN=""
IMAGE_DIR=""

TARGET_NAMES=()
TARGET_A=()
TARGET_B=()
armv8_2a_ARCH_DIRS=()

# ─── Argument Parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-dir)      IMAGE_DIR="$2";      shift 2 ;;
    --repo-dir)       REPO_DIR="$2";       shift 2 ;;
    --outdir)         OUTDIR="$2";         shift 2 ;;
    --workdir)        WORKDIR="$2";        shift 2 ;;
    --prefer-arch)    PREFER_ARCH="$2";    shift 2 ;;
    --armv8_2a-arches)  armv8_2a_ARCHES="$2";  shift 2 ;;
    --no-xlsx)        NO_XLSX=true;        shift ;;
    --no-copy)        NO_COPY=true;        shift ;;
    --dry-run)        DRY_RUN=true;        shift ;;
    --push)           PUSH=true;           shift ;;
    --arti-url)       ARTI_URL="$2";       shift 2 ;;
    --arti-repo)      ARTI_REPO="$2";      shift 2 ;;
    --arti-path)      ARTI_PATH="$2";      shift 2 ;;
    --arti-user)      ARTI_USER="$2";      shift 2 ;;
    --arti-token)     ARTI_TOKEN="$2";     shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) die "Unknown argument: '$1'" ;;
  esac
done

# ─── Early Validation ──────────────────────────────────────────────────────────
[[ -z "$REPO_DIR" ]] && die "--repo-dir is required"
[[ -d "$REPO_DIR" ]] || die "Repo dir not found: $REPO_DIR"

# Parse architecture directories
OLD_IFS="$IFS"
IFS=':' read -ra armv8_2a_ARCH_DIRS <<< "$armv8_2a_ARCHES" || die "Failed to parse --armv8_2a-arches"
IFS="$OLD_IFS"

# ─── Setup ────────────────────────────────────────────────────────────────────
mkdir -p "$WORKDIR" "$OUTDIR" || die "Failed to create working directories"
LOG_FILE="$WORKDIR/run_$(date '+%Y%m%d_%H%M%S').log"
touch "$LOG_FILE" || die "Failed to create log file: $LOG_FILE"
note "Logging to: $LOG_FILE"

# ─── Auto-discover manifests ──────────────────────────────────────────────────
discover_manifests(){
  local img_dir="$1"
  [[ -d "$img_dir" ]] || die "Image dir not found: $img_dir"

  header "Auto-discovering Manifests in: $img_dir"

  local tgt_dirs=()
  while IFS= read -r d; do
    [[ -n "$d" ]] && tgt_dirs+=("$d")
  done < <(find -L "$img_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  [[ ${#tgt_dirs[@]} -eq 0 ]] && die "No subdirectories found in: $img_dir"

  local found=0
  for tgt_dir in "${tgt_dirs[@]}"; do
    local tgt; tgt="$(basename "$tgt_dir")"
    note "Scanning [$tgt]"

    local man_a="" man_b=""
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local bname; bname="$(basename "$f")"
      [[ "$bname" =~ \.rootfs-[0-9]+\.manifest$ ]] && continue
      man_a="$f"
      break
    done < <(find -L "$tgt_dir" -maxdepth 1 -type f -name "*proprietary*.rootfs.manifest" 2>/dev/null | sort)

    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local bname; bname="$(basename "$f")"
      [[ "$bname" == *proprietary* ]] && continue
      [[ "$bname" =~ \.rootfs-[0-9]+\.manifest$ ]] && continue
      man_b="$f"
      break
    done < <(find -L "$tgt_dir" -maxdepth 1 -type f -name "*multimedia*.rootfs.manifest" 2>/dev/null | sort)

    [[ -z "$man_a" || -z "$man_b" ]] && { warn "[$tgt] Missing manifest pair - skipping"; continue; }

    TARGET_NAMES+=("$tgt")
    TARGET_A+=("$man_a")
    TARGET_B+=("$man_b")
    found=$(( found + 1 ))
  done

  [[ $found -eq 0 ]] && die "No valid manifest pairs found"
  ok "Discovered $found target(s)"
}

[[ -n "$IMAGE_DIR" ]] && discover_manifests "$IMAGE_DIR"
[[ ${#TARGET_NAMES[@]} -eq 0 ]] && die "No targets defined"

# ─── EMBEDDED: Full RPM Resolver ──────────────────────────────────────────────
resolve_dependencies() {
  local targets_file="$1" output_csv="$2" label="$3"
  
  if [[ ! -s "$targets_file" ]]; then
    warn "$label: diff empty — writing empty CSV"
    python3 - "$output_csv" <<'PY'
import csv, sys
hdr = ["Target Package","Needed Package","Needed EVR","Architecture","Provided Virtuals","Location Href","Source Repo"]
with open(sys.argv[1], "w", newline="", encoding="utf-8") as f:
    csv.writer(f).writerow(hdr)
PY
    return 0
  fi

  note "$label: resolving $(wc -l < "$targets_file") packages"

  python3 - "$REPO_DIR" "$targets_file" "$output_csv" "$PREFER_ARCH" <<'RESOLVER_PY'
import csv, sys, os, re, gzip, io, subprocess, xml.etree.ElementTree as ET
from collections import defaultdict, deque
from pathlib import Path

repo_dir = sys.argv[1]
targets_file = sys.argv[2]
output_csv = sys.argv[3]
prefer_arch = sys.argv[4]

ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
NS = {
    "common": "http://linux.duke.edu/metadata/common",
    "rpm": "http://linux.duke.edu/metadata/rpm",
    "repomd": "http://linux.duke.edu/metadata/repo",
}

def decompress_zst(data):
    try:
        import zstandard as zstd
        dctx = zstd.ZstdDecompressor()
        with dctx.stream_reader(io.BytesIO(data)) as reader:
            chunks = []
            while True:
                chunk = reader.read(16384)
                if not chunk:
                    break
                chunks.append(chunk)
        return b"".join(chunks)
    except:
        try:
            p = subprocess.run(["zstd", "-d", "-c", "-q"], input=data, stdout=subprocess.PIPE, timeout=30, check=False)
            return p.stdout
        except subprocess.TimeoutExpired:
            print(f"WARNING: zstd timeout", file=sys.stderr)
            return data
        except:
            return data

def open_maybe_compressed(path):
    with open(path, "rb") as f:
        data = f.read()
    if path.endswith(".gz") or data[:2] == b"\x1f\x8b":
        try:
            data = gzip.decompress(data)
        except:
            pass
    elif path.endswith(".zst") or data.startswith(ZSTD_MAGIC):
        data = decompress_zst(data)
    return io.BytesIO(data)

def find_primary_xml(repodata_dir):
    repomd_path = os.path.join(repodata_dir, "repomd.xml")
    if not os.path.exists(repomd_path):
        return None
    try:
        tree = ET.parse(repomd_path)
        root = tree.getroot()
        for data in root.findall("repomd:data", NS):
            if data.get("type") == "primary":
                loc = data.find("repomd:location", NS)
                if loc is not None:
                    href = loc.attrib.get("href")
                    if href:
                        repo_root = os.path.dirname(repodata_dir)
                        return os.path.join(repo_root, href)
    except:
        pass
    return None

def parse_primary_xml(primary_path, repo_id):
    pkgs = {}
    try:
        bio = open_maybe_compressed(primary_path)
        tree = ET.parse(bio)
        root = tree.getroot()
        
        for pkg in root.findall("common:package", NS):
            if pkg.get("type") != "rpm":
                continue
            
            name_el = pkg.find("common:name", NS)
            arch_el = pkg.find("common:arch", NS)
            ver_el = pkg.find("common:version", NS)
            loc_el = pkg.find("common:location", NS)
            fmt_el = pkg.find("common:format", NS)
            
            name = (name_el.text if name_el is not None else "") or ""
            arch = (arch_el.text if arch_el is not None else "") or ""
            epoch = ver_el.get("epoch") if ver_el is not None else None
            version = ver_el.get("ver", "") if ver_el is not None else ""
            release = ver_el.get("rel", "") if ver_el is not None else ""
            location_href = loc_el.attrib.get("href") if loc_el is not None else None
            
            provides = set([name])
            depends = []
            
            if fmt_el is not None:
                provs = fmt_el.find("rpm:provides", NS)
                if provs is not None:
                    for ent in provs.findall("rpm:entry", NS):
                        n = ent.get("name")
                        if n and not n.startswith("rpmlib("):
                            provides.add(n)
                
                reqs = fmt_el.find("rpm:requires", NS)
                if reqs is not None:
                    for ent in reqs.findall("rpm:entry", NS):
                        n = ent.get("name")
                        if not n or n.startswith("rpmlib(") or n.startswith("config("):
                            continue
                        depends.append(n)
            
            pkgs[name] = {
                "arch": arch,
                "epoch": epoch,
                "version": version,
                "release": release,
                "location_href": location_href,
                "source_repo": repo_id,
                "provides": provides,
                "depends": depends,
            }
    except Exception as e:
        print(f"Error parsing {primary_path}: {e}", file=sys.stderr)
    
    return pkgs

all_pkgs = {}
providers_map = defaultdict(list)

for root, dirs, files in os.walk(repo_dir):
    if "repodata" in dirs:
        repo_id = os.path.basename(root)
        repodata = os.path.join(root, "repodata")
        primary = find_primary_xml(repodata)
        
        if primary and os.path.exists(primary):
            pkgs = parse_primary_xml(primary, repo_id)
            for name, info in pkgs.items():
                if name not in all_pkgs:
                    all_pkgs[name] = info
                for prov in info["provides"]:
                    if name not in providers_map[prov]:
                        providers_map[prov].append(name)

targets = set()
try:
    with open(targets_file) as f:
        for line in f:
            s = line.strip()
            if s and not s.startswith("#"):
                targets.add(s)
except IOError as e:
    print(f"ERROR: Cannot read targets file {targets_file}: {e}", file=sys.stderr)
    raise

def resolve_deps(root_pkg):
    needed = set()
    visited = set()
    queue = deque([root_pkg])
    visited.add(root_pkg)
    
    while queue:
        current = queue.popleft()
        if current not in all_pkgs:
            continue
        
        for dep in all_pkgs[current].get("depends", []):
            if dep in providers_map:
                candidates = providers_map[dep]
                provider = dep if dep in candidates else sorted(candidates)[0]
                
                if provider and provider not in visited:
                    visited.add(provider)
                    if provider != root_pkg:
                        needed.add(provider)
                    queue.append(provider)
    
    return needed

rows = []
for tgt in sorted(targets):
    deps = resolve_deps(tgt)
    for dep in sorted(deps):
        if dep in all_pkgs:
            info = all_pkgs[dep]
            evr = f"{info['epoch']}:{info['version']}-{info['release']}" if info['epoch'] else f"{info['version']}-{info['release']}"
            rows.append({
                "Target Package": tgt,
                "Needed Package": dep,
                "Needed EVR": evr,
                "Architecture": info["arch"],
                "Provided Virtuals": ", ".join(sorted(info["provides"])),
                "Location Href": info["location_href"] or "",
                "Source Repo": info["source_repo"],
            })

with open(output_csv, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=["Target Package","Needed Package","Needed EVR","Architecture","Provided Virtuals","Location Href","Source Repo"])
    writer.writeheader()
    for r in rows:
        writer.writerow(r)
RESOLVER_PY

  [[ $? -eq 0 ]] || die "Resolver failed for $label"
  ok "$label: resolver finished"
}

# ─── Per-target: normalise, diff, resolve, extract ────────────────────────────
for i in "${!TARGET_NAMES[@]}"; do
  TGT="${TARGET_NAMES[$i]}"
  TGT_DIR="$WORKDIR/$TGT"
  mkdir -p "$TGT_DIR" || die "Failed to create $TGT_DIR"

  header "[$TGT] Step 1/3 — Normalise & Diff"
  A_NORM="$TGT_DIR/A.normalized.txt"
  B_NORM="$TGT_DIR/B.normalized.txt"
  sed 's/[[:space:]].*$//' "${TARGET_A[$i]}" | sed '/^[[:space:]]*$/d' | sort -u > "$A_NORM" || die "Failed to normalize A manifest: ${TARGET_A[$i]}"
  sed 's/[[:space:]].*$//' "${TARGET_B[$i]}" | sed '/^[[:space:]]*$/d' | sort -u > "$B_NORM" || die "Failed to normalize B manifest: ${TARGET_B[$i]}"
  ok "$TGT: A → $(wc -l < "$A_NORM") pkgs   B → $(wc -l < "$B_NORM") pkgs"

  A_MINUS_B="$TGT_DIR/difference_A_minus_B.txt"
  B_MINUS_A="$TGT_DIR/difference_B_minus_A.txt"
  grep -Fxvf "$B_NORM" "$A_NORM" > "$A_MINUS_B" || true
  grep -Fxvf "$A_NORM" "$B_NORM" > "$B_MINUS_A" || true
  note "$TGT: A−B=$(wc -l < "$A_MINUS_B")  B−A=$(wc -l < "$B_MINUS_A")"

  header "[$TGT] Step 2/3 — Resolve Dependencies"
  DEPS_A="$TGT_DIR/deps_A_minus_B.csv"
  DEPS_B="$TGT_DIR/deps_B_minus_A.csv"
  resolve_dependencies "$A_MINUS_B" "$DEPS_A" "$TGT A−B"
  resolve_dependencies "$B_MINUS_A" "$DEPS_B" "$TGT B−A"

  header "[$TGT] Step 3/3 — Extract Package Lists"
  PKGS_ALL="$TGT_DIR/pkgs_all.txt"

  python3 - "$DEPS_A" "$DEPS_B" "$A_MINUS_B" "$B_MINUS_A" "$PKGS_ALL" "$TGT" <<'PY'
import csv, sys
from pathlib import Path

deps_a, deps_b, diff_a, diff_b, out_all, tgt = sys.argv[1:]

def extract_csv(csv_path):
    pkgs = set()
    p = Path(csv_path)
    if not p.exists(): 
        return pkgs
    try:
        with p.open(newline="", encoding="utf-8", errors="ignore") as f:
            reader = csv.reader(f)
            next(reader, None)
            for row in reader:
                if row and len(row) >= 2:
                    pkgs.add(row[0])
                    pkgs.add(row[1])
    except Exception as e:
        print(f"Error reading {csv_path}: {e}", file=sys.stderr)
        raise
    return pkgs

def read_lines(path):
    p = Path(path)
    if not p.exists(): 
        return set()
    try:
        return {l.strip() for l in p.read_text().splitlines() if l.strip()}
    except Exception as e:
        print(f"Error reading {path}: {e}", file=sys.stderr)
        raise

a = extract_csv(deps_a)
b = extract_csv(deps_b)

if not a:
    a = read_lines(diff_a)
if not b:
    b = read_lines(diff_b)

allp = a | b

def write_sorted(path, items):
    Path(path).write_text("\n".join(sorted(items)) + ("\n" if items else ""), encoding="utf-8")

write_sorted(out_all, allp)
print(f"  [{tgt}] total={len(allp)}")
PY

  [[ $? -eq 0 ]] || die "Failed to extract packages for $TGT"
  ok "$TGT: package lists written"
done

# ─── Split armv8_2a vs target-specific ──────────────────────────────────────────
header "Splitting armv8_2a vs Target-Specific"

TARGET_NAMES_STR=$(IFS='|'; echo "${TARGET_NAMES[*]}")

python3 - "$WORKDIR" "$REPO_DIR" "$armv8_2a_ARCHES" "$TARGET_NAMES_STR" <<'PY'
import sys, subprocess, os, re
from pathlib import Path

workdir = sys.argv[1]
repo_dir = sys.argv[2]
armv8_2a_arches = sys.argv[3].split(":")
targets = sys.argv[4].split("|")
repo_path = Path(repo_dir)

armv8_2a_dirs = [str(repo_path / a) for a in armv8_2a_arches if (repo_path / a).is_dir()]
target_repo_dirs = {}
for t in targets:
    t_underscore = t.replace("-", "_")
    repo_subdir = repo_path / t_underscore
    if repo_subdir.is_dir():
        target_repo_dirs[t] = str(repo_subdir)

print(f"  armv8_2a arch dirs: {armv8_2a_dirs}")
print(f"  Target repo dirs: {target_repo_dirs}")

def escape_regex_chars(s):
    return re.escape(s)

def find_rpms_in_dirs(pkg, search_dirs):
    found = []
    for d in search_dirs:
        if not Path(d).is_dir():
            continue
        escaped_pkg = escape_regex_chars(pkg)
        try:
            r = subprocess.run(
                ["find", "-L", d, "-type", "f", "-regextype", "posix-extended",
                 "-regex", f".*/{escaped_pkg}-[0-9].*\\.rpm"],
                capture_output=True, text=True, timeout=30)
            found += [p for p in r.stdout.strip().splitlines() if p.strip()]
        except subprocess.TimeoutExpired:
            print(f"  ERROR: find timeout in {d}", file=sys.stderr)
            raise
        except Exception as e:
            print(f"  ERROR: find failed in {d}: {e}", file=sys.stderr)
            raise
    return sorted(found)

target_pkgs = {}
for tgt in targets:
    pkgs_all = Path(workdir) / tgt / "pkgs_all.txt"
    if not pkgs_all.exists():
        raise FileNotFoundError(f"Missing {pkgs_all}")
    target_pkgs[tgt] = set(l.strip() for l in pkgs_all.read_text().splitlines() if l.strip())
    print(f"  [{tgt}] pkgs_all: {len(target_pkgs[tgt])}")

all_pkgs = set()
for pkgs in target_pkgs.values():
    all_pkgs |= pkgs
print(f"  Total unique: {len(all_pkgs)}")

if not target_repo_dirs:
    print(f"  No target-specific repos - treating ALL as armv8_2a")
    armv8_2a_pkgs = all_pkgs
    per_target_specific = {t: set() for t in targets}
else:
    armv8_2a_pkgs = set()
    per_target_specific = {t: set() for t in targets}
    for pkg in all_pkgs:
        in_armv8_2a_dir = bool(find_rpms_in_dirs(pkg, armv8_2a_dirs))
        if in_armv8_2a_dir:
            armv8_2a_pkgs.add(pkg)
        else:
            for tgt in targets:
                if pkg in target_pkgs[tgt]:
                    per_target_specific[tgt].add(pkg)

def ws(path, items):
    Path(path).write_text("\n".join(sorted(items)) + ("\n" if items else ""), encoding="utf-8")

ws(Path(workdir) / "pkgs_armv8_2a.txt", armv8_2a_pkgs)
print(f"  [global] armv8_2a: {len(armv8_2a_pkgs)}")

for tgt in targets:
    specific = per_target_specific[tgt]
    ws(Path(workdir) / tgt / "pkgs_target_specific.txt", specific)
    print(f"  [{tgt}] specific: {len(specific)}")
PY

[[ $? -eq 0 ]] || die "Failed to split packages"
ok "Split complete"

# ─── Build deps.xlsx ──────────────────────────────────────────────────────────
if ! $NO_XLSX; then
  header "Build deps.xlsx"
  XLSX_OUT="$WORKDIR/deps.xlsx"
  
  TARGET_NAMES_STR=$(IFS='|'; echo "${TARGET_NAMES[*]}")
  
  python3 - "$WORKDIR" "$XLSX_OUT" "$TARGET_NAMES_STR" <<'PY'
import csv, sys
from pathlib import Path

workdir, xlsx_out = sys.argv[1], sys.argv[2]
targets = sys.argv[3].split("|")

try:
    from openpyxl import Workbook
    from openpyxl.styles import Font, PatternFill, Alignment
    from openpyxl.utils import get_column_letter
except ImportError:
    print("WARN: openpyxl not installed - skipping xlsx", file=sys.stderr)
    raise SystemExit(0)

HFILL = PatternFill("solid", fgColor="1F4E79")
HFONT = Font(bold=True, color="FFFFFF")

def style(ws):
    for c in ws[1]:
        c.fill = HFILL
        c.font = HFONT
        c.alignment = Alignment(horizontal="center")
    ws.freeze_panes = "A2"

def aw(ws):
    for col in ws.columns:
        w = max((len(str(c.value or "")) for c in col), default=10)
        ws.column_dimensions[get_column_letter(col[0].column)].width = min(w+4, 60)

def add_csv(wb, title, pth):
    ws = wb.create_sheet(title=title[:31])
    p = Path(pth)
    if not p.exists():
        ws.append(["ERROR: Missing file"])
        return
    rows = list(csv.reader(p.open(newline="", encoding="utf-8", errors="ignore")))
    for r in rows:
        ws.append(r)
    if rows:
        style(ws)
    aw(ws)

def add_txt(wb, title, pth):
    ws = wb.create_sheet(title=title[:31])
    p = Path(pth)
    if not p.exists():
        ws.append(["ERROR: Missing file"])
        return
    ws.append(["Package"])
    style(ws)
    for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.strip():
            ws.append([line.strip()])
    aw(ws)

wb = Workbook()
wb.remove(wb.active)
add_txt(wb, "armv8_2a_pkgs", str(Path(workdir) / "pkgs_armv8_2a.txt"))
for tgt in targets:
    d = Path(workdir) / tgt
    add_csv(wb, f"{tgt}_A-B_deps", str(d / "deps_A_minus_B.csv"))
    add_csv(wb, f"{tgt}_B-A_deps", str(d / "deps_B_minus_A.csv"))
    add_txt(wb, f"{tgt}_specific", str(d / "pkgs_target_specific.txt"))
wb.save(xlsx_out)
print(f"  Wrote: {xlsx_out}")
PY

  [[ $? -eq 0 ]] || die "Failed to build deps.xlsx"
fi

# ─── Copy RPMs function ────────────────────────────────────────────────────────
copy_rpms() {
  local PKG_LIST="$1" DEST_DIR="$2" LABEL="$3" TARGET_ARCH_FILTER="${4:-}"
  shift 4
  local RPM_SEARCH_DIRS=("$@")
  
  [[ -f "$PKG_LIST" ]] || die "[$LABEL] Package list not found: $PKG_LIST"
  
  local total_pkgs; total_pkgs=$(grep -c '[^[:space:]]' "$PKG_LIST" || echo 0)
  (( total_pkgs == 0 )) && { note "[$LABEL] No packages to copy"; return 0; }

  mkdir -p "$DEST_DIR" || die "Failed to create $DEST_DIR"
  note "[$LABEL] $total_pkgs packages → $DEST_DIR"
  [[ -n "$TARGET_ARCH_FILTER" ]] && note "[$LABEL] Arch filter: $TARGET_ARCH_FILTER"
  $DRY_RUN && warn "[$LABEL] DRY-RUN mode"

  # OPTIMIZATION: Pre-cache all available RPMs
  note "[$LABEL] Scanning for available RPMs..."
  local RPM_CACHE_FILE
  RPM_CACHE_FILE=$(mktemp) || die "Failed to create temp file"
  trap "rm -f '$RPM_CACHE_FILE'" RETURN
  
  for sdir in "${RPM_SEARCH_DIRS[@]}"; do
    [[ -d "$sdir" ]] || continue
    timeout 120 find -L "$sdir" -type f -name "*.rpm" 2>/dev/null >> "$RPM_CACHE_FILE" || true
  done
  
  local rpm_cache_size; rpm_cache_size=$(wc -l < "$RPM_CACHE_FILE")
  note "[$LABEL] Indexed $rpm_cache_size RPM files"

  local copied=0 skipped=0 missing=0 current=0 pkg
  local MISSING_LIST=()

  while IFS= read -r pkg || [[ -n "$pkg" ]]; do
    pkg="${pkg#"${pkg%%[![:space:]]*}"}"
    pkg="${pkg%"${pkg##*[![:space:]]}"}"
    [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
    current=$(( current + 1 ))

    # FIXED: Use simple string matching without complex regex escaping
    # This handles all special characters naturally
    local all_matches=""
    
    # Step 1: Try direct match - package name followed by hyphen and digit
    all_matches=$(grep "/${pkg}-[0-9]" "$RPM_CACHE_FILE" 2>/dev/null || true)
    
    # Step 2: If not found and package ends with digit, try splitting
    # Example: libstdc++6 -> search for /libstdc++-6-
    if [[ -z "$all_matches" ]] && [[ "$pkg" =~ ([0-9]+)$ ]]; then
      local trailing_digit="${BASH_REMATCH[1]}"
      local pkg_base="${pkg%${trailing_digit}}"
      # Use plain grep without regex - treats pattern as literal string
      all_matches=$(grep "/${pkg_base}-${trailing_digit}-" "$RPM_CACHE_FILE" 2>/dev/null || true)
    fi
    
    # Step 3: Try with dot separator
    if [[ -z "$all_matches" ]]; then
      all_matches=$(grep "/${pkg}\." "$RPM_CACHE_FILE" 2>/dev/null || true)
    fi

    if [[ -z "$all_matches" ]]; then
      warn "[$LABEL][$current/$total_pkgs] ✗ NOT FOUND: $pkg"
      MISSING_LIST+=("$pkg")
      missing=$(( missing + 1 ))
      continue
    fi

    local matches="$all_matches"
    if [[ -n "$TARGET_ARCH_FILTER" ]]; then
      local filtered_matches=""
      
      # Try exact arch match first
      filtered_matches=$(echo "$all_matches" | grep -E "\.${TARGET_ARCH_FILTER}\.rpm$" || true)
      
      # Fallback to noarch
      if [[ -z "$filtered_matches" ]]; then
        filtered_matches=$(echo "$all_matches" | grep -E "\.noarch\.rpm$" || true)
      fi
      
      # Fallback to armv8_2a if not looking for noarch
      if [[ -z "$filtered_matches" && "$TARGET_ARCH_FILTER" != "noarch" ]]; then
        filtered_matches=$(echo "$all_matches" | grep -E "\.armv8_2a\.rpm$" || true)
      fi
      
      # Reject if no suitable match found
      if [[ -z "$filtered_matches" ]]; then
        local available_archs
        available_archs=$(echo "$all_matches" | xargs -I {} basename {} | sed 's/.*\.\([^.]*\)\.rpm$/\1/' | sort -u | tr '\n' ',' | sed 's/,$//')
        warn "[$LABEL][$current/$total_pkgs] ✗ ARCH MISMATCH: $pkg (need: $TARGET_ARCH_FILTER, available: $available_archs)"
        MISSING_LIST+=("$pkg [ARCH_MISMATCH]")
        missing=$(( missing + 1 ))
        continue
      fi
      
      matches="$filtered_matches"
    fi

    # If multiple versions available, pick latest
    local rpm_count; rpm_count=$(echo "$matches" | wc -l)
    local rpm
    if (( rpm_count > 1 )); then
      rpm=$(echo "$matches" | sort -V | tail -1)
    else
      rpm=$(echo "$matches" | head -1)
    fi

    [[ -z "$rpm" ]] && continue
    
    local bname; bname="$(basename "$rpm")"
    
    # Check if already exists
    if [[ -f "$DEST_DIR/$bname" ]]; then
      note "[$LABEL][$current/$total_pkgs] ⊘ SKIP (exists): $bname"
      skipped=$(( skipped + 1 ))
      continue
    fi
    
    if $DRY_RUN; then
      ok "[$LABEL][$current/$total_pkgs] DRY: $bname"
    else
      cp "$rpm" "$DEST_DIR/" || die "[$LABEL] Failed to copy: $bname from $rpm"
      ok "[$LABEL][$current/$total_pkgs] ✓ $bname"
    fi
    copied=$(( copied + 1 ))
  done < "$PKG_LIST"

  # Report statistics
  note "[$LABEL] Summary: copied=$copied skipped=$skipped missing=$missing"
  
  if (( missing > 0 )); then
    die "[$LABEL] ERROR: $missing package(s) not found/matched. Missing: ${MISSING_LIST[*]}"
  fi
}

if ! $NO_COPY; then
  header "Copy RPMs"

  armv8_2a_SEARCH=()
  for arch in "${armv8_2a_ARCH_DIRS[@]}"; do
    d="$REPO_DIR/$arch"
    [[ -d "$d" ]] && armv8_2a_SEARCH+=("$d")
  done
  [[ ${#armv8_2a_SEARCH[@]} -eq 0 ]] && armv8_2a_SEARCH+=("$REPO_DIR")

  copy_rpms "$WORKDIR/pkgs_armv8_2a.txt" "$OUTDIR/armv8_2a" "armv8_2a" "" "${armv8_2a_SEARCH[@]}"

  for tgt in "${TARGET_NAMES[@]}"; do
    TGT_SPECIFIC="$WORKDIR/$tgt/pkgs_target_specific.txt"
    TGT_ARCH_SUFFIX="${tgt//-/_}"
    
    TGT_SEARCH=()
    [[ -d "$REPO_DIR/$TGT_ARCH_SUFFIX" ]] && TGT_SEARCH+=("$REPO_DIR/$TGT_ARCH_SUFFIX")
    for arch in "${armv8_2a_ARCH_DIRS[@]}"; do
      [[ -d "$REPO_DIR/$arch" ]] && TGT_SEARCH+=("$REPO_DIR/$arch")
    done
    TGT_SEARCH+=("$REPO_DIR")

    copy_rpms "$TGT_SPECIFIC" "$OUTDIR/$tgt" "$tgt" "$TGT_ARCH_SUFFIX" "${TGT_SEARCH[@]}"
  done
fi

# ─── Push to Artifactory Function ─────────────────────────────────────────────
push_to_artifactory() {
  if [[ -z "$ARTI_USER" ]]; then
    read -rp "Artifactory username: " ARTI_USER || die "Failed to read username"
  fi
  
  if [[ -z "$ARTI_TOKEN" ]]; then
    read -rsp "Artifactory token: " ARTI_TOKEN && echo || die "Failed to read token"
  fi
  
  if [[ -z "$ARTI_PATH" ]]; then
    read -rp "Artifactory path: " ARTI_PATH || die "Failed to read path"
  fi
  
  [[ -z "$ARTI_USER" ]] && die "Artifactory username is required"
  [[ -z "$ARTI_TOKEN" ]] && die "Artifactory token is required"
  [[ -z "$ARTI_PATH" ]] && die "Artifactory path is required"

  header "Push to Artifactory"
  
  local dirs_to_push=()
  [[ -d "$OUTDIR/armv8_2a" ]] && dirs_to_push+=("$OUTDIR/armv8_2a")
  for tgt in "${TARGET_NAMES[@]}"; do
    [[ -d "$OUTDIR/$tgt" ]] && dirs_to_push+=("$OUTDIR/$tgt")
  done
  
  [[ ${#dirs_to_push[@]} -eq 0 ]] && { warn "No output directories to push"; return 0; }
  
  for dir_path in "${dirs_to_push[@]}"; do
    local dir_name; dir_name=$(basename "$dir_path")
    local total; total=$(find -L "$dir_path" -type f 2>/dev/null | wc -l)
    (( total == 0 )) && { note "[$dir_name] No files"; continue; }

    note "Pushing [$dir_name] ($total files) → $ARTI_PATH/$dir_name"
    
    local push_fail=0
    local file_count=0
    
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      file_count=$(( file_count + 1 ))
      
      local REL; REL="${file#"$dir_path"/}"
      local ENCODED_REL
      ENCODED_REL=$(printf '%s\n' "$REL" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe='/'))" 2>/dev/null) || {
        warn "  Failed to URL-encode path: $REL, using raw path"
        ENCODED_REL="$REL"
      }
      [[ -z "$ENCODED_REL" ]] && ENCODED_REL="$REL"
      
      local DEST; DEST="${ARTI_URL}/${ARTI_REPO}/${ARTI_PATH}/${dir_name}/${ENCODED_REL}"
      
      if $DRY_RUN; then
        ok "  DRY: $REL"
      else
        local HTTP_CODE
        HTTP_CODE=$(timeout 60 curl -sSL -u "${ARTI_USER}:${ARTI_TOKEN}" -X PUT "$DEST" -T "$file" -w "%{http_code}" -o /dev/null) || HTTP_CODE="000"
        if [[ "$HTTP_CODE" =~ ^2 ]]; then
          ok "  ✓ [$HTTP_CODE] $REL"
        else
          warn "  ✗ [$HTTP_CODE] $REL"
          push_fail=$(( push_fail + 1 ))
        fi
      fi
    done < <(find -L "$dir_path" -type f 2>/dev/null)
    
    note "  [$dir_name] Processed $file_count files, $push_fail failed"
    (( push_fail > 0 )) && die "Push failed for [$dir_name]: $push_fail file(s)"
  done
  
  ok "Push complete"
}

if $PUSH; then
  push_to_artifactory
fi

# ─── Verify Output ────────────────────────────────────────────────────────────
header "Verifying Output"

verify_dir_exists_with_files() {
  local dir="$1" label="$2"
  if [[ ! -d "$dir" ]]; then
    warn "$label: Directory not found: $dir"
    return 1
  fi
  local count; count=$(find -L "$dir" -type f 2>/dev/null | wc -l)
  if (( count == 0 )); then
    warn "$label: No files found"
    return 1
  fi
  ok "$label: $count files"
  return 0
}

verify_dir_exists_with_files "$OUTDIR/armv8_2a" "armv8_2a" || true

for tgt in "${TARGET_NAMES[@]}"; do
  verify_dir_exists_with_files "$OUTDIR/$tgt" "$tgt" || true
done

# ─── Final Summary ────────────────────────────────────────────────────────────
header "Done"
ok "All steps completed successfully"
note "Workdir : $WORKDIR"
note "Outdir  : $OUTDIR"
note "Log     : $LOG_FILE"
note ""
note "Summary:"
note "  armv8_2a: $(find -L "$OUTDIR/armv8_2a" -type f 2>/dev/null | wc -l) files"
for tgt in "${TARGET_NAMES[@]}"; do
  COUNT=$(find -L "$OUTDIR/$tgt" -type f 2>/dev/null | wc -l)
  note "  $tgt: $COUNT files"
done
note ""
note "Output structure:"
note "  $OUTDIR/armv8_2a/  ← Shared RPMs (noarch + armv8_2a)"
for tgt in "${TARGET_NAMES[@]}"; do
  note "  $OUTDIR/$tgt/     ← Target-specific RPMs"
done
