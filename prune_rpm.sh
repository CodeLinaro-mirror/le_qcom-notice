#!/usr/bin/env bash
set -euo pipefail
###############################################################################
# prune_and_push_rpms.sh (FULLY EMBEDDED - Complete RPM resolver from resolver.py)
#
# 1) Auto-discover manifest pairs from a root image directory
# 2) Compute diffs per target, resolve deps (full transitive closure via resolver.py logic)
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

regex_escape() {
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '.'|'['|']'|'\'|'^'|'$'|'('|')'|'|'|'*'|'+'|'?'|'{'|'}')
        out+="\\$c" ;;
      *)
        out+="$c" ;;
    esac
  done
  printf '%s' "$out"
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
  --no-xlsx              Skip building deps.xlsx
  --no-copy              Skip RPM copy step
  --dry-run              Show what would happen without doing it
  --push                 Enable push to Artifactory
  -h|--help              Show this help
USAGE
}

# ─── Requirements ─────────────────────────────────────────────────────────────
for _cmd in sed grep sort python3 find cp wc date; do need "$_cmd"; done

# ─── Defaults ─────────────────────────────────────────────────────────────────
WORKDIR="./manifest_compare_out"
OUTDIR="./out"
REPO_DIR=""
PREFER_ARCH="aarch64"
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

# ─── Argument Parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-dir)      IMAGE_DIR="$2";      shift 2 ;;
    --repo-dir)       REPO_DIR="$2";       shift 2 ;;
    --outdir)         OUTDIR="$2";         shift 2 ;;
    --workdir)        WORKDIR="$2";        shift 2 ;;
    --prefer-arch)    PREFER_ARCH="$2";    shift 2 ;;
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

# ─── Setup ────────────────────────────────────────────────────────────────────
mkdir -p "$WORKDIR" "$OUTDIR"
LOG_FILE="$WORKDIR/run_$(date '+%Y%m%d_%H%M%S').log"
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

    # Detect whether this target has a robotics-proprietary-image manifest
    local robotics_probe
    robotics_probe=$(find -L "$tgt_dir" -maxdepth 1 -type f \
      -name "*robotics-proprietary-image*.rootfs.manifest" 2>/dev/null | head -1)

    local a_pattern b_pattern
    if [[ -n "$robotics_probe" ]]; then
      a_pattern="*robotics-proprietary-image*.rootfs.manifest"
      b_pattern="*robotics-image*.rootfs.manifest"
      note "[$tgt] Using robotics manifest patterns"
    else
      a_pattern="*proprietary*.rootfs.manifest"
      b_pattern="*multimedia*.rootfs.manifest"
    fi

    local man_a="" man_b=""
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local bname; bname="$(basename "$f")"
      [[ "$bname" =~ \.rootfs-[0-9]+\.manifest$ ]] && continue
      man_a="$f"
      break
    done < <(find -L "$tgt_dir" -maxdepth 1 -type f -name "$a_pattern" 2>/dev/null | sort)

    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local bname; bname="$(basename "$f")"
      [[ "$bname" == *proprietary* ]] && continue
      [[ "$bname" =~ \.rootfs-[0-9]+\.manifest$ ]] && continue
      man_b="$f"
      break
    done < <(find -L "$tgt_dir" -maxdepth 1 -type f -name "$b_pattern" 2>/dev/null | sort)

    [[ -z "$man_a" || -z "$man_b" ]] && { warn "[$tgt] Missing manifests"; continue; }

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
[[ -d "$REPO_DIR" ]] || die "Repo dir not found: $REPO_DIR"

