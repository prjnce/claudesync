# shellcheck shell=bash
# engine: one sync cycle (SPEC §8, §10, §12, §14). Ticket #17 scope: append-only publish and install of
# main transcripts between machines; rewrites, forks, initialisation without a base, open sessions and
# bundles are recognised and deferred (later tickets).
# Drive layout per machine area (machines/<machine_id>/, flat — fewer API calls than per-session folders):
#   manifest.json.gz                     appProperties csKind=manifest, csMachine=<id>
#   t-<sid>-<seq>-<sha16>.jsonl.gz       canonical transcript segment, csKind=seg, csSha, csSid
# Local state: state/sessions.tsv (DB row per session), state/entries/<sid>.json (entry of our base
# version), state/manifest.json (our manifest), state/remote/<mid>.json (others' manifests),
# cache/segs/<sha>.gz (downloaded segments).
# Requires core, platform, version, manifest, store, claude, transform, projects, drive, root.

[[ -n ${CS_ENGINE_LOADED:-} ]] && return 0
CS_ENGINE_LOADED=1

CS_SOFT_DEADLINE=${CS_SOFT_DEADLINE:-420} # SPEC §14: no new work after 7 minutes

# --- context ---------------------------------------------------------------------------------------------

cs_eng_load() {
  cs_store_init
  mkdir -p -- "$CS_HOME/state/entries" "$CS_HOME/cache/segs"
  CS_ME=$(cs_config_get machine_id "")
  CS_ROOT_ID=$(cs_config_get root_id "")
  [[ -n $CS_ME && -n $CS_ROOT_ID ]] || cs_die_t "$CS_EXIT_ERROR" engine.not_setup
  cs_owner_check || cs_die_t "$CS_EXIT_ERROR" setup.owner_conflict "$(cs_owner_file)" "$(tr -d '\r\n' <"$(cs_owner_file)")"
  CS_MY_AREA=$(cs_drive_state_get machine_folder_id)
  [[ -n $CS_MY_AREA ]] || CS_MY_AREA=$(cs_machine_area_ensure "$CS_ROOT_ID") || return
  CS_ROWS=$(cs_project_rows)
  CS_PDIR="$(cs_claude_dir)/projects"
  CS_RUN_START=$SECONDS
}

cs_eng_time_left() {
  ((SECONDS - CS_RUN_START < CS_SOFT_DEADLINE))
}

# --- our manifest ----------------------------------------------------------------------------------------

cs_eng_my_manifest() {
  local f="$CS_HOME/state/manifest.json"
  if [[ -f $f ]]; then
    cat -- "$f"
  else
    cs_manifest_new "$CS_ME" "$(cs_config_get machine_name "")" "$(cs_os_kind)" "${CS_CLAUDE_VERSION:-}" "$(cs_config_get interval 5)"
  fi
}

cs_eng_my_manifest_save() {
  cs_write_atomic "$CS_HOME/state/manifest.json" printf '%s\n' "$1"
}

