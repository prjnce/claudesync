# shellcheck shell=bash
# gc: garbage collection in our own machine area and the `machines` command (SPEC §14.2, §20).
# Nothing here ever deletes permanently: objects only go to the Drive trash.
# Requires core, platform, version, manifest, store, claude, transform, projects, drive, root, status, engine.

[[ -n ${CS_GC_LOADED:-} ]] && return 0
CS_GC_LOADED=1

CS_GC_MIN_AGE=${CS_GC_MIN_AGE:-86400}   # an unreferenced object must be this old (a reader may be mid-download)
CS_GC_INTERVAL=${CS_GC_INTERVAL:-86400} # one listing of the area per day

# cs_gc_referenced: every object id that any known manifest (ours and the cached ones) points at.
cs_gc_referenced() {
  local f
  for f in "$CS_HOME/state/manifest.json" "$CS_HOME"/state/remote/*.json; do
    [[ -f $f ]] || continue
    cs_jq -r '[.. | objects | .id? | strings | select(length > 0)] | unique[]' "$f"
  done | sort -u
}

# cs_gc_run: trash the objects of our area that no manifest references and that are older than CS_GC_MIN_AGE.
# Skipped when a remote manifest could not be read this cycle (CS_RUN_REMOTE_FAIL) or ran less than a day ago.
cs_gc_run() {
  local last now ref m id created kind age n=0 server
  [[ ${CS_RUN_REMOTE_FAIL:-0} == 0 ]] || return 0
  last=$(cs_drive_state_get gc_last)
  now=$(date +%s)
  [[ $last =~ ^[0-9]+$ ]] && ((now - last < CS_GC_INTERVAL)) && return 0
  server=$(drv_server_time) || return 0
  server=$(date -u -d "$server" +%s 2>/dev/null) || return 0
  ref=$(cs_gc_referenced)
  while IFS= read -r m; do
    [[ -n $m ]] || continue
    id=$(cs_jq -r .id <<<"$m")
    kind=$(cs_jq -r '.appProperties.csKind // empty' <<<"$m")
    [[ $kind == manifest || $kind == live ]] && continue
    grep -qxF -- "$id" <<<"$ref" && continue
    created=$(date -u -d "$(cs_jq -r .createdTime <<<"$m")" +%s 2>/dev/null) || continue
    age=$((server - created))
    ((age >= CS_GC_MIN_AGE)) || continue
    drv_trash "$id" >/dev/null || continue
    n=$((n + 1))
  done < <(drv_list_children "$CS_MY_AREA")
  cs_drive_state_set gc_last "$now"
  ((n)) && cs_log info "gc: $n orphaned object(s) moved to the trash"
  return 0
}

# --- machines ------------------------------------------------------------------------------------------------

# cs_machines_table: "machine_id<TAB>name<TAB>os<TAB>updated<TAB>sessions" for every machine we know of.
cs_machines_table() {
  local f
  f="$CS_HOME/state/manifest.json"
  [[ -f $f ]] && cs_jq -r '[.machine_id, .name, .os, .updated, (.sessions | length | tostring)] | join("\t")' "$f"
  for f in "$CS_HOME"/state/remote/*.json; do
    [[ -f $f ]] && cs_jq -r '[.machine_id, .name, .os, .updated, (.sessions | length | tostring)] | join("\t")' "$f"
  done
  return 0
}

cs_machines() {
  local sub=${1:-list}
  shift || true
  case $sub in
    list)
      cs_eng_load || return
      cs_eng_fetch_remotes
      cs_say machines.header
      local mid name os upd n me
      me=$(cs_config_get machine_id "")
      while IFS=$'\t' read -r mid name os upd n; do
        [[ -n $mid ]] || continue
        cs_say machines.row "$name" "$os" "${upd:--}" "$n" "$([[ $mid == "$me" ]] && cs_t machines.this || true)"
      done < <(cs_machines_table)
      ;;
    forget) cs_machines_forget "$@" ;;
    *) cs_die_t "$CS_EXIT_USAGE" cli.unknown_command "machines $sub" ;;
  esac
}

# cs_machines_forget NAME [--yes]
cs_machines_forget() {
  local name=${1:-} yes=0 mid='' f mf fid sid e head ok o unsafe=0 ans me
  [[ ${2:-} == --yes ]] && yes=1
  [[ -n $name ]] || cs_die_t "$CS_EXIT_USAGE" machines.usage
  exec 9>>"$CS_HOME/sync.lock"
  cs_lock_fd 9 0 || {
    cs_say engine.busy
    return "$CS_EXIT_BUSY"
  }
  cs_eng_load || return
  cs_eng_fetch_remotes
  me=$(cs_config_get machine_id "")
  for f in "$CS_HOME"/state/remote/*.json; do
    [[ -f $f ]] || continue
    [[ $(cs_jq -r .name "$f") == "$name" || $(basename -- "$f" .json) == "$name" ]] && mid=$(basename -- "$f" .json)
  done
  [[ -n $mid ]] || cs_die_t "$CS_EXIT_ERROR" machines.not_found "$name"
  [[ $mid != "$me" ]] || cs_die_t "$CS_EXIT_ERROR" machines.is_self
  f="$CS_HOME/state/remote/$mid.json"
  # Which versions exist nowhere else?
  local -a lonely=()
  while IFS= read -r sid; do
    [[ -n $sid ]] || continue
    e=$(cs_jq -c --arg s "$sid" '.sessions[$s]' "$f")
    head=$(cs_jq -r .head <<<"$e")
    ok=0
    for o in "$CS_HOME/state/manifest.json" "$CS_HOME"/state/remote/*.json; do
      [[ -f $o && $o != "$f" ]] || continue
      local e2
      e2=$(cs_jq -c --arg s "$sid" '.sessions[$s] // empty' "$o")
      [[ -n $e2 ]] || continue
      cs_entry_is_ancestor "$e2" "$head" && {
        ok=1
        break
      }
    done
    ((ok)) || lonely+=("$sid")
  done < <(cs_jq -r '.sessions | keys[]' "$f")
  if ((!yes)); then
    cs_say machines.confirm "$name" "${#lonely[@]}"
    read -r ans || ans=n
    [[ $ans == y || $ans == Y ]] || return 1
  fi
  for sid in "${lonely[@]}"; do
    cs_gc_archive "$mid" "$sid" "$(cs_jq -c --arg s "$sid" '.sessions[$s]' "$f")" || cs_die_t "$CS_EXIT_ERROR" machines.archive_failed "$sid"
  done
  mf=$(cs_machines_folder "$CS_ROOT_ID") || return
  fid=$(drv_list_children "$mf" | cs_jq -r --arg m "$mid" 'select(.appProperties.csMachine == $m) | .id' | head -n 1)
  [[ -n $fid ]] && drv_trash "$fid" >/dev/null
  rm -f -- "$CS_HOME/state/remote/$mid".*
  cs_eng_publish_manifest || true
  cs_say machines.forgotten "$name" "${#lonely[@]}"
}

# cs_gc_archive MID SID ENTRY: copy every object of ENTRY (segments, files, subagent segments) into our area and
# keep the entry, with the new ids, in our manifest under archive[MID][SID], so GC never reclaims it.
cs_gc_archive() {
  local mid=$1 sid=$2 e=$3 tmp id sha kind path new_e k
  new_e=$e
  tmp="$CS_HOME/staging/archive.$$"
  while IFS=$'\t' read -r path id sha; do
    [[ -n $id ]] || continue
    drv_download "$id" "$tmp" || return
    k=$(drv_generate_ids 1) || return
    drv_upload "$CS_MY_AREA" "arch-$sid-${sha:0:16}" "$tmp" "{\"csKind\":\"archive\",\"csSha\":\"$sha\",\"csSid\":\"$sid\"}" "$k" >/dev/null || return
    new_e=$(cs_jq -c --argjson p "$path" --arg id "$k" --arg m "$CS_ME" 'setpath($p + ["id"]; $id) | setpath($p + ["m"]; $m)' <<<"$new_e")
  done < <(cs_jq -r '. as $r | [paths(type == "object" and has("id") and (.id | type == "string") and (.id | length > 0))] | .[] as $p | [($p | tojson), ($r | getpath($p).id), ($r | getpath($p).sha // "x0000000000000000")] | @tsv' <<<"$e")
  rm -f -- "$tmp"
  cs_eng_my_manifest_save "$(cs_jq -c --arg m "$mid" --arg s "$sid" --argjson e "$new_e" '.archive[$m][$s] = $e' <<<"$(cs_eng_my_manifest)")"
}
