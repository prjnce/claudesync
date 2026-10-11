# shellcheck shell=bash
# status: state/status.json (SPEC §21), the exit code of a run (§20), `status`, `logs` and log rotation.
# status.json is written in parts by whoever owns a field (engine: state/last_*; #19: behind, live_elsewhere;
# #20: conflicts; #31: waiting_map), always atomically through cs_status_patch.
# Requires core, version (cs_jq), store.

[[ -n ${CS_STATUS_LOADED:-} ]] && return 0
CS_STATUS_LOADED=1

CS_LOG_MAX_BYTES=${CS_LOG_MAX_BYTES:-5242880}
CS_LOG_KEEP=5

cs_status_file() { printf '%s\n' "$CS_HOME/state/status.json"; }

# cs_status_read: the status document (an empty skeleton when none was written yet).
cs_status_read() {
  local j
  j=$(cat -- "$(cs_status_file)" 2>/dev/null | tr -d '\r') || j=''
  [[ -n $j ]] || j='{}'
  cs_jq -c '{state: "OK", last_run: "", last_ok_pull: "", last_ok_push: "", boot_time: "",
             behind: {}, live_elsewhere: {}, conflicts: [], waiting_map: [], retention_skipped: 0} + .' <<<"$j"
}

# cs_status_patch FILTER [JQ_ARGS...]: apply a jq filter to the status document and write it atomically.
cs_status_patch() {
  local filter=$1 new
  shift
  new=$(cs_status_read | cs_jq -c "$@" "$filter") || return
  cs_write_atomic "$(cs_status_file)" printf '%s\n' "$new"
}

cs_status_behind_set() { # SID MACHINE LINES SINCE_ISO
  cs_status_patch '.behind[$s] = {machine: $m, lines: $l, since: (.behind[$s].since // $t)}' \
    --arg s "$1" --arg m "$2" --argjson l "$3" --arg t "$4"
}
cs_status_behind_clear() { cs_status_patch 'del(.behind[$s])' --arg s "$1"; }
cs_status_live_elsewhere_set() { cs_status_patch '.live_elsewhere = $o' --argjson o "$1"; } # {"sid": {"machine": "name"}}
cs_status_conflicts_set() { cs_status_patch '.conflicts = $a' --argjson a "$1"; }            # ["sid", ...]
cs_status_waiting_map_set() { cs_status_patch '.waiting_map = $a' --argjson a "$1"; }

# cs_status_exit STATE: the exit code that goes with a state.
cs_status_exit() {
  case $1 in
    OK) echo "$CS_EXIT_OK" ;;
    LOGIN_REQUIRED) echo "$CS_EXIT_LOGIN" ;;
    OFFLINE) echo "$CS_EXIT_OFFLINE" ;;
    NEEDS_REPAIR) echo "$CS_EXIT_REPAIR" ;;
    *) echo "$CS_EXIT_ERROR" ;; # ERROR, ROOT_MISSING
  esac
}

# cs_status_finish STATE PULL_OK PUSH_OK: write the end-of-run fields; the conflict list and the retention
# count come from the DB and state/retention_skipped. Prints nothing.
cs_status_finish() {
  local now conf n=0
  TZ=UTC printf -v now '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  # sessions that were forked (forks.tsv) or are still in conflict
  conf=$({ cs_tsv_rows sessions | "$CS_AWK" -F'\t' '$10 == "conflict" { print $1 }'; cs_tsv_rows forks | cut -f1; } | cs_jq -Rsc 'split("\n") | map(select(length > 0)) | unique')
  [[ -f $CS_HOME/state/retention_skipped ]] && n=$(grep -c . "$CS_HOME/state/retention_skipped" || true)
  cs_status_patch '.state = $st | .last_run = $t | .conflicts = $c | .retention_skipped = $n
    | (if $pull == "1" then .last_ok_pull = $t else . end) | (if $push == "1" then .last_ok_push = $t else . end)
    | (if $boot != "" then .boot_time = $boot else . end)' \
    --arg st "$1" --arg t "$now" --argjson c "${conf:-[]}" --argjson n "$n" --arg pull "$2" --arg push "$3" \
    --arg boot "$(cs_boot_time)"
}

# cs_boot_time: ISO time this machine booted, "" when unknown.
cs_boot_time() {
  local up
  [[ -r /proc/uptime ]] || return 0
  read -r up _ </proc/uptime
  up=${up%.*}
  [[ $up =~ ^[0-9]+$ ]] || return 0
  date -u -d "@$(($(date +%s) - up))" +%Y-%m-%dT%H:%M:%SZ
}

# cs_uptime_s: seconds since boot (a large number when unknown).
cs_uptime_s() {
  local up
  if [[ -r /proc/uptime ]]; then
    read -r up _ </proc/uptime
    echo "${up%.*}"
  else
    echo 999999
  fi
}

# --- log -----------------------------------------------------------------------------------------------------

# cs_log_rotate: logs/claude-sync.log -> .1 ... .4 once it is larger than CS_LOG_MAX_BYTES (5 files in all).
cs_log_rotate() {
  local f="$CS_HOME/logs/claude-sync.log" i
  [[ -f $f ]] || return 0
  (($(stat -c %s -- "$f") > CS_LOG_MAX_BYTES)) || return 0
  for ((i = CS_LOG_KEEP - 1; i >= 1; i--)); do
    [[ -f $f.$i ]] && mv -f -- "$f.$i" "$f.$((i + 1))"
  done
  mv -f -- "$f" "$f.1"
  rm -f -- "$f.$CS_LOG_KEEP"
}

# cs_logs [-f]: print the log (follow with -f).
cs_logs() {
  local f="$CS_HOME/logs/claude-sync.log"
  [[ -f $f ]] || return 0
  if [[ ${1:-} == -f ]]; then tail -n 50 -f -- "$f"; else cat -- "$f"; fi
}

# --- status command ---------------------------------------------------------------------------------------

# cs_status_show [--json]
cs_status_show() {
  local j
  j=$(cs_status_read)
  if [[ ${1:-} == --json ]]; then
    printf '%s\n' "$j"
    return 0
  fi
  cs_say status.state "$(cs_jq -r .state <<<"$j")"
  cs_say status.last_run "$(cs_jq -r '.last_run | if . == "" then "-" else . end' <<<"$j")" \
    "$(cs_jq -r '.last_ok_pull | if . == "" then "-" else . end' <<<"$j")" "$(cs_jq -r '.last_ok_push | if . == "" then "-" else . end' <<<"$j")"
  cs_say status.counts "$(cs_jq '.behind | length' <<<"$j")" "$(cs_jq '.live_elsewhere | length' <<<"$j")" \
    "$(cs_jq '.conflicts | length' <<<"$j")" "$(cs_jq '.waiting_map | length' <<<"$j")" "$(cs_jq .retention_skipped <<<"$j")"
}
