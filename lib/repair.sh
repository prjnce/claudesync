# shellcheck shell=bash
# repair: fix legacy transcripts before the first sync (SPEC §19, ticket #15):
#   1. junk dirs inside projects/ (names that can never be slugs, e.g. *.bak-*): used as the source of
#      original bytes, then moved to ~/.claude-sync/backups
#   2. duplicate session ids between valid slug dirs
#   3. CRLF -> LF
#   4. re-serialized (spaced) JSON -> compact, in this order per line: (a) the original line's bytes from a
#      junk dir when it is JSON-equal, (b) node JSON.stringify(JSON.parse), (c) python3; else keep + report.
#      jq is only used read-only, to compare lines.
#   5. foreign cwd roots (/mnt/d/... on Windows, D:\... on Linux) -> this machine's project root
#   6. backups of every modified file, mtime kept; 7. report.
# Every *.jsonl under valid slug dirs is considered (main and subagent transcripts). Live sessions are
# skipped. Requires core, platform, version, store, claude, transform, projects, ui.

[[ -n ${CS_REPAIR_LOADED:-} ]] && return 0
CS_REPAIR_LOADED=1

# What the canonicalizer prints for a line that does not parse: jq -c renders the sentinel string as JSON.
CS_REPAIR_BAD='"\u0001CSBAD"'

