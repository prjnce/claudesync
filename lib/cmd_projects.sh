# shellcheck shell=bash
# cmd_projects: the "claude-sync projects" command (SPEC §20). Requires lib/projects.sh and lib/ui.sh.

[[ -n ${CS_CMD_PROJECTS_LOADED:-} ]] && return 0
CS_CMD_PROJECTS_LOADED=1

# cs_unmapped_roots: "candidate root<TAB>sessions<TAB>bytes" for local launch dirs outside every mapped root.
cs_unmapped_roots() {
  local cwd n b root
  cs_launch_cache_init
  while IFS=$'\t' read -r cwd n b; do
    [[ -n $cwd ]] || continue
    # an unresolved token ({P:id}, {R:id}, {MEM:id}) is not a folder: no project can be made of it
    [[ $cwd == \{[PRM]*:*\}* ]] && continue
    cs_project_of_cwd "$cwd" >/dev/null 2>&1 && continue
    root=$(cs_root_of_launch "$cwd")
    printf '%s\t%s\t%s\n' "$root" "$n" "$b"
  done <<<"$CS_LAUNCH_CWDS" | "$CS_AWK" -F'\t' -v OFS='\t' '{ n[$1] += $2; b[$1] += $3 } END { for (r in n) print r, n[r], b[r] }' | sort
}

# cs_project_session_counts: "project_id<TAB>sessions<TAB>bytes" from local transcripts.
cs_project_session_counts() {
  local cwd n b id
  cs_launch_cache_init
  while IFS=$'\t' read -r cwd n b; do
    [[ -n $cwd ]] || continue
    id=$(cs_project_of_cwd "$cwd" 2>/dev/null) || continue
    printf '%s\t%s\t%s\n' "$id" "$n" "$b"
  done <<<"$CS_LAUNCH_CWDS" | "$CS_AWK" -F'\t' -v OFS='\t' '{ n[$1] += $2; b[$1] += $3 } END { for (i in n) print i, n[i], b[i] }'
}

cs_projects_list() {
  local counts id root alias en n b last=''
  counts=$(cs_project_session_counts)
  cs_say projects.mapped_header "$(cs_config_get mode all)"
  if [[ -z $(cs_tsv_rows projects) ]]; then
    cs_say projects.none_mapped
  fi
  while IFS=$'\t' read -r id root alias _ _ en _; do
    [[ -n $id ]] || continue
    if [[ $id != "$last" ]]; then
      IFS=$'\t' read -r _ n b < <(printf '%s\n' "$counts" | I=$id "$CS_AWK" -F'\t' '$1 == ENVIRON["I"]' | grep . || printf 'x\t0\t0\n')
      printf '  %s %s  %s %s  %s\n' "$(cs_pad "$alias" 20)" "$id" "$(cs_pad "$n" 5)" "$(cs_pad "$(cs_human_bytes "$b")" 10)" \
        "$([[ $en == 1 ]] || cs_t projects.excluded_tag)"
      last=$id
    fi
    printf '      %s\n' "$root"
  done < <(cs_tsv_rows projects | sort -t $'\t' -k3,3 -k1,1)
  local un
  un=$(cs_unmapped_roots)
  if [[ -n $un ]]; then
    printf '\n'
    cs_say projects.unmapped_header
    while IFS=$'\t' read -r root n b; do
      printf '  %s  %s  %s\n' "$(cs_pad "$n" 5)" "$(cs_pad "$(cs_human_bytes "$b")" 10)" "$root"
    done <<<"$un"
  fi
}

