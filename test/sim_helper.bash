# shellcheck shell=bash
# Simulated machines for engine tests (SPEC §23.2). Every machine has its own ~/.claude-sync and Claude
# config dir under $SIM/<name>/ and they share one localfs "Drive" at $SIM/drive. A Windows-style machine
# is simulated with string roots (D:\Projects\X) and CS_SEP=w: path translation works on strings, so it
# runs on any host OS. Each engine run is a separate `claude-sync run` process.

# sim_init: create the shared Drive and its root folder.
sim_init() {
  SIM="$BATS_TEST_TMPDIR/sim"
  mkdir -p "$SIM/drive"
  SIM_ROOT_ID=
}

# sim_env NAME: the environment of machine NAME, as "VAR=value" words for `env`.
sim_env() {
  local n=$1
  printf '%s\n' "CLAUDE_SYNC_HOME=$SIM/$n/home/.claude-sync" "CS_CLAUDE_DIR=$SIM/$n/claude" \
    "CS_DRIVE_BACKEND=localfs" "CS_LFS_ROOT=$SIM/drive" "CS_SEP=$(cat "$SIM/$n/sep")" "CLAUDE_SYNC_LANG=en" "CS_STABLE_WAIT=0.2" \
    "CS_LFS_USER=Sim <sim@test>"
}

# sim_exec NAME CODE [ARGS...]: run bash CODE with the libraries loaded, as machine NAME; ARGS are $1...
sim_exec() {
  local n=$1 code=$2
  shift 2
  local -a e
  mapfile -t e < <(sim_env "$n")
  env "${e[@]}" CS_SIM_CODE="$code" bash -c '
    set -uo pipefail
    source "$CS_ROOT/lib/core.sh"
    for m in platform version manifest store claude transform projects drive root status engine bundle memory gc; do source "$CS_ROOT/lib/$m.sh"; done
    cs_bootstrap
    cs_store_init
    eval "$CS_SIM_CODE"' _ "$@"
}

# sim_run NAME [ARGS...]: claude-sync run as machine NAME (output on stdout, rc preserved).
sim_run() {
  local n=$1
  shift
  local -a e
  mapfile -t e < <(sim_env "$n")
  env "${e[@]}" bash "$CS_ROOT/bin/claude-sync" run "$@"
}

# sim_machine NAME STYLE ROOT: a machine (STYLE w = Windows-like, p = POSIX) with project p1 at ROOT.
# The first machine creates the Drive root; the others join it.
sim_machine() {
  local n=$1 style=$2 root=$3 mem
  mkdir -p "$SIM/$n/home/.claude-sync" "$SIM/$n/claude/projects"
  printf '%s\n' "$style" >"$SIM/$n/sep"
  if [[ $style == w ]]; then
    # shellcheck disable=SC1003 # literal Windows path backslashes
    mem='C:\Users\'"$n"'\.claude\projects\'"$(sim_exec "$n" 'cc_slug "$1"' "$root")"'\memory'
  else
    mkdir -p "$root"
    mem="$SIM/$n/claude/projects/$(sim_exec "$n" 'cc_slug "$1"' "$root")/memory"
  fi
  sim_exec "$n" '
    cs_config_set machine_id "$3-0000-4000-8000-000000000000"
    cs_config_set machine_name "$3"
    if [[ -z $4 ]]; then
      IFS=$'"'"'\t'"'"' read -r rid mid < <(cs_root_create "Claude Sync")
    else
      IFS=$'"'"'\t'"'"' read -r rid mid _ _ < <(cs_root_candidates | head -n 1)
    fi
    cs_root_use "$rid" "$mid"
    cs_machine_area_ensure "$rid" >/dev/null
    cs_tsv_upsert projects p1 "$1" X "$1" "$2" 1 ""
    printf "%s\n" "$rid"' "$root" "$mem" "$n" "$SIM_ROOT_ID" >"$SIM/$n/rootid"
  SIM_ROOT_ID=$(cat "$SIM/$n/rootid")
}

# sim_write NAME SLUG SID LINE...: append transcript lines on machine NAME.
sim_write() {
  local n=$1 slug=$2 sid=$3
  shift 3
  mkdir -p "$SIM/$n/claude/projects/$slug"
  printf '%s\n' "$@" >>"$SIM/$n/claude/projects/$slug/$sid.jsonl"
}

# sim_find NAME SID: the transcript file of SID on machine NAME (one path per copy).
sim_find() {
  local f
  for f in "$SIM/$1"/claude/projects/*/"$2".jsonl; do [[ -f $f ]] && printf '%s\n' "$f"; done
  return 0
}

# sim_canon NAME FILE: FILE canonicalized with machine NAME's rows (to compare content across machines).
sim_canon() {
  sim_exec "$1" 'cs_transform canon "$(cs_project_rows)" <"$1"' "$2"
}

# sim_cli NAME ARGS...: claude-sync ARGS as machine NAME.
sim_cli() {
  local n=$1
  shift
  local -a e
  mapfile -t e < <(sim_env "$n")
  env "${e[@]}" bash "$CS_ROOT/bin/claude-sync" "$@"
}

native_pid() { if cs_is_windows; then cat "/proc/$1/winpid"; else printf '%s\n' "$1"; fi; }

# sim_open NAME SID: Claude "opens" session SID on machine NAME (a live process and its registry record).
sim_open() {
  local pid
  sleep 600 3>&- &
  SIM_SLEEP_PIDS+=("$!")
  pid=$(native_pid "$!")
  mkdir -p "$SIM/$1/claude/sessions"
  printf '{"pid":%s,"sessionId":"%s","status":"busy","cwd":"/x"}' "$pid" "$2" >"$SIM/$1/claude/sessions/$pid.json"
  printf '%s
' "$pid" >"$SIM/$1/open.$2"
}

# sim_close NAME SID: the session is closed (process gone, record removed).
sim_close() {
  local pid
  pid=$(cat "$SIM/$1/open.$2")
  rm -f "$SIM/$1/claude/sessions/$pid.json" "$SIM/$1/open.$2"
  kill "${SIM_SLEEP_PIDS[@]}" 2>/dev/null || true
  SIM_SLEEP_PIDS=()
}
