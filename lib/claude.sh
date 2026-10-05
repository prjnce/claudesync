# shellcheck shell=bash
# claude: Claude Code config dir, project/session scan, launch cwd, running-session registry, retention,
# settings.json edits, never-sync filter (SPEC §4). Requires lib/core.sh and lib/platform.sh.
# Transcripts are only ever READ here; jq output is stripped of CR (native jq on Windows writes CRLF).

[[ -n ${CS_CLAUDE_LOADED:-} ]] && return 0
CS_CLAUDE_LOADED=1

# cs_claude_dir: Claude Code's config dir as Claude itself resolves it:
#   CS_CLAUDE_DIR (claude-sync override) > CLAUDE_CONFIG_DIR > <homedir>/.claude (Windows: %USERPROFILE%).
cs_claude_dir() {
  local d
  if [[ -n ${CS_CLAUDE_DIR:-} ]]; then
    d=$CS_CLAUDE_DIR
  elif [[ -n ${CLAUDE_CONFIG_DIR+set} ]]; then
    [[ -n $CLAUDE_CONFIG_DIR ]] || cs_die_t "$CS_EXIT_ERROR" claude.config_dir_empty
    d=$CLAUDE_CONFIG_DIR
  elif [[ $CS_OS == windows && -n ${USERPROFILE:-} ]]; then
    d="$USERPROFILE\\.claude"
  else
    d="$HOME/.claude"
  fi
  [[ $CS_OS == windows ]] && d=$(cs_win_to_posix "$d")
  printf '%s\n' "$d"
}

# cs_claude_project_dir_name: CLAUDE_CODE_PROJECT_DIR_NAME when Claude honours it (only together with
# CLAUDE_CONFIG_DIR, /^[A-Za-z0-9_-]{1,64}$/, not a Windows device name); empty otherwise.
cs_claude_project_dir_name() {
  local n=${CLAUDE_CODE_PROJECT_DIR_NAME:-}
  [[ -n ${CLAUDE_CONFIG_DIR+set} && $n =~ ^[A-Za-z0-9_-]{1,64}$ ]] || return 0
  local lower=${n,,}
  [[ $lower =~ ^(con|prn|aux|nul|com[0-9]|lpt[0-9])$ ]] && return 0
  printf '%s\n' "$n"
}

# cs_claude_slug PATH: the projects/ subdirectory Claude uses for PATH on this machine.
cs_claude_slug() {
  local o
  o=$(cs_claude_project_dir_name)
  if [[ -n $o ]]; then printf '%s\n' "$o"; else cc_slug "$1"; fi
}

# cs_claude_scan: one find pass over projects/*/ -> "slug<TAB>sid<TAB>size<TAB>mtime(s)" per transcript.
cs_claude_scan() {
  local p
  p="$(cs_claude_dir)/projects"
  [[ -d $p ]] || return 0
  find "$p" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -printf '%h\t%f\t%s\t%Ts\n' |
    "$CS_AWK" -F'\t' -v OFS='\t' '{ n = split($1, a, "/"); sub(/\.jsonl$/, "", $2); print a[n], $2, $3, $4 }'
}

# cs_claude_junk_dirs: entries of projects/ whose name can never be a slug (slugs never contain "."),
# e.g. "D--Projects-TransFlow.bak-20260925-170208". They hijack `claude --resume <id>`.
cs_claude_junk_dirs() {
  local p d
  p="$(cs_claude_dir)/projects"
  [[ -d $p ]] || return 0
  for d in "$p"/*/; do
    [[ -d $d ]] || continue
    d=${d%/}
    d=${d##*/}
    [[ $d =~ ^[A-Za-z0-9_-]+$ ]] || printf '%s\n' "$d"
  done
}

# cs_claude_dup_ids [SCAN_FILE]: session ids present in more than one projects/ dir -> "sid<TAB>slug,slug".
cs_claude_dup_ids() {
  local src=${1:-}
  if [[ -z $src ]]; then
    cs_claude_scan | cs_claude_dup_ids /dev/stdin
    return
  fi
  "$CS_AWK" -F'\t' '{ n[$2]++; d[$2] = (d[$2] == "" ? $1 : d[$2] "," $1) } END { for (s in n) if (n[s] > 1) print s "\t" d[s] }' "$src" | sort
}