# cs_projects_select: interactive — pick unmapped local folders to sync (SPEC §16 step 8).
cs_projects_select() {
  local un i=0 ans root n b alias
  local -a roots=()
  cs_projects_list
  un=$(cs_unmapped_roots)
  if [[ -z $un ]]; then
    cs_say projects.nothing_to_select
    return 0
  fi
  printf '\n'
  while IFS=$'\t' read -r root n b; do
    i=$((i + 1))
    roots+=("$root")
    printf '  %2d) %s  (%s, %s)\n' "$i" "$root" "$n" "$(cs_human_bytes "$b")"
  done <<<"$un"
  ans=$(cs_ask projects.ask_select "")
  if [[ -z $ans ]]; then
    return 0 # nothing chosen: nothing changes (neither the projects nor the mode)
  elif [[ $ans == a || $ans == all ]]; then
    cs_config_set mode all
    ans=$(seq -s, 1 "$i")
  else
    cs_config_set mode selected
  fi
  local IFS=', '
  for n in $ans; do
    if ! [[ $n =~ ^[0-9]+$ ]] || ((n < 1 || n > i)); then continue; fi
    root=${roots[n - 1]}
    alias=${root##*[\\/]}
    # A new folder becomes a new project: never join another project just because the names match.
    if cs_project_find "$alias" >/dev/null 2>&1; then alias="$alias-$n"; fi
    IFS=$'\t' read -r id _ state < <(cs_project_map "$alias" "$root")
    cs_say projects.mapped "$alias" "$id" "$root"
  done
}

cmd_projects() {
  local sub=${1:-list}
  shift || true
  case $sub in
    list) cs_projects_list ;;
    select) cs_projects_select ;;
    map)
      if (($# == 0)); then
        cs_pend_review
        return 0
      fi
      (($# == 2)) || cs_die_t "$CS_EXIT_USAGE" projects.usage_map
      local id root state pend=''
      # A project that other machines sync and that waits here keeps its project_id (SPEC §6.1).
      if ! cs_project_find "$1" >/dev/null 2>&1; then
        pend=$(cs_tsv_rows pending_map | A=$1 "$CS_AWK" -F'\t' '$1 == "remote" && (tolower($3) == tolower(ENVIRON["A"]) || $2 == ENVIRON["A"]) { print $2; exit }')
      fi
      if [[ -n $pend ]]; then
        IFS=$'\t' read -r id root state < <(cs_project_map "$1" "$2" "$pend")
        [[ -n $id ]] && cs_tsv_delete pending_map remote "$pend"
      else
        IFS=$'\t' read -r id root state < <(cs_project_map "$1" "$2")
      fi
      [[ -n $id ]] || exit 1
      cs_say projects.mapped "$(cs_tsv_field projects alias "$id" "$root")" "$id" "$root"
      ;;
    unmap)
      (($# >= 1)) || cs_die_t "$CS_EXIT_USAGE" projects.usage_unmap
      cs_project_unmap "$@"
      cs_say projects.unmapped "$1"
      ;;
    mode)
      case ${1:-} in
        all | selected) cs_config_set mode "$1" && cs_say projects.mode_set "$1" ;;
        *) cs_die_t "$CS_EXIT_USAGE" projects.usage_mode ;;
      esac
      ;;
    exclude | include)
      (($# == 1)) || cs_die_t "$CS_EXIT_USAGE" projects.usage_exclude
      cs_project_set_enabled "$1" "$([[ $sub == include ]] && echo 1 || echo 0)"
      cs_say "projects.${sub}d" "$1"
      ;;
    dirs)
      # Raw view per projects/<slug> dir (what doctor looks at).
      local slug n bytes cwd
      printf '%s %s %s %s\n' "$(cs_pad "$(cs_t projects.col_sessions)" 8)" "$(cs_pad "$(cs_t projects.col_size)" 10)" \
        "$(cs_pad "$(cs_t projects.col_cwd)" 50)" "$(cs_t projects.col_dir)"
      while IFS=$'\t' read -r slug n bytes cwd; do
        [[ -n $slug ]] || continue
        printf '%s %s %s %s\n' "$(cs_pad "$n" 8)" "$(cs_pad "$(cs_human_bytes "$bytes")" 10)" "$(cs_pad "$cwd" 50)" "$slug"
      done < <(cs_claude_projects_report)
      ;;
    pending) cs_pend_list ;;
    *) cs_die_t "$CS_EXIT_USAGE" cli.unknown_command "projects $sub" ;;
  esac
}
