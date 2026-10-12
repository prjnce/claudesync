#!/usr/bin/env bats
# `claude-sync google`: guide, install of the user's own OAuth client, publishing status (docs/SPEC §16.1).

load test_helper

setup() {
  cs_test_setup
  T=$BATS_TEST_TMPDIR
  mkdir -p "$CLAUDE_SYNC_HOME"
  printf '{"installed":{"client_id":"123456789012-abc.apps.googleusercontent.com","client_secret":"sec","project_id":"my-proj-1"}}' >"$T/client.json"
}

cs() { bash "$CS_ROOT/bin/claude-sync" "$@"; }

@test "guide lists the steps: Drive API, Publish, the one scope, Desktop app, download at once" {
  run cs google guide
  [ "$status" -eq 0 ]
  [[ $output == *'Google Drive API'* ]]
  [[ $output == *'PUBLISH APP'* ]]
  [[ $output == *'auth/drive.file'* ]]
  [[ $output == *'Desktop app'* ]]
  [[ $output == *'https://transflow.asia/en/privacy'* && $output == *'transflow.asia'* ]]
  [[ $output == *'DOWNLOAD THE JSON NOW'* ]]
  CLAUDE_SYNC_LANG=vi run cs google guide
  [[ $output == *'TẢI JSON NGAY'* ]]
}

@test "status without a client points to the guide (exit 1)" {
  run cs google status
  [ "$status" -eq 1 ]
  [[ $output == *'No OAuth client yet'* ]]
  [[ $output == *'google guide'* ]]
}

@test "client <file> installs a valid JSON and says to sign in next; a bad file is refused" {
  run cs google client "$T/client.json"
  [ "$status" -eq 0 ]
  [ -s "$CLAUDE_SYNC_HOME/oauth-client.json" ]
  [[ $output == *'claude-sync login'* ]]
  printf '{"nothing":1}' >"$T/bad.json"
  run cs google client "$T/bad.json"
  [ "$status" -ne 0 ]
}

@test "status shows the client, the project and whether the app was published at the last sign-in" {
  cs google client "$T/client.json" >/dev/null
  run cs google status
  [[ $output == *'123456789012'*'my-proj-1'* ]]
  [[ $output == *'Not signed in'* ]]
  [[ $output == *'unknown'* ]]
  mkdir -p "$CLAUDE_SYNC_HOME/state"
  printf 'testing\n' >"$CLAUDE_SYNC_HOME/state/oauth_mode"
  run cs google status
  [[ $output == *'still in Testing'* ]]
  printf 'production\n' >"$CLAUDE_SYNC_HOME/state/oauth_mode"
  run cs google status
  [[ $output == *'published'* ]]
}

@test "a new client resets the remembered publishing status" {
  cs google client "$T/client.json" >/dev/null
  mkdir -p "$CLAUDE_SYNC_HOME/state"
  printf 'testing\n' >"$CLAUDE_SYNC_HOME/state/oauth_mode"
  cs google client "$T/client.json" >/dev/null
  [ ! -e "$CLAUDE_SYNC_HOME/state/oauth_mode" ]
}

@test "client without a file: the Client ID and secret are typed on the screen, the secret is not echoed, bad values are refused" {
  run bash -c 'printf "123456789012-abc.apps.googleusercontent.com
GOCSPX-typed-secret
" | bash "$CS_ROOT/bin/claude-sync" google client'
  [ "$status" -eq 0 ]
  [[ $output != *'GOCSPX-typed-secret'* ]]
  [ "$(jq -r .installed.client_id "$CLAUDE_SYNC_HOME/oauth-client.json" | tr -d '\r')" = 123456789012-abc.apps.googleusercontent.com ]
  [ "$(jq -r .installed.client_secret "$CLAUDE_SYNC_HOME/oauth-client.json" | tr -d '\r')" = GOCSPX-typed-secret ]
  rm "$CLAUDE_SYNC_HOME/oauth-client.json"
  run bash -c 'printf "not-an-id
secret
" | bash "$CS_ROOT/bin/claude-sync" google client'
  [ "$status" -ne 0 ]
  [ ! -e "$CLAUDE_SYNC_HOME/oauth-client.json" ]
  run bash -c 'printf "123456789012-abc.apps.googleusercontent.com

" | bash "$CS_ROOT/bin/claude-sync" google client'
  [ "$status" -ne 0 ]
  run cs google status
  [[ $output == *'No OAuth client yet'* ]]
}

@test "setup: an empty answer to the JSON path question lets you type the Client ID and secret" {
  mkdir -p "$T/claude" "$T/drive"
  run bash -c 'printf "1
n
" | CS_DRIVE_BACKEND=localfs CS_LFS_ROOT="$1/drive" CS_CLAUDE_DIR="$1/claude" bash "$CS_ROOT/bin/claude-sync" setup --step client' _ "$T"
  [ "$status" -ne 0 ]
  run bash -c 'printf "
123456789012-abc.apps.googleusercontent.com
GOCSPX-x
" | CS_DRIVE_BACKEND=localfs CS_LFS_ROOT="$1/drive" CS_CLAUDE_DIR="$1/claude" bash "$CS_ROOT/bin/claude-sync" setup --step client' _ "$T"
  [ "$status" -eq 0 ]
  [ -s "$CLAUDE_SYNC_HOME/oauth-client.json" ]
}