# cs_launch_cwd TRANSCRIPT: relocatedCwd of the last compact "type":"relocated" line, else the top-level
# .cwd of the first line that parses and has one (whole file, not just 64 KB; nested cwd ignored).
cs_launch_cwd() {
  local f=$1 rel cwd
  rel=$({ grep -a -F '"type":"relocated"' -- "$f" || true; } | tr -d '\r' |
    jq -R -r 'fromjson? | objects | select(.type == "relocated") | .relocatedCwd // empty | strings' | tr -d '\r')
  if [[ -n $rel ]]; then
    printf '%s\n' "${rel##*$'\n'}"
    return 0
  fi
  # jq 1.6 (Git for Windows) lets `fromjson?` swallow the break of first(), so first() never stops:
  # instead awk hands jq at most 50 candidate lines (and exits early on big files), then take line 1.
  cwd=$(LC_ALL=C "$CS_AWK" -v BINMODE=3 'index($0, "\"cwd\"") { sub(/\r$/, ""); print; if (++n >= 50) exit }' "$f" |
    jq -R -r 'fromjson? | objects | .cwd // empty | strings' 2>/dev/null | tr -d '\r') || true
  if [[ -z $cwd ]]; then
    # Fewer than one parsable candidate in the first 50: scan the whole file.
    cwd=$(tr -d '\r' <"$f" | jq -R -r 'fromjson? | objects | .cwd // empty | strings' 2>/dev/null | tr -d '\r') || true
  fi
  [[ -n $cwd ]] || return 1
  printf '%s\n' "${cwd%%$'\n'*}"
}

# cs_claude_pid_domain: the pidDomain Claude Code writes on this machine.
cs_claude_pid_domain() {
  if [[ $CS_OS == windows ]]; then
    local h=${COMPUTERNAME:-$(hostname)}
    printf 'win32:%s\n' "${h,,}"
  else
    local mid ns
    mid=$(tr -d '\n' </etc/machine-id 2>/dev/null) || mid=
    ns=$(readlink /proc/self/ns/pid 2>/dev/null) || ns=
    printf 'linux:%s:%s\n' "$mid" "$ns"
  fi
}

