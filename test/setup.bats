#!/usr/bin/env bats
# root folder, machine identity, owner file and the setup wizard steps 0-6 (ticket #12), on localfs.
# Two "machines" = two CLAUDE_SYNC_HOME/CS_CLAUDE_DIR pairs sharing one fake Drive.

load test_helper

setup() {
  export CS_SETUP_ONLY_STEPS='lang deps client proxy login root machine' # steps 7-10 have their own tests (setup2.bats)
  cs_test_setup
  cs_load platform version store claude drive root ui setup
  T=$BATS_TEST_TMPDIR
  export CS_DRIVE_BACKEND=localfs CS_LFS_ROOT="$T/drive" CS_CLAUDE_DIR="$T/claudeA"
  mkdir -p "$CS_CLAUDE_DIR" "$CLAUDE_SYNC_HOME"
  printf '{"installed":{"client_id":"cid.apps.googleusercontent.com","client_secret":"sec"}}' >"$T/client.json"
  cs_client_install "$T/client.json"
  cs_token_save "{\"refresh_token\":\"RT\",\"access_token\":\"AT\",\"expires_at\":$(($(date +%s) + 3000))}"
  cs_store_init
}

as_machine_b() {
  export CLAUDE_SYNC_HOME="$T/homeB/.claude-sync" CS_CLAUDE_DIR="$T/claudeB"
  CS_HOME=$CLAUDE_SYNC_HOME
  mkdir -p "$CS_CLAUDE_DIR" "$CLAUDE_SYNC_HOME"
  CS_TOKEN_CACHE=
  cs_client_install "$T/client.json"
  cs_token_save "{\"refresh_token\":\"RT\",\"access_token\":\"AT\",\"expires_at\":$(($(date +%s) + 3000))}"
  cs_store_init
}

@test "root: none -> create with marker and machines/; candidates find it" {
  [ -z "$(cs_root_candidates)" ]
  IFS=$'\t' read -r rid mid < <(cs_root_create 'Claude Sync')
  run cs_root_candidates
  [ "${#lines[@]}" -eq 1 ]
  [[ ${lines[0]} == "$rid"$'\t'"$mid"$'\t'*$'\t''Claude Sync' ]]
  [ "$(drv_get_meta "$mid" | cs_jq -r '.name + " " + .appProperties.csRoot + " " + .appProperties.csSchema')" = '.claude-sync-root 1 1' ]
  [ "$(drv_list_children "$rid" | cs_jq -r 'select(.name == "machines") | .mimeType')" = application/vnd.google-apps.folder ]
}

@test "root: the oldest of several wins; a trashed root is not a candidate" {
  CS_LFS_NOW=2026-01-01T00:00:00.000Z cs_root_create Old >/dev/null
  IFS=$'\t' read -r newer _ < <(CS_LFS_NOW=2026-02-01T00:00:00.000Z cs_root_create Newer)
  [ "$(cs_root_candidates | head -n 1 | cut -f4)" = Old ]
  oldid=$(cs_root_candidates | head -n 1 | cut -f1)
  drv_trash "$oldid" >/dev/null
  [ "$(cs_root_candidates | cut -f1)" = "$newer" ]
}

@test "root check: missing or trashed root is ROOT_MISSING and never recreated" {
  run cs_root_check
  [ "$status" -eq 4 ]
  IFS=$'\t' read -r rid mid < <(cs_root_create R)
  cs_root_use "$rid" "$mid"
  cs_root_check
  drv_trash "$mid" >/dev/null
  run cs_root_check
  [ "$status" -eq 4 ]
  [ "$(cs_root_candidates | wc -l)" -eq 0 ]
}

