# shellcheck shell=bash
# uninstall: `claude-sync uninstall [--purge] [--yes]` (SPEC §20). Removes the service and the Claude Code hooks;
# --purge also deletes ~/.claude-sync. It never touches ~/.claude (the owner file stays, so a later setup takes the
# same machine identity and the same area on Drive back) and never touches Drive.
# Requires core, platform, store, claude, scheduler, hooks, ui.

[[ -n ${CS_UNINSTALL_LOADED:-} ]] && return 0
CS_UNINSTALL_LOADED=1

cs_uninstall() {
  local purge=0 yes=0 extra=''
  while (($#)); do
    case $1 in
      --purge) purge=1 ;;
      --yes) yes=1 ;;
      *) cs_die_t "$CS_EXIT_USAGE" cli.unknown_command "uninstall $1" ;;
    esac
    shift
  done
  if ((!yes)); then
    if ((purge)); then extra=$(cs_t uninstall.with_purge); fi
    cs_confirm uninstall.ask n "$extra" || return 1
  fi
  cs_sched_uninstall || true
  cs_hooks_uninstall || true
  if ((purge)); then
    # a purge only ever deletes the claude-sync data dir, whatever the environment says
    if [[ -z $CS_HOME || $CS_HOME == / || $CS_HOME == "$HOME" || $CS_HOME == "$HOME/" ]]; then
      cs_die_t "$CS_EXIT_ERROR" uninstall.refuse "$CS_HOME"
    fi
    rm -rf -- "$CS_HOME"
    cs_say uninstall.purged "$CS_HOME"
  fi
  cs_say uninstall.done
}