# cs_claude_registry: records in sessions/*.json -> "pid sessionId procStart pidDomain status cwd" joined by \x1f
# (not tab: `read` merges runs of whitespace IFS, shifting every column after an empty field).
# Unreadable or half-written records are skipped.
cs_claude_registry() {
  local d f
  d="$(cs_claude_dir)/sessions"
  for f in "$d"/*.json; do
    [[ -f $f ]] || continue
    jq -r '[(.pid // "" | tostring), (.sessionId // ""), (.procStart // "" | tostring), (.pidDomain // ""), (.status // ""), (.cwd // "")] | join("\u001f")' \
      "$f" 2>/dev/null | tr -d '\r' || true
  done
}

# cs_proc_start_same RECORDED NOW: Claude's own rule — equal, or different units (.NET ticks > 3e17 vs
# FILETIME) which it treats as the same process.
cs_proc_start_same() {
  [[ $1 == "$2" ]] && return 0
  [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] || return 1
  local a b
  a=$(("${#1}" > 17 && 10#$1 > 300000000000000000 ? 1 : 0))
  b=$(("${#2}" > 17 && 10#$2 > 300000000000000000 ? 1 : 0))
  ((a != b))
}

# cs_claude_live_sessions: sessions open in a Claude process on THIS machine -> "sid<TAB>pid<TAB>status<TAB>cwd".
# A record counts only if its pidDomain is ours (or absent, older versions), the pid is alive and procStart
# still matches; records left behind by a crash are ignored. One ps + one start-id query in total.
cs_claude_live_sessions() {
  local reg dom live starts pid sid ps0 pdom status cwd now
  reg=$(cs_claude_registry)
  [[ -n $reg ]] || return 0
  dom=$(cs_claude_pid_domain)
  live=" $(cs_live_pids | tr '\n' ' ') "
  local -a cand=()
  while IFS=$'\x1f' read -r pid sid ps0 pdom status cwd; do
    [[ $pid =~ ^[0-9]+$ && -n $sid ]] || continue
    [[ -z $pdom || $pdom == "$dom" ]] || continue
    [[ $live == *" $pid "* ]] && cand+=("$pid")
  done <<<"$reg"
  ((${#cand[@]})) || return 0
  starts=$(cs_proc_start_ids "${cand[@]}")
  while IFS=$'\x1f' read -r pid sid ps0 pdom status cwd; do
    [[ $pid =~ ^[0-9]+$ && -n $sid ]] || continue
    [[ -z $pdom || $pdom == "$dom" ]] || continue
    now=$(printf '%s\n' "$starts" | "$CS_AWK" -F'\t' -v p="$pid" '$1 == p { print $2; exit }')
    [[ -n $now ]] || continue
    [[ -z $ps0 ]] || cs_proc_start_same "$ps0" "$now" || continue
    printf '%s\t%s\t%s\t%s\n' "$sid" "$pid" "$status" "$cwd"
  done <<<"$reg"
}

# cs_claude_retention_days [PROJECT_ROOT]: effective cleanupPeriodDays (project local > project > user;
# default 30). 0 means Claude never sweeps.
cs_claude_retention_days() {
  local root=${1:-} f v days=30
  local -a files=("$(cs_claude_dir)/settings.json")
  if [[ -n $root ]]; then
    files+=("$root/.claude/settings.json" "$root/.claude/settings.local.json")
  fi
  for f in "${files[@]}"; do
    [[ -f $f ]] || continue
    v=$(jq -r '.cleanupPeriodDays // empty' "$f" 2>/dev/null | tr -d '\r') || v=
    [[ $v =~ ^[0-9]+$ ]] && days=$v
  done
  printf '%s\n' "$days"
}

# cs_claude_settings_set KEY JSON_VALUE: set a top-level key in the user settings.json, after a timestamped
# backup in ~/.claude-sync/backups. Written via jq then CR-stripped, atomically. Settings only, never transcripts.
cs_claude_settings_set() {
  local key=$1 val=$2 f ts
  f="$(cs_claude_dir)/settings.json"
  printf '%s' "$val" | jq -e . >/dev/null 2>&1 || cs_die_t "$CS_EXIT_ERROR" settings.not_json "$key"
  mkdir -p -- "${f%/*}" "$CS_HOME/backups"
  if [[ -f $f ]]; then
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || cs_die_t "$CS_EXIT_ERROR" settings.not_object "$f"
    TZ=UTC printf -v ts '%(%Y%m%dT%H%M%SZ)T' -1
    cp -p -- "$f" "$CS_HOME/backups/settings.json.$ts.$$"
  else
    printf '{}\n' >"$f"
  fi
  cs_write_atomic "$f" cs_claude_settings_filter "$f" "$key" "$val"
}

cs_claude_settings_filter() {
  jq --arg k "$2" --argjson v "$3" '.[$k] = $v' "$1" | tr -d '\r'
}

# cs_claude_never_sync RELPATH: rc 0 if RELPATH (relative to the Claude config dir) must never be synced
# (SPEC §4.3). Checked by tests; every uploader must call it.
cs_claude_never_sync() {
  case $1 in
    sessions/* | session-env/* | shell-snapshots/* | ide/* | cache/* | state/* | backups/*) return 0 ;;
    .credentials.json | .claude.json | .config.json | .last-cleanup) return 0 ;;
    projects/*/.session-aliases | projects/*/memory/team/* | projects/*/memory/.memory-sync* | memory/personal/*) return 0 ;;
    *.ccr-tip.json | *.precompact.json | *.compact.tmp.* | *.superseded-* | *.orphaned-* | *.csync-tmp*) return 0 ;;
    */../* | ../* | /*) return 0 ;;
  esac
  return 1
}

# cs_claude_projects_report: "slug<TAB>sessions<TAB>bytes<TAB>launch cwd of the newest session".
cs_claude_projects_report() {
  local scan slug n bytes sid cwd dir
  scan=$(cs_claude_scan)
  [[ -n $scan ]] || return 0
  dir="$(cs_claude_dir)/projects"
  while IFS=$'\t' read -r slug n bytes sid; do
    cwd=$(cs_launch_cwd "$dir/$slug/$sid.jsonl") || cwd="?"
    printf '%s\t%s\t%s\t%s\n' "$slug" "$n" "$bytes" "$cwd"
  done < <(printf '%s\n' "$scan" | "$CS_AWK" -F'\t' -v OFS='\t' '
    { n[$1]++; b[$1] += $3; if ($4 >= t[$1]) { t[$1] = $4; s[$1] = $2 } }
    END { for (d in n) print d, n[d], b[d], s[d] }' | sort)
}
