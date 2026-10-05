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

  [setup.h_lang]='Step 0 - Language'
  [setup.ask_lang]='Language / Ngôn ngữ: 1 = English, 2 = Tiếng Việt'
  [setup.h_deps]='Step 1 - Dependencies'
  [setup.deps_ok]='All required tools found (bash %s, awk %s).'
  [setup.no_python]='Note: python3 is missing; sign-in will ask you to paste the final browser address instead.'
  [setup.no_git]='Note: git is missing; conflicting memory edits will keep the local copy and save the other one aside.'
  [setup.h_client]='Step 2 - Google OAuth client'
  [setup.client_have]='An OAuth client is already installed (%s).'
  [setup.ask_client_replace]='Replace it with another client JSON? (y/n)'
  [setup.client_guide]='claude-sync uses your own Google OAuth client (create it once, then copy the same JSON to every machine):
  1. console.cloud.google.com -> create a project, e.g. "claude-sync".
  2. APIs & Services -> enable "Google Drive API".
  3. Google Auth Platform -> Branding: app name and support email.
  4. Audience: External -> add yourself as a test user -> PUBLISH APP (otherwise sign-ins expire after 7 days).
  5. Data access: add the scope .../auth/drive.file.
  6. Clients -> Create client -> Desktop app -> download the JSON right away.'
  [setup.ask_client_path]='Path to the downloaded client JSON'
  [setup.h_proxy]='Step 3 - Proxy'
  [setup.ask_proxy]='HTTPS proxy for Google APIs ("-" for none)'
  [setup.h_login]='Step 4 - Sign in to Google Drive'
  [setup.ask_relogin]='Sign in again with another account? (y/n)'
  [setup.h_root]='Step 5 - Root folder on Google Drive'
  [setup.ask_root_name]='No claude-sync folder exists yet. Name of the folder to create in My Drive'
  [setup.root_created]='Created "%s" with its marker.'
  [setup.root_found]='Found the existing claude-sync folder "%s".'
  [setup.root_many]='Found %s claude-sync folders; using the oldest, "%s". Others:'
  [setup.root_summary]='  Account: %s
  Folder:  %s
  Link:    %s
  Machines already joined:'
  [setup.no_machines]='    (none yet: this is the first machine)'
  [setup.h_machine]='Step 6 - This machine'
  [setup.ask_machine_name]='Name of this machine'
  [setup.owner_conflict]='%s says another claude-sync install (machine %s) manages this Claude config dir. Refusing to take it over.'
  [setup.machine_done]='This machine is "%s" (%s).'
  [setup.bad_step]='unknown setup step: %s (steps: %s)'
  [setup.step_failed]='setup step "%s" failed; fix the problem and run "claude-sync setup" again (finished steps are kept).'
  [setup.done_so_far]='Steps 0-6 are done. Choosing projects, the schedule and the first sync come in the next version.'
  [folder.not_set]='No root folder is set up yet: run "claude-sync setup".'
  [folder.missing]='The root folder %s is missing or in the trash (ROOT_MISSING). claude-sync will not recreate it on its own.'

  [projects.col_sessions]='SESSIONS'
  [projects.col_size]='SIZE'
  [projects.col_cwd]='LAUNCH CWD (newest session)'
  [projects.col_dir]='PROJECT DIR'
)
