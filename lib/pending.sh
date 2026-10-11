# shellcheck shell=bash
# pending: new paths that need a decision (SPEC §6.1, §6.2, §11 pending_map.tsv, §21 waiting_map).
#   (a) kind "remote": a project another machine syncs that is not mapped here (key = project_id)
#   (b) kind "local":  a folder with Claude sessions outside every mapped root (key = the root)
# The engine only detects and suggests; the user confirms (`projects map`). Never maps by itself, except in mode
# all for a new folder that resembles nothing (SPEC §6.1, user decision 2026-10-06).
# pending_map.tsv: kind key alias machines remote_roots sessions bytes first_seen notified_sessions candidates decision
#   candidates: "path|reason|score;..." (for kind local the path is a project id); decision: pending|skipped|excluded.
#   Empty cells are "-" (a tab-separated read would merge empty cells).
# Requires core, platform, version, manifest, store, claude, transform, projects, cmd_projects, status, engine.

[[ -n ${CS_PENDING_LOADED:-} ]] && return 0
CS_PENDING_LOADED=1

CS_PEND_SCAN_BUDGET=${CS_PEND_SCAN_BUDGET:-5} # seconds per cycle for looking at directories

# --- our projects in the manifest ---------------------------------------------------------------------------

# cs_pend_publish_projects: manifest.projects = {id: {alias, roots[], remote_keys[]}} (hashes only, §6.2).
cs_pend_publish_projects() {
  local p m
  p=$(cs_tsv_rows projects | cs_jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t")) | group_by(.[0])
    | map({key: .[0][0], value: {alias: .[0][2], roots: map(.[1]),
        remote_keys: (map(.[6] // "" | split(",") | map(select(length > 0))) | add // [] | unique)}})
    | from_entries')
  [[ -n $p ]] || return 0
  m=$(cs_eng_my_manifest)
  cs_eng_my_manifest_save "$(cs_jq -c --argjson p "$p" '.projects = $p' <<<"$m")"
}

# --- names ----------------------------------------------------------------------------------------------------

# cs_pend_name_score A B: 0 no match; 1 identical (ignoring case); 2 identical without non-alphanumerics;
# 3 one is a prefix of the other; 4 edit distance <= 2.
cs_pend_name_score() {
  "$CS_AWK" -v a="$1" -v b="$2" '
    function lev(s, t,   i, j, n, m, d, c, x) {
      n = length(s); m = length(t)
      for (i = 0; i <= n; i++) d[i, 0] = i
      for (j = 0; j <= m; j++) d[0, j] = j
      for (i = 1; i <= n; i++) for (j = 1; j <= m; j++) {
        c = (substr(s, i, 1) == substr(t, j, 1)) ? 0 : 1
        x = d[i - 1, j] + 1
        if (d[i, j - 1] + 1 < x) x = d[i, j - 1] + 1
        if (d[i - 1, j - 1] + c < x) x = d[i - 1, j - 1] + c
        d[i, j] = x
      }
      return d[n, m]
    }
    BEGIN {
      a = tolower(a); b = tolower(b)
      if (a == "" || b == "") { print 0; exit }
      if (a == b) { print 1; exit }
      na = a; nb = b; gsub(/[^a-z0-9]/, "", na); gsub(/[^a-z0-9]/, "", nb)
      if (na != "" && na == nb) { print 2; exit }
      if (length(na) >= 3 && length(nb) >= 3 && (index(na, nb) == 1 || index(nb, na) == 1)) { print 3; exit }
      if (lev(na, nb) <= 2) { print 4; exit }
      print 0
    }'
}

# cs_pend_equiv ROOT: the same folder as seen from the other side of Windows/WSL (D:\a\b <-> /mnt/d/a/b).
cs_pend_equiv() {
  local r=$1 d rest
  if [[ $r =~ ^([A-Za-z]):[\\/](.*)$ ]]; then
    d=${BASH_REMATCH[1]}
    rest=${BASH_REMATCH[2]//\\//}
    printf '/mnt/%s/%s\n' "${d,,}" "$rest"
  elif [[ $r =~ ^/mnt/([A-Za-z])/(.*)$ ]]; then
    d=${BASH_REMATCH[1]}
    rest=${BASH_REMATCH[2]//\//\\}
    printf '%s:\\%s\n' "${d^^}" "$rest"
  else
    return 1
  fi
}

# --- looking at directories (bounded in time, resumable through a cache) -----------------------------------------

cs_pend_scan_roots() {
  local d
  local -a roots=()
  if [[ -n $(cs_config_get scan_dirs "") ]]; then
    read -r -a roots <<<"$(cs_config_get scan_dirs "")"
  else
    roots=("$HOME/projects" "$HOME/Projects" "$HOME/work" "$HOME/src" "$HOME/code")
  fi
  while IFS=$'\t' read -r _ d _; do
    [[ -n $d ]] || continue
    d=$(cs_posix_of_native "$d")
    roots+=("${d%/*}")
  done < <(cs_tsv_rows projects)
  printf '%s\n' "${roots[@]}" | sort -u | while IFS= read -r d; do [[ -d $d ]] && printf '%s\n' "$d"; done
}

# cs_pend_scan_update: look at directories not seen yet (git remotes), until CS_PEND_SCAN_BUDGET seconds are used.
cs_pend_scan_update() {
  local cache="$CS_HOME/state/scan_cache.tsv" start=$SECONDS d keys root
  local -A seen=()
  [[ -f $cache ]] || : >"$cache"
  while IFS=$'\t' read -r d _; do seen[$d]=1; done <"$cache"
  while IFS= read -r root; do
    while IFS= read -r d; do
      [[ -n $d && -z ${seen[$d]:-} ]] || continue
      ((SECONDS - start >= CS_PEND_SCAN_BUDGET)) && return 0
      keys=''
      [[ -e $d/.git ]] && keys=$(cs_remote_keys "$d")
      printf '%s\t%s\n' "$d" "${keys:--}" >>"$cache"
      seen[$d]=1
    done < <(find "$root" -mindepth 1 -maxdepth 2 \( -name node_modules -o -name '.*' \) -prune -o -type d -print 2>/dev/null)
  done < <(cs_pend_scan_roots)
}

cs_pend_keys_intersect() { # "a,b" "c,d" -> rc 0 if they share a key
  local a k
  [[ -n $1 && $1 != - && -n $2 && $2 != - ]] || return 1
  for a in ${1//,/ }; do
    for k in ${2//,/ }; do [[ $a == "$k" ]] && return 0; done
  done
  return 1
}

# --- candidates --------------------------------------------------------------------------------------------------

# cs_pend_cands_remote ALIAS ROOTS("|"-separated) KEYS: "score<TAB>path<TAB>reason" lines, best first.
cs_pend_cands_remote() {
  local alias=$1 rlist=$2 keys=$3 r e d k ns base cache="$CS_HOME/state/scan_cache.tsv" root n
  local -a rr=()
  IFS='|' read -r -a rr <<<"$rlist"
  for r in "${rr[@]}"; do
    e=$(cs_pend_equiv "$r") || continue
    [[ -d $(cs_posix_of_native "$e") ]] && printf '10\t%s\tpath_equivalent\n' "$e"
  done
  while IFS=$'\t' read -r root n _; do
    [[ -n $root ]] || continue
    ns=$(cs_pend_name_score "$alias" "${root##*[\\/]}")
    ((ns > 0)) && printf '%s\t%s\tclaude_ran_here_name\n' "$((20 + ns))" "$root"
  done < <(cs_unmapped_roots)
  [[ -f $cache ]] || return 0
  while IFS=$'\t' read -r d k; do
    [[ -n $d ]] || continue
    base=${d##*/}
    if cs_pend_keys_intersect "$k" "$keys"; then
      printf '30\t%s\tsame_git_remote\n' "$(cs_native_path "$d")"
      continue
    fi
    ns=$(cs_pend_name_score "$alias" "$base")
    ((ns > 0)) && printf '%s\t%s\tname\n' "$((40 + ns))" "$(cs_native_path "$d")"
  done <"$cache"
}

# cs_pend_cands_local ROOT: existing projects that this new folder may be another root of.
cs_pend_cands_local() {
  local root=$1 base keys id alias pkeys ns
  base=${root##*[\\/]}
  keys=$(cs_remote_keys "$root")
  while IFS=$'\t' read -r id _ alias _ _ _ pkeys; do
    [[ -n $id ]] || continue
    if cs_pend_keys_intersect "$keys" "$pkeys"; then
      printf '30\t%s\tsame_git_remote\n' "$id"
      continue
    fi
    ns=$(cs_pend_name_score "$base" "$alias")
    ((ns > 0)) && printf '%s\t%s\tname\n' "$((40 + ns))" "$id"
  done < <(cs_tsv_rows projects)
}

# cs_pend_pack: stdin "score path reason" -> "path|reason|score;..." (best score per path, best first).
cs_pend_pack() {
  sort -t$'\t' -k1,1n -s | "$CS_AWK" -F'\t' '!($2 in s) { s[$2] = 1; printf "%s%s|%s|%s", (n++ ? ";" : ""), $2, $3, $1 } END { if (!n) printf "-"; print "" }'
}

# --- detection ------------------------------------------------------------------------------------------------------

# cs_pend_row_get KIND KEY: the row's fields in the array CS_PR (rc 1 if none).
cs_pend_row_get() {
  local row
  row=$(cs_tsv_get pending_map "$1" "$2") || return 1
  cs_tsv_split "$row" CS_PR
}

# cs_pend_upsert KIND KEY ALIAS MACHINES ROOTS SESSIONS BYTES CANDS: keeps first_seen, notified and decision.
cs_pend_upsert() {
  local kind=$1 key=$2 first now notified=0 dec=pending
  now=$(date +%s)
  first=$now
  if cs_pend_row_get "$kind" "$key"; then
    first=${CS_PR[7]} notified=${CS_PR[8]} dec=${CS_PR[10]}
    [[ $dec == skipped ]] && (($6 > notified)) && dec=pending
  fi
  cs_tsv_upsert pending_map "$kind" "$key" "${3:--}" "${4:--}" "${5:--}" "$6" "$7" "$first" "$notified" "${8:--}" "$dec"
}

cs_pend_detect() {
  local f mid name id alias roots keys n bytes machines mode
  local -A seen_remote=()
  mode=$(cs_config_get mode all)
  # (a) projects of other machines that are not mapped here
  local -A mapped=()
  while IFS=$'\t' read -r id _; do mapped[$id]=1; done < <(cs_tsv_rows projects)
  local -A nm=() nroots=() nkeys=() nsess=() nbytes=() nalias=()
  for f in "$CS_HOME"/state/remote/*.json; do
    [[ -f $f ]] || continue
    name=$(cs_jq -r '.name // empty' "$f")
    while IFS=$'\t' read -r id alias roots keys; do
      [[ -n $id && -z ${mapped[$id]:-} ]] || continue
      nalias[$id]=$alias
      nm[$id]+="${nm[$id]:+,}$name"
      nroots[$id]+="${nroots[$id]:+|}$roots"
      nkeys[$id]+="${nkeys[$id]:+,}$keys"
    done < <(cs_jq -r '.projects // {} | to_entries[] | [.key, .value.alias, (.value.roots | join("|")), (.value.remote_keys | join(","))] | @tsv' "$f")
    while IFS=$'\t' read -r id n bytes; do
      [[ -n $id && -z ${mapped[$id]:-} && -n ${nalias[$id]:-} ]] || continue
      nsess[$id]=$((${nsess[$id]:-0} + n))
      nbytes[$id]=$((${nbytes[$id]:-0} + bytes))
    done < <(cs_jq -r '[.sessions[] | select((.project // "") != "" and .project != "unmapped")] | group_by(.project) | .[] | [.[0].project, length, (map(.len) | add)] | @tsv' "$f")
  done
  cs_pend_scan_update
  for id in "${!nalias[@]}"; do
    seen_remote[$id]=1
    cs_pend_row_get remote "$id" && [[ ${CS_PR[10]} == excluded ]] && continue
    cs_pend_upsert remote "$id" "${nalias[$id]}" "${nm[$id]}" "${nroots[$id]}" "${nsess[$id]:-0}" "${nbytes[$id]:-0}" \
      "$(cs_pend_cands_remote "${nalias[$id]}" "${nroots[$id]}" "${nkeys[$id]}" | cs_pend_pack)"
  done
  # rows that were resolved (mapped meanwhile, or the other machines no longer have the project)
  local kind key rows
  rows=$(cs_tsv_rows pending_map)
  while IFS=$'\t' read -r kind key _; do
    [[ $kind == remote ]] || continue
    [[ -n ${seen_remote[$key]:-} ]] && continue
    cs_pend_row_get remote "$key" && [[ ${CS_PR[10]} == excluded && -z ${mapped[$key]:-} ]] && continue
    cs_tsv_delete pending_map remote "$key"
  done <<<"$rows"
  # (b) folders with local sessions outside every mapped root
  local root un
  un=$(cs_unmapped_roots)
  local -A seen_local=()
  local cands
  if [[ $mode == all ]]; then
    while IFS=$'\t' read -r root n bytes; do
      [[ -n $root ]] || continue
      seen_local[$root]=1
      cs_pend_row_get local "$root" && [[ ${CS_PR[10]} == excluded ]] && continue
      cands=$(cs_pend_cands_local "$root" | cs_pend_pack)
      if [[ $cands == - ]] && ! cs_pend_row_get local "$root"; then
        cs_pend_auto_add "$root"
        continue
      fi
      cs_pend_upsert local "$root" "${root##*[\\/]}" "$(cs_config_get machine_name "")" "$root" "$n" "$bytes" "$cands"
    done <<<"$un"
  fi
  rows=$(cs_tsv_rows pending_map)
  while IFS=$'\t' read -r kind key _; do
    [[ $kind == local && -z ${seen_local[$key]:-} ]] || continue
    cs_pend_row_get local "$key" && [[ ${CS_PR[10]} == excluded ]] && continue
    cs_tsv_delete pending_map local "$key"
  done <<<"$rows"
  cs_pend_status
}

# cs_pend_auto_add ROOT: mode all and the folder resembles no project: it becomes a project (SPEC §6.1).
cs_pend_auto_add() {
  local root=$1 alias id state
  alias=${root##*[\\/]}
  IFS=$'\t' read -r id _ state < <(cs_project_map "$alias" "$root" 2>/dev/null)
  [[ -n $id ]] || return 0
  cs_log info "run: new folder $root added as project $alias ($id)"
  cs_status_patch '.auto_added = (((.auto_added // []) + [$a]) | unique)' --arg a "$alias"
}

# cs_pend_status: status.json waiting_map from the rows that still wait for a decision.
cs_pend_status() {
  local kind key alias machines sessions top j='[]'
  while IFS=$'\t' read -r kind key alias machines _ sessions _ _ _ cands dec; do
    [[ $dec == pending ]] || continue
    top=${cands%%;*}
    [[ $top == - ]] && top=''
    j=$(cs_jq -c --arg k "$kind" --arg key "$key" --arg a "$alias" --arg m "$machines" --argjson n "$sessions" --arg t "${top%%|*}" \
      '. + [{kind: $k, key: $key, alias: $a, machine: $m, sessions: $n, top_candidate: $t}]' <<<"$j")
  done < <(cs_tsv_rows pending_map)
  cs_status_waiting_map_set "$j"
}

# --- the user's side: projects pending / projects map ----------------------------------------------------------------

# cs_pend_list: what waits for a decision (decision = pending).
cs_pend_list() {
  local kind key alias machines roots sessions bytes first notified cands dec i c any=0
  while IFS=$'\t' read -r kind key alias machines roots sessions bytes first notified cands dec; do
    [[ $dec == pending ]] || continue
    any=1
    if [[ $kind == remote ]]; then
      cs_say pending.row_remote "$alias" "$machines" "$roots" "$sessions" "$(cs_human_bytes "$bytes")"
    else
      cs_say pending.row_local "$key" "$sessions" "$(cs_human_bytes "$bytes")"
    fi
    i=0
    if [[ $cands != - ]]; then
      local IFS=';'
      for c in $cands; do
        i=$((i + 1))
        cs_say pending.cand "$i" "$(cs_pend_cand_show "$kind" "${c%%|*}")" "$(cs_t "pending.reason_${c#*|}" 2>/dev/null | head -n 1 || true)"
      done
    fi
  done < <(cs_tsv_rows pending_map)
  ((any)) || cs_say pending.none
}

# cs_pend_cand_show KIND PATH_OR_ID: a candidate as text (a project candidate shows its alias).
cs_pend_cand_show() {
  if [[ $1 == local ]]; then
    printf '%s (%s)\n' "$(cs_tsv_rows projects | I=$2 "$CS_AWK" -F'\t' '$1 == ENVIRON["I"] { print $3; exit }')" "$2"
  else
    printf '%s\n' "$2"
  fi
}

# cs_pend_precheck PATH: rc 0 if PATH can be mapped (exists; asks again when it nests inside another project).
cs_pend_precheck() {
  local p=$1 other orow
  [[ -d $(cs_posix_of_native "$p") ]] || {
    cs_say projects.no_dir "$p" >&2
    return 1
  }
  while IFS=$'\t' read -r other orow _; do
    [[ -n $other ]] || continue
    orow=$(printf '%s' "$orow")
    if [[ $orow != "$p" ]] && { cs_path_under "$p" "$orow" || cs_path_under "$orow" "$p"; }; then
      cs_confirm pending.confirm_nested n "$p" "$orow" || return 1
      break
    fi
  done < <(cs_tsv_rows projects | "$CS_AWK" -F'\t' -v OFS='\t' '{ print $1, $2 }')
  if [[ $p == /mnt/* ]] && [[ $CS_OS == linux ]]; then cs_say pending.mnt_warn "$p" >&2; fi
  return 0
}

# cs_pend_decide KIND KEY DECISION: skip (remember the session count) or exclude for good.
cs_pend_decide() {
  cs_pend_row_get "$1" "$2" || return 1
  cs_tsv_upsert pending_map "$1" "$2" "${CS_PR[2]}" "${CS_PR[3]}" "${CS_PR[4]}" "${CS_PR[5]}" "${CS_PR[6]}" "${CS_PR[7]}" "${CS_PR[5]}" "${CS_PR[9]}" "$3"
}

# cs_pend_review: go through the pending items one by one.
cs_pend_review() {
  local kind key alias machines roots sessions bytes first notified cands dec ans i c rest id root path rows any=0
  rows=$(cs_tsv_rows pending_map)
  while IFS=$'\t' read -r -u 7 kind key alias machines roots sessions bytes first notified cands dec; do
    [[ $dec == pending ]] || continue
    any=1
    local -a cl=()
    if [[ $cands != - ]]; then
      local IFS=';'
      for c in $cands; do cl+=("${c%%|*}"); done
      unset IFS
    fi
    while :; do
      if [[ $kind == remote ]]; then
        cs_say pending.row_remote "$alias" "$machines" "$roots" "$sessions" "$(cs_human_bytes "$bytes")"
      else
        cs_say pending.row_local "$key" "$sessions" "$(cs_human_bytes "$bytes")"
      fi
      i=0
      for c in "${cl[@]}"; do
        i=$((i + 1))
        cs_say pending.cand "$i" "$(cs_pend_cand_show "$kind" "$c")" ""
      done
      ans=$(cs_ask pending.ask s)
      case ${ans,,} in
        s) cs_pend_decide "$kind" "$key" skipped && break ;;
        x) cs_pend_decide "$kind" "$key" excluded && break ;;
        p)
          path=$(cs_ask pending.ask_path "")
          cs_pend_precheck "$path" || continue
          cs_pend_apply "$kind" "$key" "$alias" "$path" && break
          ;;
        r)
          [[ $kind == local ]] || continue
          id=$(cs_ask pending.ask_project "")
          id=$(cs_project_find "$id") || {
            cs_say projects.unknown "$id" >&2
            continue
          }
          cs_project_map "$id" "$key" >/dev/null && cs_tsv_delete pending_map local "$key" && break
          ;;
        *)
          if [[ $ans =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= ${#cl[@]})); then
            path=${cl[ans - 1]}
            if [[ $kind == remote ]]; then
              cs_pend_precheck "$path" || continue
              cs_pend_apply remote "$key" "$alias" "$path" && break
            else
              cs_project_map "$path" "$key" >/dev/null && cs_tsv_delete pending_map local "$key" && break
            fi
          else
            cs_say pending.bad >&2
          fi
          ;;
      esac
    done
  done 7<<<"$rows"
  ((any)) || cs_say pending.none
  cs_pend_status
}

# cs_pend_apply KIND KEY ALIAS PATH: map PATH. A remote project keeps the project_id of the other machines.
cs_pend_apply() {
  local id state
  if [[ $1 == remote ]]; then
    IFS=$'\t' read -r id _ state < <(cs_project_map "$3" "$4" "$2")
  else
    IFS=$'\t' read -r id _ state < <(cs_project_map "$3" "$4")
  fi
  [[ -n $id ]] || return 1
  cs_say projects.mapped "$3" "$id" "$4"
  cs_tsv_delete pending_map "$1" "$2"
}