# ─── EMBEDDED: Full RPM Resolver (from resolver.py) ──────────────────────────
resolve_dependencies() {
  local targets_file="$1" output_csv="$2" label="$3"

  if [[ ! -s "$targets_file" ]]; then
    warn "$label: diff empty — writing empty CSV."
    python3 - "$output_csv" <<'PY'
import csv, sys
hdr = ["Target Package","Needed Package","Needed EVR","Architecture","Provided Virtuals","Location Href","Source Repo"]
with open(sys.argv[1], "w", newline="", encoding="utf-8") as f:
    csv.writer(f).writerow(hdr)
PY
    return 0
  fi

  note "$label: resolving $(wc -l < "$targets_file") packages …"

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
            p = subprocess.run(["zstd", "-d", "-c", "-q"], input=data, stdout=subprocess.PIPE, check=False)
            return p.stdout
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

# Discover and parse all repos
all_pkgs = {}
providers_map = defaultdict(set)

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
                    providers_map[prov].add(name)

# Load targets
targets = set()
with open(targets_file) as f:
    for line in f:
        s = line.strip()
        if s and not s.startswith("#"):
            targets.add(s)

# Resolve dependencies (BFS - full transitive closure)
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
                provider = sorted(providers_map[dep])[0]
                if provider not in visited:
                    visited.add(provider)
                    if provider != root_pkg:
                        needed.add(provider)
                    queue.append(provider)

    return needed

# Write output
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

  ok "$label: resolver finished → $output_csv"
}
# ─── Per-target: normalise, diff, resolve, extract ────────────────────────────
for i in "${!TARGET_NAMES[@]}"; do
  TGT="${TARGET_NAMES[$i]}"
  TGT_DIR="$WORKDIR/$TGT"
  mkdir -p "$TGT_DIR"

  header "[$TGT] Step 1/3 — Normalise & Diff"
  A_NORM="$TGT_DIR/A.normalized.txt"
  B_NORM="$TGT_DIR/B.normalized.txt"
  sed 's/[[:space:]].*$//' "${TARGET_A[$i]}" | sed '/^[[:space:]]*$/d' | sort -u > "$A_NORM"
  sed 's/[[:space:]].*$//' "${TARGET_B[$i]}" | sed '/^[[:space:]]*$/d' | sort -u > "$B_NORM"
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
import csv, re, sys
from pathlib import Path

deps_a, deps_b, diff_a, diff_b, out_all, tgt = sys.argv[1:]

KERNEL_VER_SUFFIX_RE = re.compile(
    r'-\d+\.\d+\.\d+(?:-rc\d+)?-\d+-g[0-9a-fA-F]+(?:-dirty)?$'
)

def prune_kernel_pkg(name: str) -> str:
    if name.startswith("kernel"):
        return KERNEL_VER_SUFFIX_RE.sub("", name)
    return name

def extract_csv(csv_path):
    pkgs = set()
    p = Path(csv_path)
    if not p.exists(): return pkgs
    with p.open(newline="", encoding="utf-8", errors="ignore") as f:
        reader = csv.reader(f)
        next(reader, None)  # skip header
        for row in reader:
            if row and len(row) >= 2:
                pkgs.add(prune_kernel_pkg(row[0]))
                pkgs.add(prune_kernel_pkg(row[1]))
    return pkgs

def read_lines(path):
    p = Path(path)
    if not p.exists(): return set()
    return {prune_kernel_pkg(l.strip()) for l in p.read_text().splitlines() if l.strip()}

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


  ok "$TGT: package lists written."
done

# ─── Build deps.xlsx ──────────────────────────────────────────────────────────
if ! $NO_XLSX; then
  header "Build deps.xlsx"
  XLSX_OUT="$WORKDIR/deps.xlsx"
  python3 - "$WORKDIR" "$XLSX_OUT" "${TARGET_NAMES[@]}" <<'PY'
import csv, sys
from pathlib import Path

workdir, xlsx_out = sys.argv[1], sys.argv[2]
targets = sys.argv[3:]

try:
    from openpyxl import Workbook
    from openpyxl.styles import Font, PatternFill, Alignment
    from openpyxl.utils import get_column_letter
except ImportError:
    print("WARN: openpyxl not installed — skipping deps.xlsx")
    raise SystemExit(0)

HFILL = PatternFill("solid", fgColor="1F4E79")
HFONT = Font(bold=True, color="FFFFFF")

