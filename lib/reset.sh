# shellcheck shell=bash
# reset: `claude-sync reset [--yes]` — forget what this machine remembers about what was synced, so that the next run
# uploads everything again (a clean re-import). Only the sync bookkeeping under ~/.claude-sync/state goes: the
# login, the OAuth client, the config, the projects chosen and everything under ~/.claude stay. Nothing on Drive is
# deleted (SPEC §11: the DB can always be rebuilt). Requires core, platform, store, drive (state), ui.

[[ -n ${CS_RESET_LOADED:-} ]] && return 0
CS_RESET_LOADED=1

cs_reset() {
  local yes=0 f k
  while (($#)); do
    case $1 in
      --yes) yes=1 ;;
      *) cs_die_t "$CS_EXIT_USAGE" reset.usage ;;
    esac
    shift
  done
  cs_store_init
  # no sync may be running while its bookkeeping is removed
  exec 9>>"$CS_HOME/sync.lock"
  cs_lock_fd 9 0 || cs_die_t "$CS_EXIT_BUSY" reset.busy
  if ((!yes)); then
    cs_confirm reset.ask n || return 1
  fi
  local st="$CS_HOME/state"
  rm -rf -- "$st/entries" "$st/known" "$st/bundle" "$st/agents" "$st/remote" "$st/base"
  rm -f -- "$st/sessions.tsv" "$st/manifest.json" "$st/manifest.json.gz" "$st/launch_cache.tsv" "$st/scan_cache.tsv" \
    "$st/retention_skipped" "$st/hook-notified" "$st"/live_pub.* "$st/forks.tsv"
  rm -rf -- "$CS_HOME/cache/segs" "$CS_HOME/cache/packs" "$CS_HOME/staging" "$CS_HOME/journal"
  rm -f -- "$CS_HOME/pending" "$CS_HOME/run.stamp"
  # the ids of our objects on Drive are forgotten too: the next run finds the machine folder and our manifest again
  f="$st/drive.json"
  if [[ -f $f ]]; then
    local j
    j=$(<"$f")
    for k in manifest_id manifest_md5 live_id gc_last machine_folder_id; do
      j=$(cs_jq -c --arg k "$k" 'del(.[$k])' <<<"$j")
    done
    cs_write_atomic "$f" printf '%s\n' "$j"
  fi
  cs_store_init
  cs_say reset.done
  cs_say reset.drive_hint
}