# cs_eng_publish_manifest: upload our manifest when its content differs from the last SUCCESSFUL upload
# (F9: nothing is written while nothing changed; a failed upload is retried next cycle).
cs_eng_publish_manifest() {
  local j gz id rc=0 md5
  j=$(cs_eng_my_manifest)
  gz="$CS_HOME/state/manifest.json.gz"
  cs_manifest_write "$gz" "$j" || rc=$?
  ((rc == 0 || rc == 3)) || return "$rc"
  md5=$(md5sum -- "$gz")
  md5=${md5%% *}
  md5=${md5#\\}
  [[ $md5 == "$(cs_drive_state_get manifest_md5)" ]] && return 0
  id=$(cs_drive_state_get manifest_id)
  if [[ -n $id ]]; then
    drv_update_content "$id" "$gz" >/dev/null || return
  else
    id=$(drv_upload "$CS_MY_AREA" manifest.json.gz "$gz" "{\"csKind\":\"manifest\",\"csMachine\":\"$CS_ME\"}" | cs_jq -r .id) || return
    [[ -n $id && $id != null ]] || return 1
    cs_drive_state_set manifest_id "$id"
  fi
  cs_drive_state_set manifest_md5 "$md5"
  cs_log info "run: manifest published"
}

# --- other machines' manifests ----------------------------------------------------------------------------

# cs_eng_fetch_remotes: download every other machine's manifest that changed since the last cycle
# (one search for all manifests, then one download per changed manifest).
cs_eng_fetch_remotes() {
  local m mid id md5 old dir="$CS_HOME/state/remote" gz j
  mkdir -p -- "$dir"
  while IFS= read -r m; do
    [[ -n $m ]] || continue
    mid=$(cs_jq -r '.appProperties.csMachine // empty' <<<"$m")
    [[ -n $mid && $mid != "$CS_ME" ]] || continue
    id=$(cs_jq -r .id <<<"$m")
    md5=$(cs_jq -r '.md5Checksum // empty' <<<"$m")
    old=$(cat -- "$dir/$mid.md5" 2>/dev/null || true)
    [[ -n $md5 && $md5 == "$old" && -f $dir/$mid.json ]] && continue
    gz="$CS_HOME/staging/remote.$mid.gz"
    drv_download "$id" "$gz" || {
      cs_log warn "run: could not download the manifest of $mid"
      continue
    }
    if j=$(cs_manifest_read "$gz"); then
      cs_write_atomic "$dir/$mid.json" printf '%s\n' "$j"
      printf '%s\n' "$md5" >"$dir/$mid.md5"
    fi
    rm -f -- "$gz"
  done < <(drv_find_by_prop csKind manifest)
}

# cs_eng_candidates_table: "mid<TAB>sid<TAB>head<TAB>project" for every session in others' manifests.
cs_eng_candidates_table() {
  local f
  for f in "$CS_HOME"/state/remote/*.json; do
    [[ -f $f ]] || continue
    cs_jq -r --arg m "$(basename -- "$f" .json)" '.sessions | to_entries[] | [$m, .key, .value.head, (.value.project // "")] | @tsv' "$f"
  done
}

cs_eng_remote_entry() { # MID SID
  cs_jq -c --arg s "$2" '.sessions[$s]' "$CS_HOME/state/remote/$1.json"
}

# --- DB rows --------------------------------------------------------------------------------------------
# sessions.tsv: sid project_id dir local_size local_mtime installed_len installed_sha base base_segs_ref status flags updated

cs_eng_row_set() { # SID PROJECT DIR SIZE MTIME ILEN ISHA BASE STATUS
  cs_tsv_upsert sessions "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" - "$9" - "$(date +%s)"
}

cs_eng_entry_file() {
  printf '%s\n' "$CS_HOME/state/entries/$1.json"
}

# --- paths ------------------------------------------------------------------------------------------------

# cs_eng_canon_path P / cs_eng_local_path P: one path through the transform (as a "cwd" value).
cs_eng_canon_path() {
  printf '{"cwd":"%s"}\n' "$(cs_json_escape "$1")" | cs_transform canon "$CS_ROWS" | cs_jq -r .cwd
}
cs_eng_local_path() {
  printf '{"cwd":"%s"}\n' "$(cs_json_escape "$1")" | cs_transform local "$CS_ROWS" | cs_jq -r .cwd
}

cs_native_parent() {
  local p=$1
  p=${p%[\\/]*}
  # shellcheck disable=SC1003 # a literal backslash (drive root "C:\")
  [[ $p == [A-Za-z]: ]] && p+='\'
  printf '%s\n' "$p"
}

# cs_eng_place PROJECT_ID LAUNCH_LOCAL: the projects/ subdir for a session first installed here (SPEC §8):
# the slug of the nearest existing ancestor of its launch dir inside the project root, reusing an existing
# slug dir that differs only in case.
cs_eng_place() {
  local pid=$1 launch=$2 root c slug d
  root=$(cs_tsv_rows projects | I=$pid "$CS_AWK" -F'\t' '$1 == ENVIRON["I"] && $6 == 1 { print $2; exit }')
  [[ -n $root ]] || return 1
  c=$launch
  cs_path_under "$c" "$root" || c=$root
  while [[ $c != "$root" && ! -d $(cs_posix_of_native "$c") ]]; do c=$(cs_native_parent "$c"); done
  slug=$(cs_claude_slug "$c")
  if cs_path_ci "$root" && [[ -d $CS_PDIR ]]; then
    for d in "$CS_PDIR"/*/; do
      d=${d%/}
      d=${d##*/}
      [[ ${d,,} == "${slug,,}" ]] && {
        slug=$d
        break
      }
    done
  fi
  printf '%s\n' "$slug"
}

# cs_eng_dup_elsewhere SID FILE: rc 0 if another, different file with this session id exists (SPEC §8.4).
cs_eng_dup_elsewhere() {
  local f
  for f in "$CS_PDIR"/*/"$1".jsonl; do
    [[ -f $f ]] || continue
    [[ -e $2 && $f -ef $2 ]] && continue
    [[ $f == "$2" ]] && continue
    return 0
  done
  return 1
}

# --- segments ------------------------------------------------------------------------------------------

# cs_eng_seg_fetch SEG_JSON: the local cached .gz of a segment (downloaded and sha-checked if needed).
cs_eng_seg_fetch() {
  local sha id c tmp got
  sha=$(cs_jq -r .sha <<<"$1")
  id=$(cs_jq -r .id <<<"$1")
  c="$CS_HOME/cache/segs/$sha.gz"
  if [[ ! -f $c ]]; then
    tmp="$c.csync-tmp.$$"
    drv_download "$id" "$tmp" || return
    got=$(gzip -dc -- "$tmp" | cs_sha256_hex -)
    if [[ $got != "$sha" ]]; then
      rm -f -- "$tmp"
      cs_log warn "run: segment $id has the wrong content (sha $got, want $sha)"
      return 1
    fi
    mv -f -- "$tmp" "$c"
  fi
  printf '%s\n' "$c"
}

# --- publish --------------------------------------------------------------------------------------------

# cs_eng_publish SID FILE PROJECT DIR PREV_LEN: append our new complete lines as one segment.
cs_eng_publish() {
  local sid=$1 f=$2 pid=$3 dir=$4 prev=${5:-0} L seg sha len lines id jr entry seq launch man size mt
  L=$(cs_complete_len "$f")
  ((L > prev)) || return 0
  seg="$CS_HOME/staging/seg.$sid.gz"
  tail -c +$((prev + 1)) -- "$f" | head -c $((L - prev)) | cs_transform canon "$CS_ROWS" | gzip -n -c >"$seg"
  sha=$(gzip -dc -- "$seg" | cs_sha256_hex -)
  read -r lines len < <(gzip -dc -- "$seg" | wc -lc)
  entry=$(cat -- "$(cs_eng_entry_file "$sid")" 2>/dev/null) || entry=$(cs_entry_new "$sid")
  seq=$(cs_jq '.segs | length' <<<"$entry")
  id=$(drv_generate_ids 1) || return
  jr=$(cs_journal_begin publish "$(cs_jq -nc --arg s "$sid" --arg i "$id" --arg t "$seg" '{sid: $s, id: $i, tmp: [$t]}')")
  drv_upload "$CS_MY_AREA" "t-$sid-$seq-${sha:0:16}.jsonl.gz" "$seg" \
    "{\"csKind\":\"seg\",\"csSha\":\"$sha\",\"csSid\":\"$sid\"}" "$id" >/dev/null || {
    cs_journal_end "$jr"
    rm -f -- "$seg"
    return 1
  }
  entry=$(cs_entry_append "$sid" "$entry" "$CS_ME" "$id" "$len" "$lines" "$sha")
  launch=$(cs_eng_canon_path "$(cs_launch_cwd "$f")")
  read -r size mt < <(stat -c '%s %Y' -- "$f")
  entry=$(cs_jq -c --arg p "$pid" --arg l "$launch" --argjson mt "$mt" '. + {project: $p, launch: $l, mtime: $mt}' <<<"$entry")
  man=$(cs_manifest_put_session "$(cs_eng_my_manifest)" "$sid" "$entry")
  cs_eng_my_manifest_save "$man"
  cs_write_atomic "$(cs_eng_entry_file "$sid")" printf '%s\n' "$entry"
  cs_eng_row_set "$sid" "$pid" "$dir" "$size" "$mt" "$L" "$(cs_sha256_range "$f" 0 "$L")" "$(cs_jq -r .head <<<"$entry")" synced
  cs_known_add "$sid" "$(cs_jq -r .head <<<"$entry")"
  cs_journal_end "$jr"
  rm -f -- "$seg"
  cs_log info "run: published $sid (+$lines lines, segment $seq)"
  CS_RUN_PUBLISHED=$((CS_RUN_PUBLISHED + 1))
}

# --- install --------------------------------------------------------------------------------------------

# cs_eng_install SID ENTRY [DIR ILEN BASE]: install the candidate ENTRY. With BASE (our local file is
# exactly that version) only the segments after BASE are fetched and appended to our bytes.
cs_eng_install() {
  local sid=$1 entry=$2 dir=${3:-} ilen=${4:-0} base=${5:-} pid start=0 n i f tmp jr sig sig2 mt
  pid=$(cs_jq -r '.project // empty' <<<"$entry")
  if [[ -z $dir ]]; then
    dir=$(cs_eng_place "$pid" "$(cs_eng_local_path "$(cs_jq -r '.launch // empty' <<<"$entry")")") || return 1
  fi
  f="$CS_PDIR/$dir/$sid.jsonl"
  if cs_eng_dup_elsewhere "$sid" "$f"; then
    cs_log warn "run: $sid exists in another project dir; needs repair"
    cs_eng_row_set "$sid" "$pid" "$dir" 0 0 0 - "${base:--}" needs_repair
    return 0
  fi
  if [[ -n $base ]]; then
    start=$(cs_jq --arg b "$base" '[.segs[].cum] | index([$b])' <<<"$entry")
    [[ $start =~ ^[0-9]+$ ]] || return 1
    start=$((start + 1))
  fi
  n=$(cs_jq '.segs | length' <<<"$entry")
  local -a gzs=()
  for ((i = start; i < n; i++)); do
    gzs+=("$(cs_eng_seg_fetch "$(cs_jq -c ".segs[$i]" <<<"$entry")")") || return 1
  done
  mkdir -p -- "$CS_PDIR/$dir"
  tmp="$f.csync-tmp"
  sig=$(stat -c '%s %Y' -- "$f" 2>/dev/null || echo absent)
  jr=$(cs_journal_begin install "$(cs_jq -nc --arg s "$sid" --arg v "$(cs_jq -r .head <<<"$entry")" --arg t "$tmp" '{sid: $s, version: $v, tmp: [$t]}')")
  local cnt="$CS_HOME/staging/cnt.$sid" shaf="$CS_HOME/staging/sha.$sid"
  {
    if ((ilen > 0)); then head -c "$ilen" -- "$f"; fi
    if ((${#gzs[@]})); then gzip -dc -- "${gzs[@]}" | cs_transform local "$CS_ROWS"; fi
  } | LC_ALL=C "$CS_AWK" -v BINMODE=3 -v cnt="$cnt" '{ print; n++; if (index($0, "\r")) c++ } END { print n + 0, c + 0 > cnt }' |
    tee >(cs_sha256_hex - >"$shaf") >"$tmp"
  wait $! 2>/dev/null || true
  local olines ocrs want
  read -r olines ocrs <"$cnt"
  want=$(cs_jq -r .lines <<<"$entry")
  rm -f -- "$cnt"
  if ((olines != want || ocrs != 0)); then
    cs_log warn "run: install of $sid failed its check ($olines lines, want $want; $ocrs CR)"
    rm -f -- "$tmp" "$shaf"
    cs_journal_end "$jr"
    return 1
  fi
  mt=$(cs_jq -r '.mtime // empty' <<<"$entry")
  [[ $mt =~ ^[0-9]+$ ]] || mt=$(date +%s)
  ((mt > $(date +%s))) && mt=$(date +%s) # clock skew: never in the future
  touch -d "@$mt" -- "$tmp"
  # Compare-and-swap (SPEC §12.7 step 6): the target and the registry must be as when we decided.
  sig2=$(stat -c '%s %Y' -- "$f" 2>/dev/null || echo absent)
  if [[ $sig2 != "$sig" ]] || cs_claude_live_sessions | cut -f1 | grep -qx "$sid"; then
    cs_log info "run: $sid changed or opened during install; deferred"
    rm -f -- "$tmp" "$shaf"
    cs_journal_end "$jr"
    return 0
  fi
  local try
  for try in 1 2 3 4 5 6; do
    mv -f -- "$tmp" "$f" 2>/dev/null && break
    sleep "0.$((try * 2))"
  done
  [[ ! -e $tmp ]] || {
    rm -f -- "$tmp" "$shaf"
    cs_journal_end "$jr"
    return 1
  }
  local size head
  size=$(stat -c %s -- "$f")
  head=$(cs_jq -r .head <<<"$entry")
  cs_eng_row_set "$sid" "$pid" "$dir" "$size" "$mt" "$size" "$(<"$shaf")" "$head" synced
  rm -f -- "$shaf"
  cs_write_atomic "$(cs_eng_entry_file "$sid")" printf '%s\n' "$entry"
  cs_known_add "$sid" "$head"
  # Adopt the version in our manifest too, so others never see our older one as a candidate (C1).
  cs_eng_my_manifest_save "$(cs_manifest_put_session "$(cs_eng_my_manifest)" "$sid" "$entry")"
  cs_journal_end "$jr"
  cs_log info "run: installed $sid ($(( n - start )) new segment(s))"
  CS_RUN_INSTALLED=$((CS_RUN_INSTALLED + 1))
}

# --- deciding ------------------------------------------------------------------------------------------

# cs_eng_pick SID BASE_ENTRY CANDS: among candidate "mid head" lines, the one to install — not already
# known, not an ancestor of our base, and (with a base) a descendant of it. Prints "mid<TAB>head".
cs_eng_pick() {
  local sid=$1 bentry=$2 cands=$3 mid head e best='' bestn=-1 n base=''
  [[ -n $bentry ]] && base=$(cs_jq -r .head <<<"$bentry")
  while IFS=$'\t' read -r mid head; do
    [[ -n $head ]] || continue
    cs_known_has "$sid" "$head" && continue
    [[ -n $bentry ]] && cs_entry_is_ancestor "$bentry" "$head" && continue
    e=$(cs_eng_remote_entry "$mid" "$sid")
    if [[ -n $base ]] && ! cs_entry_is_ancestor "$e" "$base"; then
      printf 'CONFLICT\t%s\n' "$mid"
      return 0
    fi
    n=$(cs_jq '.segs | length' <<<"$e")
    ((n > bestn)) && {
      best="$mid"$'\t'"$head"
      bestn=$n
    }
  done <<<"$cands"
  [[ -n $best ]] && printf '%s\n' "$best"
  return 0
}

# cs_run [--dry-run]: one cycle. Prints a one-line summary.
cs_run() {
  local dry=0
  [[ ${1:-} == --dry-run ]] && dry=1
  exec 9>>"$CS_HOME/sync.lock"
  cs_lock_fd 9 0 || {
    cs_say engine.busy
    return "$CS_EXIT_BUSY"
  }
  cs_eng_load || return
  local j
  while IFS= read -r j; do [[ -n $j ]] && cs_journal_abandon "$j"; done < <(cs_journal_pending)
  cs_root_check || {
    cs_say engine.root_missing
    return "$CS_EXIT_ERROR"
  }
  cs_eng_fetch_remotes
  local table
  table=$(cs_eng_candidates_table)
  CS_RUN_PUBLISHED=0 CS_RUN_INSTALLED=0
  local -A seen=()
  local slug sid size mt row f pid dir lsize lmt ilen isha base status cands pick
  local -a r
  local live
  live=" $(cs_claude_live_sessions | cut -f1 | tr '\n' ' ') "

  # 1. Local sessions (pull first: installs before publishes, SPEC §14 step 9).
  local -a to_publish=()
  while IFS=$'\t' read -r slug sid size mt; do
    [[ -n $sid && $slug =~ ^[A-Za-z0-9_-]+$ ]] || continue
    seen[$sid]=1
    f="$CS_PDIR/$slug/$sid.jsonl"
    if row=$(cs_tsv_get sessions "$sid"); then
      cs_tsv_split "$row" r
      pid=${r[1]} dir=${r[2]} lsize=${r[3]} lmt=${r[4]} ilen=${r[5]} isha=${r[6]} base=${r[7]} status=${r[9]}
      [[ $base == - ]] && base=''
      if [[ $pid == - ]]; then
        # Not in a mapped project when first seen: the user may have mapped it since.
        pid=$(cs_project_of_cwd "$(cs_launch_cwd "$f" 2>/dev/null || echo)" 2>/dev/null) || pid=-
        [[ $pid != - ]] && cs_eng_row_set "$sid" "$pid" "$dir" 0 0 0 - - new
        lsize=0 lmt=0
      fi
    else
      pid=$(cs_project_of_cwd "$(cs_launch_cwd "$f" 2>/dev/null || echo)" 2>/dev/null) || pid=''
      dir=$slug lsize=0 lmt=0 ilen=0 isha=- base='' status=new
      cs_eng_row_set "$sid" "${pid:--}" "$dir" 0 0 0 - - "$([[ -n $pid ]] && echo new || echo unmapped)"
    fi
    [[ -n $pid && $pid != - ]] || continue
    cands=$(printf '%s\n' "$table" | S=$sid "$CS_AWK" -F'\t' -v OFS='\t' '$2 == ENVIRON["S"] { print $1, $3 }')
    local changed=0
    [[ $size != "$lsize" || $mt != "$lmt" ]] && changed=1
    if ((changed)) && [[ -n $base ]] && [[ $(cs_sha256_range "$f" 0 "$ilen") != "$isha" ]]; then
      cs_log info "run: $sid was rewritten locally; deferred (rewrite handling: #18)"
      continue
    fi
    local bentry=''
    [[ -n $base ]] && bentry=$(cat -- "$(cs_eng_entry_file "$sid")" 2>/dev/null || true)
    pick=$(cs_eng_pick "$sid" "$bentry" "$cands")
    if [[ $pick == CONFLICT* ]]; then
      cs_log info "run: $sid diverged from ${pick#*$'\t'}; deferred (forks: #20)"
      continue
    fi
    if [[ -n $pick ]]; then
      if [[ -z $base ]]; then
        cs_log info "run: $sid exists here and remotely without a known base; deferred (initialisation: #18)"
        continue
      fi
      if ((changed)); then
        cs_log info "run: $sid changed here and on ${pick%%$'\t'*}; deferred (forks: #20)"
        continue
      fi
      if [[ $live == *" $sid "* ]]; then
        cs_log info "run: $sid is open here; install deferred (#19)"
        continue
      fi
      ((dry)) && {
        printf 'install %s\n' "$sid"
        continue
      }
      cs_eng_time_left || continue
      cs_eng_install "$sid" "$(cs_eng_remote_entry "${pick%%$'\t'*}" "$sid")" "$dir" "$ilen" "$base" || true
      continue
    fi
    if ((changed)) || [[ -z $base ]]; then
      to_publish+=("$sid"$'\t'"$f"$'\t'"$pid"$'\t'"$dir"$'\t'"${ilen:-0}")
    fi
  done < <(cs_claude_scan)

  # 2. Sessions that exist only on other machines.
  local mid head proj
  while IFS=$'\t' read -r mid sid head proj; do
    [[ -n $sid && -z ${seen[$sid]:-} ]] || continue
    seen[$sid]=1
    cs_tsv_rows projects | cut -f1,6 | grep -qx "$proj"$'\t'1 || continue # not mapped here (#31)
    if row=$(cs_tsv_get sessions "$sid"); then
      cs_log info "run: $sid was installed before but is gone locally; not re-downloaded (#18)"
      continue
    fi
    pick=$(cs_eng_pick "$sid" "" "$(printf '%s\n' "$table" | S=$sid "$CS_AWK" -F'\t' -v OFS='\t' '$2 == ENVIRON["S"] { print $1, $3 }')")
    [[ -n $pick && $pick != CONFLICT* ]] || continue
    ((dry)) && {
      printf 'install %s\n' "$sid"
      continue
    }
    cs_eng_time_left || continue
    cs_eng_install "$sid" "$(cs_eng_remote_entry "${pick%%$'\t'*}" "$sid")" || true
  done <<<"$table"

  # 3. Publish.
  local item
  for item in "${to_publish[@]}"; do
    IFS=$'\t' read -r sid f pid dir ilen <<<"$item"
    ((dry)) && {
      printf 'publish %s\n' "$sid"
      continue
    }
    cs_eng_time_left || break
    cs_eng_publish "$sid" "$f" "$pid" "$dir" "$ilen" || cs_log warn "run: publishing $sid failed; retried next cycle"
  done
  ((dry)) || cs_eng_publish_manifest
  cs_say engine.summary "$CS_RUN_INSTALLED" "$CS_RUN_PUBLISHED"
}