def style(ws):
    for c in ws[1]:
        c.fill = HFILL; c.font = HFONT
        c.alignment = Alignment(horizontal="center")
    ws.freeze_panes = "A2"

def aw(ws):
    for col in ws.columns:
        w = max((len(str(c.value or "")) for c in col), default=10)
        ws.column_dimensions[get_column_letter(col[0].column)].width = min(w+4,60)

def add_csv(wb, title, pth):
    ws = wb.create_sheet(title=title[:31])
    p = Path(pth)
    if not p.exists(): ws.append([f"Missing: {pth}"]); return
    rows = list(csv.reader(p.open(newline="", encoding="utf-8", errors="ignore")))
    for r in rows: ws.append(r)
    if rows: style(ws)
    aw(ws)

def add_txt(wb, title, pth):
    ws = wb.create_sheet(title=title[:31])
    p = Path(pth)
    if not p.exists(): ws.append([f"Missing: {pth}"]); return
    ws.append(["Package"]); style(ws)
    for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.strip(): ws.append([line.strip()])
    aw(ws)

wb = Workbook(); wb.remove(wb.active)
for tgt in targets:
    d = Path(workdir) / tgt
    add_csv(wb, f"{tgt}_A-B_deps", str(d / "deps_A_minus_B.csv"))
    add_csv(wb, f"{tgt}_B-A_deps", str(d / "deps_B_minus_A.csv"))
    add_txt(wb, f"{tgt}_specific", str(d / "pkgs_target_specific.txt"))
wb.save(xlsx_out)
print(f"  Wrote: {xlsx_out}")
PY
fi