@test "machine identity: v4 UUID, kept on re-run, default name from hostname" {
  id=$(cs_machine_init)
  [[ $id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
  [ "$(cs_machine_init)" = "$id" ]
  [ -n "$(cs_config_get machine_name)" ]
  [ "$(cs_new_uuid)" != "$(cs_new_uuid)" ]
}

@test "owner file: claim, re-claim by the same install, refuse another install (F12)" {
  id=$(cs_machine_init)
  cs_owner_claim "$id"
  cs_owner_claim "$id"
  cs_owner_check
  ! cs_owner_claim other-machine-id
  printf 'someone-else\n' >"$(cs_owner_file)"
  ! cs_owner_check
}

@test "wizard steps 0-6 with piped answers; a re-run changes nothing (F7)" {
  answers=$'2\nn\n-\nn\n\nPC-A\n'
  run bash -c 'printf "%s" "$1" | bash "$CS_ROOT/bin/claude-sync" setup' _ "$answers"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cs_config_get lang)" = vi ]
  [ "$(cs_config_get machine_name)" = PC-A ]
  [[ $output == *'Đã tạo "Claude Sync"'* ]]
  id=$(cs_config_get machine_id)
  rid=$(cs_config_get root_id)
  [ "$(tr -d '\r\n' <"$(cs_owner_file)")" = "$id" ]
  [ "$(cs_machines_list "$rid" | cut -f1,2)" = "$(printf '%s\tPC-A' "$id")" ]
  run bash -c 'printf "%s" "$1" | bash "$CS_ROOT/bin/claude-sync" setup' _ "$answers"
  [ "$status" -eq 0 ]
  [ "$(cs_config_get machine_id)" = "$id" ]
  [ "$(cs_root_candidates | wc -l)" -eq 1 ]
  [ "$(cs_machines_list "$rid" | wc -l)" -eq 1 ]
}

@test "second machine finds the first machine's root and joins it (Q2 behaviour, F7)" {
  printf '1\nn\n-\nn\n\nWIN\n' | cli setup >/dev/null
  rid=$(cs_config_get root_id)
  as_machine_b
  run bash -c 'printf "1\nn\n-\nn\nWSL\n" | bash "$CS_ROOT/bin/claude-sync" setup'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *'Found the existing claude-sync folder "Claude Sync"'* ]]
  [[ $output == *'WIN (windows)'* || $output == *'WIN (linux)'* || $output == *'WIN (wsl)'* ]]
  [ "$(cs_config_get root_id)" = "$rid" ]
  [ "$(cs_root_candidates | wc -l)" -eq 1 ]
  [ "$(cs_machines_list "$rid" | wc -l)" -eq 2 ]
}

@test "setup --step runs one step; an unknown step is a usage error" {
  run bash -c 'printf "2\n" | bash "$CS_ROOT/bin/claude-sync" setup --step lang'
  [ "$status" -eq 0 ]
  [ "$(cs_config_get lang)" = vi ]
  run cli setup --step nope
  [ "$status" -eq 2 ]
}

@test "client step: a bad path is refused, a valid JSON is installed" {
  rm -f "$CLAUDE_SYNC_HOME/oauth-client.json"
  printf '{"x":1}' >"$T/bad.json"
  run bash -c 'printf "%s\n%s\n" "$1" "$2" | bash "$CS_ROOT/bin/claude-sync" setup --step client' _ "$T/bad.json" "$T/client.json"
  [ "$status" -eq 0 ]
  [[ $output == *'is not a Google OAuth client JSON'* ]]
  [ -f "$CLAUDE_SYNC_HOME/oauth-client.json" ]
}

@test "proxy step stores the answer and '-' clears it" {
  printf 'http://proxy.local:3128\n' | cs_setup_step_proxy >/dev/null 2>&1
  [ "$(cs_config_get proxy)" = http://proxy.local:3128 ]
  printf -- '-\n' | cs_setup_step_proxy >/dev/null 2>&1
  [ "$(cs_config_get proxy)" = '' ]
}

@test "folder show: account, folder, link and machines; missing root is reported" {
  printf '1\nn\n-\nn\nMy Sync\nPC-A\n' | cli setup >/dev/null
  run cli folder show
  [ "$status" -eq 0 ]
  [[ $output == *'Folder:  My Sync'* ]]
  [[ $output == *'https://drive.google.com/drive/folders/'* ]]
  [[ $output == *'PC-A'* ]]
  drv_trash "$(cs_config_get root_id)" >/dev/null
  run cli folder show
  [ "$status" -eq 1 ]
  [[ $output == *ROOT_MISSING* ]]
}
