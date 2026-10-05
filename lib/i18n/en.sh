# shellcheck shell=bash
# English UI messages: printf formats. Keys and % specifiers must match lib/i18n/vi.sh (test/i18n.bats).
# No backslashes in formats; pass paths and other data as %s arguments.

declare -gA CS_MSG_en=(
  [usage]='usage: claude-sync <command> [args]

  setup                         full setup wizard (re-runnable)
  login [--device] | logout     sign in to / revoke Google Drive access
  folder [show]                 root folder, marker, machines
  projects ...                  list|select|pending|map|unmap|mode|exclude
  sync [--pull-only|--push-only] [--project X] [--dry-run] [--verbose]
  run [--trigger=...]           one non-interactive cycle (used by the service)
  status [--json]               health, last/next run, behind, conflicts, waiting maps
  conflicts [list|show <sid>]   forked sessions, losing memory/plan copies
  restore <sid>                 reinstall a session removed by retention
  repair [--dry-run]            fix legacy data (CRLF, spaced JSON, foreign cwd, duplicates)
  service install|uninstall|status|kick
  hooks install|uninstall
  config get|set <key> <value>  interval=5|10, guard=block|warn|off, lang=en|vi
  machines [list|forget <name>]
  claude [args...]              pull, then exec claude
  doctor                        check dependencies and installation
  logs [-f]
  uninstall [--purge]
  --version | help'
  [cli.unknown_command]='unknown command: %s'
  [cli.not_implemented]='"%s" is not implemented yet'

  [boot.missing_tools]='missing required tools: %s — %s'
  [boot.install_git]='install Git for Windows (https://gitforwindows.org); jq: winget install jqlang.jq'
  [boot.install_apt]='sudo apt install %s'
  [boot.gnu_tool]='GNU %s is not first in PATH (%s)'

  [config.bad_key]='invalid config key: %s'
  [config.multiline]='config value must be a single line'
  [claude.config_dir_empty]='CLAUDE_CONFIG_DIR is set but empty'
  [settings.not_json]='settings: the value for %s is not valid JSON'
  [settings.not_object]='settings: %s is not a JSON object; leaving it untouched'

  [doctor.title]='claude-sync %s doctor'
  [doctor.env]='bash %s, awk %s, os %s'
  [doctor.claude_dir]='Claude config dir: %s'
  [doctor.claude_dir_missing]='Claude config dir not found: %s'
  [doctor.sessions]='%s sessions in %s project dirs'
  [doctor.retention]='retention (cleanupPeriodDays, user settings): %s days'
  [doctor.junk_dir]='not a valid project dir (hijacks --resume): projects/%s'
  [doctor.dup_ids]='%s session ids exist in more than one project dir'
  [doctor.problems]='Problems found: run "claude-sync repair --dry-run" (repair is not implemented yet).'
  [doctor.ok]='No problems found.'

  [auth.no_client]='no OAuth client found (%s): run "claude-sync login --client <downloaded client JSON>" or "claude-sync setup"'
  [auth.bad_client]='%s is not a Google OAuth client JSON (expected "installed" with client_id and client_secret)'
  [auth.open_url]='Open this URL in a browser to sign in (trying to open it for you):'
  [auth.waiting]='Waiting for Google... If the browser cannot come back here (SSH, WSL), paste the final http://127.0.0.1:... address from the browser and press Enter.'
  [auth.browser_done]='claude-sync: signed in. You can close this tab and return to the terminal.'
  [auth.timeout]='No answer from the browser in time. Run "claude-sync login" again.'
  [auth.state_mismatch]='The browser answer does not belong to this login (state mismatch). Run "claude-sync login" again.'
  [auth.denied]='Google returned an error: %s'
  [auth.exchange_failed]='Could not exchange the sign-in code for a token: %s'
  [auth.no_drive_scope]='Google Drive access was not granted (tick the Drive checkbox) - run "claude-sync login" again.'
  [auth.testing_mode]='Warning: the OAuth app is still in "Testing": sign-ins expire after 7 days. Publish it (Google Auth Platform > Audience).'
  [auth.signed_in]='Signed in.'
  [auth.signed_in_as]='Signed in as: %s'
  [auth.logged_out]='Signed out: the token was revoked and removed from this machine.'
  [auth.client_installed]='OAuth client saved to %s'

  [projects.col_sessions]='SESSIONS'
  [projects.col_size]='SIZE'
  [projects.col_cwd]='LAUNCH CWD (newest session)'
  [projects.col_dir]='PROJECT DIR'
)