# cs_equiv_path PATH: the same location as seen from the other OS family (WSL view of a Windows drive):
#   /mnt/d/x/y <-> D:\x\y. rc 1 if PATH has no such twin.
cs_equiv_path() {
  local p=$1
  if [[ $p =~ ^/mnt/([A-Za-z])(/.*)?$ ]]; then
    local rest=${BASH_REMATCH[2]:-/}
    printf '%s:%s\n' "${BASH_REMATCH[1]^^}" "${rest//\//\\}"
  elif [[ $p =~ ^([A-Za-z]):[\\/]?(.*)$ ]]; then
    local rest=${BASH_REMATCH[2]//\\//}
    printf '/mnt/%s/%s\n' "${BASH_REMATCH[1],,}" "$rest"
  else
    return 1
  fi
}

# cs_is_foreign_path PATH: rc 0 if PATH is in the other OS family's form (cannot be a cwd on this machine).
# On Windows a Git Bash drive path (/d/Projects/x, kept by Claude in wireIngestContext) is NOT foreign.
cs_is_foreign_path() {
  if [[ $CS_OS == windows ]]; then
    [[ $1 == /* && ! $1 =~ ^/[A-Za-z](/|$) ]]
  else
    [[ $1 =~ ^[A-Za-z]:[\\/] ]]
  fi
}

# cs_repair_files [SLUG...]: every transcript under valid slug dirs (or under the given ones):
# "relpath (from projects/)<TAB>size".
cs_repair_files() {
  local p
  p="$(cs_claude_dir)/projects"
  [[ -d $p ]] || return 0
  local -a dirs=()
  if (($#)); then
    local s
    for s in "$@"; do [[ -d $p/$s ]] && dirs+=("$p/$s"); done
  else
    local d
    for d in "$p"/*/; do
      d=${d%/}
      [[ ${d##*/} =~ ^[A-Za-z0-9_-]+$ ]] && dirs+=("$d")
    done
  fi
  ((${#dirs[@]})) || return 0
  local d
  for d in "${dirs[@]}"; do
    find "$d" -type f -name '*.jsonl' -printf "${d##*/}/%P\t%s\n"
  done
}

# cs_repair_needing: the "slug/<sid>.jsonl" paths that Claude could not load as they are (nothing is changed).
cs_repair_needing() {
  local rel size crs sp fo f
  while IFS=$'\t' read -r rel size; do
    [[ -n $rel ]] || continue
    f="$(cs_claude_dir)/projects/$rel"
    read -r crs sp fo < <(cs_repair_needs "$f")
    if ((crs || sp || fo)); then printf '%s\n' "$rel"; fi
  done < <(cs_repair_files)
}

# cs_repair_sid_of REL: the session id a transcript belongs to (main: <sid>.jsonl, sub: <sid>/subagents/...).
cs_repair_sid_of() {
  local r=${1#*/}
  r=${r%%/*}
  printf '%s\n' "${r%.jsonl}"
}

# cs_repair_needs FILE: "crs spaced foreign" for a transcript (spaced/foreign are 0/1).
cs_repair_needs() {
  local f=$1 crs sp=0 fo=0
  crs=$(tr -cd '\r' <"$f" | wc -c)
  # Compact JSON never contains an unescaped quote-colon-space-quote; re-serialized JSON always does.
  grep -q -F '": "' "$f" && sp=1
  if [[ $CS_OS == windows ]]; then
    # "/" not followed by a single drive letter: /mnt/d, /home, /root... but not Git Bash's /d/Projects
    grep -q -E '"cwd": ?"/([A-Za-z][^/"]|[^A-Za-z])' "$f" && fo=1
  else
    grep -q -E '"cwd": ?"[A-Za-z]:' "$f" && fo=1
  fi
  printf '%s %s %s\n' "$((crs))" "$sp" "$fo"
}

# cs_repair_foreign_cwds FILE: distinct foreign cwd values in FILE (any key spelling, read-only).
cs_repair_foreign_cwds() {
  tr -d '\r' <"$1" | grep -o -E '"(cwd|relocatedCwd)": ?"[^"]*"' | sed -E 's/^"[A-Za-z]+": ?"//; s/"$//' |
    sed 's/\\\\/\\/g' | sort -u | while IFS= read -r c; do cs_is_foreign_path "$c" && printf '%s\n' "$c"; done
  return 0
}

# cs_repair_alias_for FOREIGN_CWD: "project_id<TAB>foreign root<TAB>local root" — the project whose root
# contains the twin path of FOREIGN_CWD; rc 1 if none is mapped.
cs_repair_alias_for() {
  local twin id root
  twin=$(cs_equiv_path "$1") || return 1
  id=$(cs_project_of_cwd "$twin") || return 1
  while IFS=$'\t' read -r pid root _; do
    [[ $pid == "$id" ]] || continue
    if cs_path_under "$twin" "$root"; then
      printf '%s\t%s\t%s\n' "$id" "$(cs_equiv_path "$root")" "$root"
      return 0
    fi
  done < <(cs_tsv_rows projects)
  return 1
}

# cs_repair_compactor: stdin lines -> compact JSON lines, 1:1 (unparsable lines unchanged). node first
# (byte-identical to Claude's JSON.stringify), python3 next; prints nothing usable without either.
cs_repair_compactor_kind() {
  if command -v node >/dev/null 2>&1; then
    printf 'node\n'
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
    printf 'python\n'
  else
    printf 'none\n'
  fi
}

cs_repair_compact() {
  case $1 in
    node)
      node -e 'const rl = require("readline").createInterface({ input: process.stdin, crlfDelay: Infinity });
        rl.on("line", (l) => { let o; try { o = JSON.stringify(JSON.parse(l)); } catch (e) { o = l; } process.stdout.write(o + "\n"); });'
      ;;
    python)
      python3 -c '
import json, sys
for raw in sys.stdin.buffer:
    raw = raw.rstrip(b"\r\n")
    try:
        out = json.dumps(json.loads(raw.decode("utf-8", "surrogatepass")), separators=(",", ":"), ensure_ascii=False).encode("utf-8", "surrogatepass")
    except Exception:
        out = raw
    sys.stdout.buffer.write(out + b"\n")'
      ;;
    *) cat ;;
  esac
}

# The matcher. ENVIRON: FCMD (command printing the canonical form of each line of FR), FR (the file),
# OCMD/OR (same for the original; empty when there is none), MODE 1 (write lines to re-serialize to UIN,
# print counts) or 2 (print the repaired file, taking those lines back from UOUT in order; counts to CNT).
# Canonical form = the parsed line with sorted keys, so JSON-equal lines compare equal. A line with no
# original that is already compact (no unescaped quote-colon-space) is kept byte for byte.
# Counts: lines, from original, re-serialized, kept compact, unparsable.
CS_REPAIR_AWK='
function spaced(s,   p, q, k, n) {
  q = 0
  while ((p = index(substr(s, q + 1), "\": ")) > 0) {
    q += p
    n = 0
    for (k = q - 1; k >= 1 && substr(s, k, 1) == "\\"; k--) n++
    if (n % 2 == 0) return 1   # the quote is not escaped: a key followed by ": "
  }
  return 0
}
BEGIN {
  BAD = ENVIRON["BAD"]
  if (ENVIRON["OR"] != "") {
    ocmd = ENVIRON["OCMD"]; orf = ENVIRON["OR"]
    while ((ocmd | getline c) > 0) {
      if ((getline r < orf) <= 0) break
      sub(/\r$/, "", r)
      # An "original" can itself be a re-serialized copy (seen on real data): only compact lines count.
      if (c != BAD && !(c in M) && !spaced(r)) M[c] = r
    }
    close(ocmd); close(orf)
  }
  fcmd = ENVIRON["FCMD"]; fr = ENVIRON["FR"]; mode = ENVIRON["MODE"]
  while ((fcmd | getline c) > 0) {
    if ((getline r < fr) <= 0) r = ""
    sub(/\r$/, "", r)
    n++
    if (c == BAD) { nb++; out = r }
    else if (c in M) { no++; out = M[c] }
    else if (!spaced(r)) { nk++; out = r }
    else { nu++; if (mode == 1) print r > ENVIRON["UIN"]; else if ((getline out < ENVIRON["UOUT"]) <= 0) out = r }
    if (mode == 2) print out
  }
  if (mode == 1) print n + 0, no + 0, nu + 0, nk + 0, nb + 0
  else print n + 0, no + 0, nu + 0, nk + 0, nb + 0 > ENVIRON["CNT"]
}'

# Canonicalizers: the parsed line with sorted keys, compact; "\u0001CSBAD" for a line that does not parse.
# node or python3 — jq 1.6's raw-line mode corrupts multi-byte UTF-8 characters at buffer boundaries in
# long lines (found 2026-10-05: 121 lines of one real transcript), so it must not compare content.
# shellcheck disable=SC2089 # program text for node -e, passed through the environment, never word-split
CS_CANON_JS='const sk = (v) => Array.isArray(v) ? v.map(sk) : (v && typeof v === "object") ? Object.keys(v).sort().reduce((o, k) => (o[k] = sk(v[k]), o), {}) : v;
const rl = require("readline").createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (l) => { let o; try { o = JSON.stringify(sk(JSON.parse(l))); } catch (e) { o = JSON.stringify("\u0001CSBAD"); } process.stdout.write(o + "\n"); });'
# shellcheck disable=SC2089 # program text for python3 -c, passed through the environment
CS_CANON_PY='
import json, sys
for raw in sys.stdin.buffer:
    raw = raw.rstrip(b"\r\n")
    try:
        out = json.dumps(json.loads(raw.decode("utf-8", "surrogatepass")), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8", "surrogatepass")
    except Exception:
        out = json.dumps("\x01CSBAD").encode()
    sys.stdout.buffer.write(out + b"\n")'

# cs_repair_canon_cmd VAR: a POSIX sh command (awk runs it with /bin/sh, which is dash on Ubuntu) that
# prints the canonical form of every line of the file named by the environment variable VAR. Programs
# and paths travel in environment variables, never inside the command text, so no shell quoting rules
# (bash's $'...', non-ASCII paths) can break it.
cs_repair_canon_cmd() {
  case $(cs_repair_compactor_kind) in
    node) printf 'tr -d "\r" < "$%s" | node -e "$CS_CANON_JS"' "$1" ;;
    python) printf 'tr -d "\r" < "$%s" | python3 -c "$CS_CANON_PY"' "$1" ;;
    # jq without raw mode parses correctly but stops at the first broken line: then nothing matches.
    *) printf 'tr -d "\r" < "$%s" | jq -c -S . 2>/dev/null | tr -d "\r"' "$1" ;;
  esac
}

# cs_repair_one FILE ORIG ALIAS_ROWS LOCAL_ROWS OUT: repaired FILE into OUT (ORIG and the rows may be empty).
# Prints "lines from_orig recompacted kept unparsable tool out_lines out_crs". Never touches FILE.
cs_repair_one() {
  local f=$1 orig=$2 arows=$3 lrows=$4 out=$5 work kind stats cnt fcmd ocmd=''
  work=$(mktemp -d -p "$CS_HOME/staging" repair.XXXXXX)
  kind=$(cs_repair_compactor_kind)
  fcmd=$(cs_repair_canon_cmd CS_CANON_F)
  [[ -n $orig ]] && ocmd=$(cs_repair_canon_cmd CS_CANON_O)
  # shellcheck disable=SC2090 # exported as data for the canonicalizer commands, not expanded here
  export CS_CANON_JS CS_CANON_PY
  stats=$(BAD=$CS_REPAIR_BAD CS_CANON_F=$f CS_CANON_O=$orig FCMD=$fcmd FR=$f OCMD=$ocmd OR=$orig MODE=1 UIN=$work/u.in \
    LC_ALL=C "$CS_AWK" -v BINMODE=3 "$CS_REPAIR_AWK" </dev/null)
  : >>"$work/u.in"
  cs_repair_compact "$kind" <"$work/u.in" >"$work/u.out"
  # Pass 2 streams straight through the path transforms into OUT, counting lines/CRs on the way: the
  # big output is written once and never read back (first reads of fresh files are slow, SPEC R2).
  {
    BAD=$CS_REPAIR_BAD CS_CANON_F=$f CS_CANON_O=$orig FCMD=$fcmd FR=$f OCMD=$ocmd OR=$orig MODE=2 UOUT=$work/u.out CNT=$work/cnt \
      LC_ALL=C "$CS_AWK" -v BINMODE=3 "$CS_REPAIR_AWK" </dev/null |
      if [[ -n $arows ]]; then cs_transform canon "$arows" | cs_transform local "$lrows"; else cat; fi |
      LC_ALL=C "$CS_AWK" -v BINMODE=3 -v cnt="$work/outcnt" '{ print; n++; if (index($0, "\r")) c++ } END { print n + 0, c + 0 > cnt }'
  } >"$out"
  cnt=$(<"$work/outcnt")
  rm -rf -- "$work"
  printf '%s %s %s\n' "$stats" "$kind" "$cnt"
}

# cs_repair_orig_of REL: the same relative path inside a junk dir whose name starts with the slug ("" if none).
cs_repair_orig_of() {
  local rel=$1 slug=${1%%/*} p j
  p="$(cs_claude_dir)/projects"
  while IFS= read -r j; do
    [[ ${j,,} == "${slug,,}".* || ${j,,} == "${slug,,}"-bak* ]] || continue
    [[ -f $p/$j/${rel#*/} ]] && {
      printf '%s\n' "$p/$j/${rel#*/}"
      return 0
    }
  done < <(cs_claude_junk_dirs)
  printf '\n'
}

# cs_repair_token_files LIVE_SET: "rel" of every transcript whose cwd is still an unresolved path token ({P:id}, {R:id},
# {MEM:id}) of a project that is mapped here. Such a file was installed from another machine whose project_id for the
# folder differed from ours (the engine now refuses that), so the token never became the folder. Only a cwd field counts:
# chat text that merely mentions a token is left alone. LIVE_SET is " sid sid " (open sessions are skipped).
cs_repair_token_files() {
  local live=$1 rel size f id ok
  while IFS=$'\t' read -r rel size; do
    [[ -n $rel ]] || continue
    f="$(cs_claude_dir)/projects/$rel"
    grep -q -E '"(cwd|relocatedCwd)": ?"\{(P|R|MEM):[A-Za-z0-9_-]+\}' "$f" || continue
    [[ $live == *" $(cs_repair_sid_of "$rel") "* ]] && continue
    ok=0
    while IFS= read -r id; do
      cs_tsv_rows projects | cut -f1,6 | grep -qx -- "$id"$'\t'1 && ok=1
    done < <(grep -o -E '"(cwd|relocatedCwd)": ?"\{(P|R|MEM):[A-Za-z0-9_-]+\}' "$f" | sed -E 's/.*\{(P|R|MEM):([A-Za-z0-9_-]+)\}$/\2/' | sort -u)
    ((ok)) && printf '%s\n' "$rel"
  done < <(cs_repair_files)
  return 0
}

# cs_repair_tokens DRY BACKUP_DIR REL...: put the folder back in place of the tokens (transform "local" with this machine's
# project rows), keeping the mtime and a backup. Prints the number of files changed; a failed line/CR check keeps the file.
cs_repair_tokens() {
  local dry=$1 bdir=$2 rows rel f out n=0 l1 l2 c1 c2 jr=''
  shift 2
  rows=$(cs_project_rows)
  for rel in "$@"; do
    f="$(cs_claude_dir)/projects/$rel"
    out="$f.csync-tmp"
    jr=''
    ((dry)) || jr=$(cs_journal_begin repair "$(cs_jq -nc --arg f "$f" --arg t "$out" '{file: $f, tmp: [$t]}')")
    cs_transform_file local "$rows" "$f" "$out" || {
      rm -f -- "$out"
      [[ -n $jr ]] && cs_journal_end "$jr"
      continue
    }
    l1=$(wc -l <"$f")
    l2=$(wc -l <"$out")
    c1=$(tr -cd '\r' <"$f" | wc -c)
    c2=$(tr -cd '\r' <"$out" | wc -c)
    if ((l1 != l2 || c1 != c2)) || cmp -s -- "$f" "$out"; then
      rm -f -- "$out"
      [[ -n $jr ]] && cs_journal_end "$jr"
      continue
    fi
    if ((dry)); then
      rm -f -- "$out"
    else
      mkdir -p -- "$bdir/projects/${rel%/*}"
      cp -p -- "$f" "$bdir/projects/$rel"
      touch -r "$f" -- "$out"
      mv -f -- "$out" "$f"
      cs_journal_end "$jr"
      cs_log info "repair: replaced unresolved path tokens in $rel"
    fi
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# cs_repair [--dry-run] [--yes] [--project NAME]: the command (SPEC §19).
cs_repair() {
  local dry=0 yes=0 project='' a
  while (($#)); do
    case $1 in
      --dry-run) dry=1 ;;
      --yes) yes=1 ;;
      --project)
        project=${2:-}
        shift
        ;;
      *) cs_die_t "$CS_EXIT_USAGE" cli.unknown_command "repair $1" ;;
    esac
    shift
  done
  cs_store_init
  # A previous run killed half way left only its temp file (the target is replaced by one rename at the
  # very end): drop those leftovers.
  local j
  while IFS= read -r j; do
    [[ -n $j && $(cs_journal_op "$j") == repair ]] && cs_journal_abandon "$j"
  done < <(cs_journal_pending)
  local p ts bdir
  p="$(cs_claude_dir)/projects"
  TZ=UTC printf -v ts '%(%Y%m%dT%H%M%SZ)T' -1
  bdir="$CS_HOME/backups/repair-$ts"
  local -a slugs=()
  if [[ -n $project ]]; then
    local id root
    id=$(cs_project_find "$project") || cs_die_t "$CS_EXIT_ERROR" projects.unknown "$project"
    while IFS=$'\t' read -r pid root _; do
      [[ $pid == "$id" ]] && slugs+=("$(cs_claude_slug "$root")")
    done < <(cs_tsv_rows projects)
  fi

  cs_heading repair.h_scan
  local live
  live=" $(cs_claude_live_sessions | cut -f1 | tr '\n' ' ') "
  local rel size sid f needs crs sp fo
  local -a todo=() skipped_live=()
  local -A foreign=()
  while IFS=$'\t' read -r rel size; do
    [[ -n $rel ]] || continue
    f="$p/$rel"
    read -r crs sp fo < <(cs_repair_needs "$f")
    ((crs || sp || fo)) || continue
    sid=$(cs_repair_sid_of "$rel")
    if [[ $live == *" $sid "* ]]; then
      skipped_live+=("$rel")
      continue
    fi
    todo+=("$rel")
    if ((fo)); then
      while IFS= read -r a; do foreign[$a]=1; done < <(cs_repair_foreign_cwds "$f")
    fi
  done < <(cs_repair_files "${slugs[@]}")

  # Foreign roots -> this machine's project roots (user confirms).
  local arows='' lrows='' line id froot lroot
  local -A seen=()
  local -a unmapped_foreign=()
  for a in "${!foreign[@]}"; do
    if line=$(cs_repair_alias_for "$a"); then
      IFS=$'\t' read -r id froot lroot <<<"$line"
      [[ -n ${seen[$id:$froot]:-} ]] && continue
      seen[$id:$froot]=1
      cs_say repair.alias "$froot" "$lroot"
      arows+=$(cs_transform_row P "{P:$id}" "$froot")$'\n'$(cs_transform_row R "{R:$id}" "$froot")$'\n'
    else
      unmapped_foreign+=("$a")
    fi
  done
  if ((${#unmapped_foreign[@]})); then
    printf '%s\n' "${unmapped_foreign[@]}" | sort -u | head -n 5 | while IFS= read -r a; do cs_say repair.foreign_unmapped "$a"; done
  fi
  if [[ -n $arows ]]; then
    lrows=$(cs_project_rows)
    if ((!dry && !yes)) && ! cs_confirm repair.ask_alias y; then
      arows=''
    fi
  fi

  local junk tokfiles
  junk=$(cs_claude_junk_dirs)
  tokfiles=$(cs_repair_token_files "$live")
  ((${#todo[@]} || ${#skipped_live[@]})) || [[ -n $junk || -n $tokfiles ]] || {
    cs_say repair.nothing
    return 0
  }

  cs_heading repair.h_files
  local orig out res lines from_o recomp kept bad kind olines ocrs total_changed=0 total_lines=0 total_bad=0 failed=0
  for rel in "${todo[@]}"; do
    f="$p/$rel"
    orig=$(cs_repair_orig_of "$rel")
    if ((dry)); then
      out=$(mktemp -p "$CS_HOME/staging" dry.XXXXXX)
    else
      out="$f.csync-tmp"
    fi
    local jr=''
    ((dry)) || jr=$(cs_journal_begin repair "$(cs_jq -nc --arg f "$f" --arg t "$out" '{file: $f, tmp: [$t]}')")
    res=$(cs_repair_one "$f" "$orig" "$arows" "$lrows" "$out")
    read -r lines from_o recomp kept bad kind olines ocrs <<<"$res"
    printf '  %s\n    ' "$rel"
    cs_say repair.file_stats "$lines" "$from_o" "$recomp" "$kind" "$kept" "$bad"
    if ((olines != lines || ocrs != 0)); then
      cs_say repair.verify_failed "$rel" "$lines" "$olines" "$ocrs"
      rm -f -- "$out"
      [[ -n $jr ]] && cs_journal_end "$jr"
      failed=$((failed + 1))
      continue
    fi
    total_changed=$((total_changed + 1))
    total_lines=$((total_lines + lines))
    total_bad=$((total_bad + bad))
    if ((dry)); then
      rm -f -- "$out"
    else
      mkdir -p -- "$bdir/projects/${rel%/*}"
      cp -p -- "$f" "$bdir/projects/$rel"
      touch -r "$f" -- "$out"
      mv -f -- "$out" "$f"
      cs_journal_end "$jr"
      cs_log info "repair: rewrote $rel ($lines lines, $from_o from original, $recomp re-serialized with $kind, $bad unparsable)"
    fi
  done
  for rel in "${skipped_live[@]}"; do cs_say repair.skipped_live "$rel"; done

  if [[ -n $tokfiles ]]; then
    local -a tf=()
    mapfile -t tf <<<"$tokfiles"
    cs_heading repair.h_tokens
    local tn
    tn=$(cs_repair_tokens "$dry" "$bdir" "${tf[@]}")
    if ((dry)); then cs_say repair.tokens_would "$tn" "${#tf[@]}"; else cs_say repair.tokens_fixed "$tn" "${#tf[@]}"; fi
  fi

  if [[ -n $junk ]]; then
    cs_heading repair.h_junk
    while IFS= read -r a; do
      if ((dry)); then
        cs_say repair.junk_would_move "$a" "$bdir/junk/$a"
      elif ((yes)) || cs_confirm repair.ask_junk y "$a"; then
        mkdir -p -- "$bdir/junk"
        mv -- "$p/$a" "$bdir/junk/$a"
        cs_say repair.junk_moved "$a" "$bdir/junk/$a"
        cs_log info "repair: moved projects/$a to $bdir/junk"
      fi
    done <<<"$junk"
  fi

  printf '\n'
  if ((dry)); then
    cs_say repair.summary_dry "$total_changed" "$total_lines" "$total_bad" "$failed"
  else
    cs_say repair.summary "$total_changed" "$total_lines" "$total_bad" "$failed" "$bdir"
  fi
  if ((!dry && failed == 0)); then
    # Sessions that setup had blocked until they were repaired are free again.
    local rel2 sid2
    for rel2 in "${todo[@]}"; do
      sid2=$(cs_repair_sid_of "$rel2")
      if [[ $(cs_tsv_field sessions status "$sid2" 2>/dev/null) == needs_repair ]]; then cs_tsv_delete sessions "$sid2"; fi
    done
  fi
  ((failed == 0))
}
