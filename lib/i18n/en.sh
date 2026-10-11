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

  [projects.no_dir]='not a directory on this machine: %s'
  [projects.spelling]='Note: you typed %s; Claude writes it as %s in its transcripts, so that spelling is used.'
  [projects.no_sessions_here]='Note: no Claude session on this machine was started under %s (yet).'
  [projects.nested]='Warning: %s overlaps the root %s of another project (the longest root wins for each session).'
  [projects.unknown]='no project with id or name %s'
  [projects.mapped_header]='Projects synced from this machine (mode: %s):'
  [projects.none_mapped]='  (none yet: run "claude-sync projects select" or "claude-sync projects map <name> <folder>")'
  [projects.excluded_tag]='[excluded]'
  [projects.unmapped_header]='Folders with Claude sessions that are not synced (sessions, size, folder):'
  [projects.nothing_to_select]='Every folder with Claude sessions is already mapped.'
  [projects.ask_select]='Folders to sync: numbers separated by commas, "a" for all, empty for none'
  [projects.mapped]='Mapped %s (%s): %s'
  [projects.usage_map]='usage: claude-sync projects map <name|id> <folder>'
  [projects.usage_unmap]='usage: claude-sync projects unmap <name|id> [folder]'
  [projects.unmapped]='Unmapped %s.'
  [projects.mode_set]='Project mode is now "%s".'
  [projects.usage_mode]='usage: claude-sync projects mode all|selected'
  [projects.usage_exclude]='usage: claude-sync projects exclude|include <name|id>'
  [projects.excluded]='Excluded %s: it is no longer synced from this machine.'
  [projects.included]='Included %s again.'

  [repair.h_scan]='Scanning transcripts for legacy damage'
  [repair.alias]='WSL/Windows path %s will be rewritten to the project root on this machine: %s'
  [repair.foreign_unmapped]='Foreign path %s belongs to no mapped project: map it first ("claude-sync projects map <name> <folder>"); its sessions are repaired without path translation.'
  [repair.ask_alias]='Rewrite those paths? (y/n)'
  [repair.nothing]='Nothing to repair.'
  [repair.h_files]='Transcripts'
  [repair.file_stats]='%s lines: %s from the original, %s re-serialized (%s), %s already compact, %s unparsable kept as is'
  [repair.verify_failed]='%s: check failed (lines %s -> %s, CR %s); left unchanged.'
  [repair.skipped_live]='%s is open in Claude: skipped (close the session and run repair again).'
  [repair.h_junk]='Folders that are not project folders'
  [repair.junk_would_move]='would move projects/%s to %s'
  [repair.ask_junk]='Move projects/%s out of the Claude config into the claude-sync backups? (y/n)'
  [repair.junk_moved]='Moved projects/%s to %s'
  [repair.summary_dry]='Dry run: %s transcripts would be rewritten (%s lines, %s unparsable kept), %s failed checks. Nothing was changed.'
  [repair.summary]='Rewrote %s transcripts (%s lines, %s unparsable kept), %s failed checks. Backups: %s'

  [engine.not_setup]='This machine is not set up yet: run "claude-sync setup".'
  [engine.busy]='Another claude-sync run is in progress; nothing to do.'
  [engine.root_missing]='The root folder on Google Drive is missing or in the trash (ROOT_MISSING); nothing was synced.'
  [engine.summary]='Sync done: %s installed, %s published.'
  [hooks.installed]='Claude Code hooks installed (settings.json was backed up).'
  [hooks.removed]='claude-sync hooks removed.'
  [hooks.usage]='Usage: claude-sync hooks install|uninstall'
  [hook.state_LOGIN_REQUIRED]='claude-sync: Google login required: run "claude-sync login".'
  [hook.state_OFFLINE]='claude-sync: the last sync could not reach Google Drive (offline).'
  [hook.state_ROOT_MISSING]='claude-sync: the Drive root folder is missing or in the trash; nothing is synced.'
  [hook.state_NEEDS_REPAIR]='claude-sync: some sessions need repair: run "claude-sync repair".'
  [hook.never_pulled]='claude-sync: no successful sync yet.'
  [hook.stale]='claude-sync: the last successful sync was at %s, so sessions from other machines may be missing; a sync was started.'
  [hook.behind]='claude-sync: this session is behind %s by %s lines. Run /exit and then "claude-sync sync" before continuing.'
  [hook.live_elsewhere]='claude-sync: this session is open on %s too.'
  [hook.map_here]='claude-sync: this folder may be project %s from another machine. To sync it here: claude-sync projects map %s "%s"'
  [hook.map_waiting]='claude-sync: projects from other machines are waiting for a folder on this machine: run "claude-sync projects map".'
  [hook.guard]='This session was continued on %s (%s). Close this tab and reopen the session (a sync was started).'
  [service.launcher_fallback]='Could not build launcher.exe (blocked, or no .NET compiler): using run-hidden.vbs instead.'
  [service.register_failed]='Could not register the scheduled task (schtasks failed).'
  [service.installed]='claude-sync service installed (runs every %s min).'
  [service.removed]='claude-sync service removed.'
  [service.not_installed]='The claude-sync service is not installed (run "claude-sync service install").'
  [service.no_systemd]='No systemd user instance here (container, or WSL without systemd): the service cannot be installed. Hooks and the wrapper still keep things in sync; "claude-sync doctor" explains.'
  [service.interval]='Runs every %s min.'
  [service.timer_state]='Timer: %s, %s'
  [service.usage]='Usage: claude-sync service install|uninstall|status|kick'
  [service.ask_sudo]='Allow linger (runs while you are logged out) needs permission. Use sudo?'
  [service.linger_failed]='Could not enable linger: the service only runs while you are logged in.'
  [config.set]='%s = %s'
  [config.usage]='Usage: claude-sync config get [key] | config set <key> <value>'
  [config.unknown_key]='Unknown setting: %s'
  [config.bad_value]='Value %s is not allowed for %s.'
  [conflicts.row]='Session %s was forked: the other branch is session %s (%s)'
  [conflicts.memory]='Memory or plan with both-sides changes: %s (the other version is in conflicts/)'
  [conflicts.none]='No conflicts.'
  [conflicts.usage]='Usage: claude-sync conflicts [list|show <session-id>]'
  [conflicts.show]='Session %s
  forked branch: %s
  losing version: %s
  when: %s'
  [conflicts.unknown]='No conflict is recorded for %s.'
  [pending.row_remote]='Project %s from %s (roots there: %s): %s sessions, %s'
  [pending.row_local]='Folder %s has %s Claude sessions (%s) that are not synced.'
  [pending.cand]='  %s) %s %s'
  [pending.none]='Nothing is waiting for a decision.'
  [pending.ask]='Number = use that candidate, p = type a folder, r = add as another root of an existing project, s = skip for now, x = never ask again'
  [pending.ask_path]='Folder on this machine'
  [pending.ask_project]='Project (name or id)'
  [pending.bad]='Not a valid choice.'
  [pending.confirm_nested]='%s overlaps the root %s of another project. Use it anyway?'
  [pending.mnt_warn]='Note: %s is on a Windows drive: WSL and Windows share its working files, and I/O is slower.'
  [pending.reason_path_equivalent]='(same path seen from the other side)'
  [pending.reason_claude_ran_here_name]='(Claude ran here; similar name)'
  [pending.reason_same_git_remote]='(same git remote)'
  [pending.reason_name]='(similar name)'
  [machines.header]='Machines:'
  [machines.row]='  %s (%s), last manifest %s, %s sessions%s'
  [machines.this]=' <- this machine'
  [machines.usage]='Usage: claude-sync machines [list|forget <name>]'
  [machines.not_found]='No other machine is called "%s".'
  [machines.is_self]='This is the machine you are on; it cannot be forgotten.'
  [machines.confirm]='Forget machine "%s"? Its area goes to the Drive trash; %s version(s) that exist nowhere else are copied into the area of this machine first. (y/n)'
  [machines.archive_failed]='Could not copy session %s; nothing was forgotten.'
  [machines.forgotten]='Machine "%s" forgotten (%s version(s) saved here).'
  [engine.offline]='No network (OFFLINE); nothing was synced.'
  [engine.login_required]='Google login required (LOGIN_REQUIRED): run "claude-sync login".'
  [status.state]='State: %s'
  [status.last_run]='Last run: %s (last pull ok: %s, last push ok: %s)'
  [status.counts]='Behind: %s, open elsewhere: %s, conflicts: %s, waiting for a map: %s, older than retention: %s'
  [restore.usage]='Usage: claude-sync restore <session-id>'
  [restore.not_found]='Session %s is not on Google Drive.'
  [restore.exists]='Session %s already exists on this machine.'
  [restore.failed]='Could not restore session %s (see the log).'
  [restore.done]='Restored session %s (modified one day ago, so that Claude does not sweep it at once).'

  [projects.col_sessions]='SESSIONS'
  [projects.col_size]='SIZE'
  [projects.col_cwd]='LAUNCH CWD (newest session)'
  [projects.col_dir]='PROJECT DIR'
)
