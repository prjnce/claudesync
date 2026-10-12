#!/usr/bin/env bats
# Setup steps 7-10, doctor, uninstall and the unsupported-layout stop (ticket #29), on localfs.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  cs_test_setup
  T=$BATS_TEST_TMPDIR
  export CS_DRIVE_BACKEND=localfs CS_LFS_ROOT="$T/drive" CS_CLAUDE_DIR="$T/claude" CS_SCHED_KIND=linux CLAUDE_SYNC_LANG=en
  export USER=tester
  mkdir -p "$CS_CLAUDE_DIR/projects" "$T/drive" "$T/stubs"
  CALLS="$T/calls.log"
  : >"$CALLS"
  export CALLS
  printf '#!/usr/bin/env bash\necho "systemctl $*" >>"$CALLS"\n[[ $2 == show-environment ]] && exit 0\n[[ $2 == is-active ]] && echo active\nexit 0\n' >"$T/stubs/systemctl"
  printf '#!/usr/bin/env bash\necho "loginctl $*" >>"$CALLS"\nexit 0\n' >"$T/stubs/loginctl"
  chmod +x "$T/stubs"/*
  export PATH="$T/stubs:$PATH"
  printf '{"installed":{"client_id":"cid.apps.googleusercontent.com","client_secret":"sec"}}' >"$T/client.json"
  mkdir -p "$CLAUDE_SYNC_HOME"
  # the login of steps 0-6 is not what is tested here: a client file and a token are already in place
  bash -c 'source "$CS_ROOT/lib/core.sh"; cs_bootstrap; for m in platform version store claude drive; do source "$CS_ROOT/lib/$m.sh"; done
    cs_client_install "$1"; cs_token_save "{\"refresh_token\":\"RT\",\"access_token\":\"AT\",\"expires_at\":$(($(date +%s) + 3000))}"' _ "$T/client.json"
}

cs() { bash "$CS_ROOT/bin/claude-sync" "$@"; }

# a transcript with CRLF line ends: Claude cannot load it as it is
crlf_session() {
  mkdir -p "$CS_CLAUDE_DIR/projects/slug-a"
  printf '{"type":"user","cwd":"/x","n":1}\r\n{"type":"user","cwd":"/x","n":2}\r\n' >"$CS_CLAUDE_DIR/projects/slug-a/0b7a1c2e-1111-4222-8333-444455556666.jsonl"
}

@test "step 7: nothing to repair says so; a declined repair blocks those sessions; an accepted one repairs and frees them" {
  run bash -c 'printf "" | bash "$CS_ROOT/bin/claude-sync" setup --step repair'
  [ "$status" -eq 0 ]
  [[ $output == *'can be loaded as they are'* ]]
  crlf_session
  run bash -c 'printf "n\n" | bash "$CS_ROOT/bin/claude-sync" setup --step repair'
  [ "$status" -eq 0 ]
  [[ $output == *'stay blocked'* ]]
  grep -q 'needs_repair' "$CLAUDE_SYNC_HOME/state/sessions.tsv"
  run bash -c 'printf "y\n" | bash "$CS_ROOT/bin/claude-sync" setup --step repair'
  [ "$status" -eq 0 ]
  ! grep -q "$(printf '\r')" "$CS_CLAUDE_DIR/projects/slug-a/0b7a1c2e-1111-4222-8333-444455556666.jsonl"
  ! grep -q 'needs_repair' "$CLAUDE_SYNC_HOME/state/sessions.tsv"
}

@test "step 9: declining the retention change leaves settings alone; accepting writes 3650 after a backup; 3650 needs no question" {
  run bash -c 'printf "n\n" | bash "$CS_ROOT/bin/claude-sync" setup --step retention'
  [ "$status" -eq 0 ]
  [[ $output == *'Kept at 30 days'* ]]
  [ ! -e "$CS_CLAUDE_DIR/settings.json" ] || ! grep -q cleanupPeriodDays "$CS_CLAUDE_DIR/settings.json"
  printf '{"theme":"dark"}\n' >"$CS_CLAUDE_DIR/settings.json"
  run bash -c 'printf "y\n" | bash "$CS_ROOT/bin/claude-sync" setup --step retention'
  [ "$status" -eq 0 ]
  [ "$(jq -r .cleanupPeriodDays "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = 3650 ]
  [ "$(jq -r .theme "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = dark ]
  [ -n "$(ls "$CLAUDE_SYNC_HOME/backups" | grep '^settings.json')" ]
  run bash -c 'printf "" | bash "$CS_ROOT/bin/claude-sync" setup --step retention'
  [[ $output == *'fine'* ]]
}

@test "the whole wizard: service, hooks, doctor and the first sync; running it again changes nothing the user did not choose again" {
  answers=$(printf '1\nn\n-\nn\nMy Sync\nPC-A\ny\n5\n')
  run bash -c 'printf "%s\n" "$1" | bash "$CS_ROOT/bin/claude-sync" setup' _ "$answers"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *'plain text and may contain secrets'* ]]
  [[ $output == *'First sync'* ]]
  [ -f "$HOME/.config/systemd/user/claude-sync.timer" ]
  grep -q 'enable --now claude-sync.timer' "$CALLS"
  [ "$(jq '[.hooks[][]] | length' "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" -eq 3 ]
  [ "$(jq -r .cleanupPeriodDays "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = 3650 ]
  [ "$(jq -r .state "$CLAUDE_SYNC_HOME/state/status.json" | tr -d '\r')" = OK ]
  id1=$(grep '^machine_id=' "$CLAUDE_SYNC_HOME/config")
  root1=$(grep '^root_id=' "$CLAUDE_SYNC_HOME/config")
  # a second run: same machine, same root, no duplicated hooks or units
  run bash -c 'printf "%s\n" "$1" | bash "$CS_ROOT/bin/claude-sync" setup' _ "$(printf '1\nn\n-\nn\ny\nPC-A\ny\n5\n')"
  [ "$status" -eq 0 ]
  [ "$(grep '^machine_id=' "$CLAUDE_SYNC_HOME/config")" = "$id1" ]
  [ "$(grep '^root_id=' "$CLAUDE_SYNC_HOME/config")" = "$root1" ]
  [ "$(jq '[.hooks[][]] | length' "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" -eq 3 ]
  [ "$(find "$T/drive/objects" -name meta.json | xargs grep -l '"csRoot"' | wc -l)" -eq 1 ]
}

@test "doctor: a set-up machine reports each part; a missing service or hook is a WARN with exit 1" {
  printf '1\nn\n-\nn\nMy Sync\nPC-A\ny\n5\n' | cs setup >/dev/null
  run cs doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *'systemd timer claude-sync.timer is active'* ]]
  [[ $output == *'Claude Code hooks are installed'* ]]
  [[ $output == *'Drive root folder is reachable'* ]]
  cs hooks uninstall >/dev/null
  run cs doctor
  [ "$status" -eq 1 ]
  [[ $output == *'WARN'*'hooks are not installed'* ]]
}

@test "uninstall removes service and hooks and keeps Drive and ~/.claude; --purge deletes ~/.claude-sync; setup again takes the same machine back" {
  printf '1\nn\n-\nn\nMy Sync\nPC-A\ny\n5\n' | cs setup >/dev/null
  id1=$(grep '^machine_id=' "$CLAUDE_SYNC_HOME/config")
  objects=$(find "$T/drive/objects" -name meta.json | wc -l)
  run cs uninstall --yes
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.config/systemd/user/claude-sync.timer" ]
  ! grep -q '#claude-sync' "$CS_CLAUDE_DIR/settings.json"
  [ -d "$CLAUDE_SYNC_HOME" ]
  run cs uninstall --purge --yes
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_SYNC_HOME" ]
  [ -s "$CS_CLAUDE_DIR/.claude-sync-owner" ]
  [ "$(find "$T/drive/objects" -name meta.json | wc -l)" -ge "$objects" ]
  # the wizard again (client and token are re-created by the test setup)
  mkdir -p "$CLAUDE_SYNC_HOME"
  bash -c 'source "$CS_ROOT/lib/core.sh"; cs_bootstrap; for m in platform version store claude drive; do source "$CS_ROOT/lib/$m.sh"; done
    cs_client_install "$1"; cs_token_save "{\"refresh_token\":\"RT\",\"access_token\":\"AT\",\"expires_at\":$(($(date +%s) + 3000))}"' _ "$T/client.json"
  run bash -c 'printf "1\nn\n-\nn\ny\nPC-A\ny\n5\n" | bash "$CS_ROOT/bin/claude-sync" setup'
  [ "$status" -eq 0 ]
  [[ $output == *'reusing it'* ]]
  [ "$(grep '^machine_id=' "$CLAUDE_SYNC_HOME/config")" = "$id1" ]
}

@test "an unknown Claude layout stops the engine before it writes anything (R1)" {
  printf '1\nn\n-\nn\nMy Sync\nPC-A\n' | CS_SETUP_ONLY_STEPS='lang deps client proxy login root machine' cs setup >/dev/null
  mkdir -p "$CS_CLAUDE_DIR/projects/slug-a"
  printf 'x\n' >"$CS_CLAUDE_DIR/projects/slug-a/0b7a1c2e.compact.tmp.1"
  n=$(find "$T/drive/objects" -name meta.json | wc -l)
  run cs run
  [ "$status" -eq 1 ]
  [[ $output == *'unsupported Claude layout'* ]]
  [ "$(find "$T/drive/objects" -name meta.json | wc -l)" -eq "$n" ]
  run cs doctor
  [ "$status" -eq 1 ]
  [[ $output == *'FAIL'*'compaction temp file'* ]]
  rm "$CS_CLAUDE_DIR/projects/slug-a/0b7a1c2e.compact.tmp.1"
  CLAUDE_CODE_HOVER_REST=1 run cs run
  [ "$status" -eq 1 ]
}

# jsoncwd PATH: PATH as Claude writes it into a transcript on this host (JSON-escaped)
jsoncwd() {
  local p=$1
  if command -v cygpath >/dev/null 2>&1; then p=$(cygpath -w "$p"); fi
  printf '%s' "${p//\\/\\\\}"
}

# a session that was started in a folder that is not a project yet
unmapped_session() {
  mkdir -p "$T/work/X" "$CS_CLAUDE_DIR/projects/slug-x"
  printf '{"type":"user","cwd":"%s","n":1}
' "$(jsoncwd "$T/work/X")" >"$CS_CLAUDE_DIR/projects/slug-x/0b7a1c2e-1111-4222-8333-444455556666.jsonl"
}

@test "step 8: one numbered list of everything that uses Claude here; Enter = all, numbers choose, the rest is left out" {
  printf '1
n
-
n
My Sync
PC-A
' | CS_SETUP_ONLY_STEPS='lang deps client proxy login root machine' bash "$CS_ROOT/bin/claude-sync" setup >/dev/null
  mkdir -p "$T/work/P0"
  mkdir -p "$CS_CLAUDE_DIR/projects/slug-p0"
  printf '{"type":"user","cwd":"%s","n":1}
' "$(jsoncwd "$T/work/P0")" >"$CS_CLAUDE_DIR/projects/slug-p0/0b7a1c2e-1111-4222-8333-444455556661.jsonl"
  bash "$CS_ROOT/bin/claude-sync" projects map P0 "$T/work/P0" >/dev/null
  unmapped_session
  # Enter: everything
  run bash -c 'printf "
" | bash "$CS_ROOT/bin/claude-sync" setup --step projects'
  [ "$status" -eq 0 ]
  [[ $output == *'Projects that use Claude on this machine:'* ]]
  [[ $output == *'1. P0'* && $output == *'2. X'* ]]
  [[ $output == *'Choose the projects to sync from this machine'* ]]
  [ "$(grep -vc '^#' "$CLAUDE_SYNC_HOME/state/projects.tsv")" -eq 2 ]
  [ "$(cut -f6 "$CLAUDE_SYNC_HOME/state/projects.tsv" | grep -v '^enabled' | sort -u)" = 1 ]
  grep -qx 'mode=all' "$CLAUDE_SYNC_HOME/config"
  # a wrong number is refused and asked again; then only P0 is chosen: X is not added, mode selected
  bash "$CS_ROOT/bin/claude-sync" projects unmap X >/dev/null
  run bash -c 'printf "9
1
" | bash "$CS_ROOT/bin/claude-sync" setup --step projects'
  [ "$status" -eq 0 ]
  [[ $output == *'Not a valid choice'* ]]
  [ "$(grep -vc '^#' "$CLAUDE_SYNC_HOME/state/projects.tsv")" -eq 1 ]
  grep -qx 'mode=selected' "$CLAUDE_SYNC_HOME/config"
  # choosing only X leaves P0 out (disabled) and maps X
  run bash -c 'printf "2
" | bash "$CS_ROOT/bin/claude-sync" setup --step projects'
  [ "$status" -eq 0 ]
  [ "$(grep -vc '^#' "$CLAUDE_SYNC_HOME/state/projects.tsv")" -eq 2 ]
  [ "$(awk -F'	' '$3 == "P0" { print $6 }' "$CLAUDE_SYNC_HOME/state/projects.tsv")" = 0 ]
}

@test "step 9: even when the value is fine it asks; a new value is written after a backup" {
  printf '{"cleanupPeriodDays":3650}
' >"$CS_CLAUDE_DIR/settings.json"
  run bash -c 'printf "y
" | bash "$CS_ROOT/bin/claude-sync" setup --step retention'
  [[ $output == *'Keep it at 3650 days?'* ]]
  [ "$(jq -r .cleanupPeriodDays "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = 3650 ]
  run bash -c 'printf "n
1000
" | bash "$CS_ROOT/bin/claude-sync" setup --step retention'
  [ "$status" -eq 0 ]
  [ "$(jq -r .cleanupPeriodDays "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = 1000 ]
  [ -n "$(ls "$CLAUDE_SYNC_HOME/backups" | grep '^settings.json')" ]
}