# ─── Copy RPMs ────────────────────────────────────────────────────────────────
copy_rpms() {
  local PKG_LIST="$1" DEST_DIR="$2" LABEL="$3" TARGET_ARCH_FILTER="${4:-}"
  shift 4
  local RPM_SEARCH_DIRS=("$@")

  [[ -f "$PKG_LIST" ]] || { warn "[$LABEL] Package list not found"; return 1; }
  local total_pkgs; total_pkgs=$(grep -c '[^[:space:]]' "$PKG_LIST" || echo 0)
  (( total_pkgs == 0 )) && { note "[$LABEL] No packages"; return 0; }

  mkdir -p "$DEST_DIR"
  note "[$LABEL] $total_pkgs packages → $DEST_DIR"
  [[ -n "$TARGET_ARCH_FILTER" ]] && note "[$LABEL] Arch filter: $TARGET_ARCH_FILTER"
  $DRY_RUN && warn "[$LABEL] DRY-RUN"

  local copied=0 missing=0 current=0 pkg

  while IFS= read -r pkg || [[ -n "$pkg" ]]; do
    pkg="${pkg#"${pkg%%[![:space:]]*}"}"
    pkg="${pkg%"${pkg##*[![:space:]]}"}"
    [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
    current=$(( current + 1 ))

    local pkg_re; pkg_re="$(regex_escape "$pkg")"

    local all_matches=""
    for sdir in "${RPM_SEARCH_DIRS[@]}"; do
      [[ -d "$sdir" ]] || continue
      local hits
      hits=$(find -L "$sdir" -type f -regextype posix-extended -regex ".*/${pkg_re}-[0-9].*\.rpm" 2>/dev/null | sort)
      [[ -n "$hits" ]] && all_matches+="$hits"$'\n'
    done
    all_matches="$(printf '%s' "$all_matches" | sort -u)"
    all_matches="${all_matches%$'\n'}"

    if [[ -z "$all_matches" ]]; then
      warn "[$LABEL][$current/$total_pkgs] ⚠️  No RPM: $pkg"
      missing=$(( missing + 1 ))
      continue
    fi

    local matches="$all_matches"
    if [[ -n "$TARGET_ARCH_FILTER" ]]; then
      matches=$(echo "$all_matches" | grep -i "\.${TARGET_ARCH_FILTER}\.rpm$" || true)
      [[ -z "$matches" ]] && matches=$(echo "$all_matches" | grep -i "\.noarch\.rpm$" || true)
      [[ -z "$matches" ]] && matches=$(echo "$all_matches" | grep -i "\.armv8_2a\.rpm$" || true)
      [[ -z "$matches" ]] && matches="$all_matches"
    fi

    while IFS= read -r rpm; do
      [[ -z "$rpm" ]] && continue
      local bname; bname="$(basename "$rpm")"
      if [[ -f "$DEST_DIR/$bname" ]]; then
        note "[$LABEL] SKIP (exists): $bname"
        continue
      fi
      if $DRY_RUN; then
        ok "[$LABEL][$current/$total_pkgs] DRY-RUN: $bname"
      else
        cp "$rpm" "$DEST_DIR/"
        ok "[$LABEL][$current/$total_pkgs] ✅ $bname"
      fi
      copied=$(( copied + 1 ))
    done <<< "$matches"
  done < "$PKG_LIST"

  note "[$LABEL] copied=$copied  missing=$missing"
}

if ! $NO_COPY; then
  header "Copy RPMs (mirroring repo directory structure)"

  python3 - "$REPO_DIR" "$WORKDIR" "$OUTDIR" "$DRY_RUN" "${TARGET_NAMES[@]}" <<'PY'
import sys, re, shutil
from pathlib import Path

repo_dir, workdir, outdir, dry_run_s = sys.argv[1:5]
targets = sys.argv[5:]
dry_run = dry_run_s.lower() == "true"

repo_path = Path(repo_dir)
out_path = Path(outdir)

# Auto-discover actual repo subdirectories (whatever they're really named)
repo_subdirs = sorted([d for d in repo_path.iterdir() if d.is_dir()])

# Match repo subdirs to targets by name (dash <-> underscore)
target_map = {t.replace("-", "_"): t for t in targets}

target_owned = {}   # target(dashed-name) -> Path to its repo subdir
common_dirs  = []   # repo subdirs not owned by any specific target

for d in repo_subdirs:
    if d.name in target_map:
        target_owned[target_map[d.name]] = d
    else:
        common_dirs.append(d)

print(f"  Target-owned repo dirs : { {t: str(p) for t, p in target_owned.items()} }")
print(f"  Common repo dirs       : {[str(p) for p in common_dirs]}")

def find_rpms(pkg, search_dir):
    pkg_re = re.compile(re.escape(pkg) + r'-[0-9].*\.rpm$')
    return sorted(p for p in search_dir.rglob("*.rpm") if pkg_re.match(p.name))

def copy_file(src: Path, dest_dir: Path, label: str):
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / src.name
    if dest.exists():
        print(f"  [{label}] SKIP (exists): {src.name}")
        return
    if dry_run:
        print(f"  [{label}] DRY-RUN: {src.name}")
    else:
        shutil.copy2(src, dest)
        print(f"  [{label}] \u2705 {src.name}")

for tgt in targets:
    pkgs_all = Path(workdir) / tgt / "pkgs_all.txt"
    if not pkgs_all.exists():
        print(f"  [{tgt}] no pkgs_all.txt \u2014 skipping")
        continue
    pkgs = [l.strip() for l in pkgs_all.read_text().splitlines() if l.strip()]
    print(f"  [{tgt}] {len(pkgs)} packages to resolve")

    tgt_dir = target_owned.get(tgt)
    missing = []

    for pkg in pkgs:
        found_any = False

        # 1) Look in this target's own repo subdir first
        if tgt_dir is not None:
            for h in find_rpms(pkg, tgt_dir):
                copy_file(h, out_path / tgt, tgt)
                found_any = True

        # 2) Also mirror any hits from common/shared repo subdirs
        for cdir in common_dirs:
            for h in find_rpms(pkg, cdir):
                copy_file(h, out_path / cdir.name, f"{tgt}:{cdir.name}")
                found_any = True

        if not found_any:
            missing.append(pkg)

    if missing:
        print(f"  [{tgt}] \u26a0\ufe0f  {len(missing)} package(s) not found in any repo dir:")
        for m in missing:
            print(f"      - {m}")

print("Done.")
PY

  ok "RPM copy complete."
fi



# ─── Push to Artifactory ──────────────────────────────────────────────────────
if $PUSH; then
  need curl
  [[ -z "$ARTI_USER"  ]] && read -rp  "Artifactory username: " ARTI_USER
  [[ -z "$ARTI_TOKEN" ]] && read -rsp "Artifactory token: " ARTI_TOKEN && echo
  [[ -z "$ARTI_PATH"  ]] && read -rp  "Artifactory path: " ARTI_PATH

  # Strip leading/trailing slashes to avoid malformed (double-slash) URLs
  ARTI_PATH="${ARTI_PATH#/}"
  ARTI_PATH="${ARTI_PATH%/}"

  header "Push to Artifactory"

  OUT_SUBDIRS=()
  while IFS= read -r d; do
    [[ -n "$d" ]] && OUT_SUBDIRS+=("$d")
  done < <(find -L "$OUTDIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  if [[ ${#OUT_SUBDIRS[@]} -eq 0 ]]; then
    warn "No output subdirectories found under $OUTDIR — nothing to push."
  fi

  for dir_path in "${OUT_SUBDIRS[@]}"; do
    dir_name="$(basename "$dir_path")"
    DIR_TOTAL=$(find -L "$dir_path" -type f 2>/dev/null | wc -l)
    if (( DIR_TOTAL == 0 )); then
      note "Skipping [$dir_name] — no files."
      continue
    fi

    note "Pushing [$dir_name] ($DIR_TOTAL files) → $ARTI_PATH/$dir_name"

    # Use -printf '%P' so REL is always relative to $dir_path,
    # even if the build tree contains symlinked subdirectories.
    # This prevents the full workspace/absolute path from leaking
    # into the Artifactory destination URL.
    while IFS= read -r REL; do
      [[ -z "$REL" ]] && continue
      file="$dir_path/$REL"
      DEST="${ARTI_URL}/${ARTI_REPO}/${ARTI_PATH}/${dir_name}/${REL}"

      if $DRY_RUN; then
        ok "  DRY-RUN: $dir_name/$REL"
      else
        HTTP_CODE=$(curl -sSL -u "${ARTI_USER}:${ARTI_TOKEN}" -X PUT "$DEST" -T "$file" -w "%{http_code}" -o /dev/null) || true
        if [[ "$HTTP_CODE" =~ ^2 ]]; then
          ok "  ✅ [$HTTP_CODE] $dir_name/$REL"
        else
          warn "  ❌ [$HTTP_CODE] $dir_name/$REL"
        fi
      fi
    done < <(find -L "$dir_path" -type f -printf '%P\n' 2>/dev/null)
  done

  ok "Push complete"
fi

# ─── Final summary ────────────────────────────────────────────────────────────
header "Done"
ok "All steps completed."
note "Workdir  : $WORKDIR"
note "Outdir   : $OUTDIR"
note "Log file : $LOG_FILE"
note ""
note "Output layout (mirrors actual repo directory names):"
note "  $OUTDIR/<repo-subdir-name>/   <- for each repo dir matched (target-owned or shared)"
note ""
note "Workdir layout:"
for tgt in "${TARGET_NAMES[@]}"; do
  TGT_DIR="$WORKDIR/$tgt"
  note "  $TGT_DIR/"
  for f in difference_A_minus_B.txt difference_B_minus_A.txt \
            deps_A_minus_B.csv deps_B_minus_A.csv \
            pkgs_all.txt; do
    fp="$TGT_DIR/$f"
    [[ -f "$fp" ]] && note "    \u2714  $f  ($(wc -l < "$fp") lines)"
  done
done
[[ -f "$WORKDIR/deps.xlsx" ]] && note "  \u2714  $WORKDIR/deps.xlsx"
