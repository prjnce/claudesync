#!/usr/bin/env bats
# auth: PKCE, query parsing, client JSON, token storage, exchange/refresh/revoke, loopback listener and a
# full non-interactive login (ticket #10). Token endpoints are file:// mocks; nothing reaches Google.

load test_helper

setup() {
  cs_test_setup
  cs_load platform version auth
  T=$BATS_TEST_TMPDIR
  mkdir -p "$CLAUDE_SYNC_HOME"
  printf '{"installed":{"client_id":"cid.apps.googleusercontent.com","client_secret":"sec","redirect_uris":["http://localhost"]}}' >"$T/client.json"
}

mock() { # mock NAME JSON -> file:// URL serving JSON
  printf '%s' "$2" >"$T/$1.json"
  if cs_is_windows; then printf 'file:///%s\n' "$(cygpath -m "$T/$1.json")"; else printf 'file://%s\n' "$T/$1.json"; fi
}

@test "PKCE S256 matches the RFC 7636 appendix B vector" {
  [ "$(cs_pkce_challenge dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk)" = E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM ]
}

@test "random tokens are base64url without padding" {
  t=$(cs_random_token 48)
  [[ $t =~ ^[A-Za-z0-9_-]{64}$ ]]
  [ "$t" != "$(cs_random_token 48)" ]
}

@test "query parsing decodes %XX and +, and matches whole keys only" {
  q='xcode=no&code=4%2F0Ab_c+d&state=s%3D1&empty='
  [ "$(cs_qs_get "$q" code)" = '4/0Ab_c d' ]
  [ "$(cs_qs_get "$q" state)" = 's=1' ]
  [ "$(cs_qs_get "$q" empty)" = '' ]
  [ "$(cs_qs_get "$q" missing)" = '' ]
}

@test "client JSON: install validates and copies with mode 600; load reads id and secret" {
  run cs_client_load
  [ "$status" -eq 3 ]
  printf '{"foo":1}' >"$T/bad.json"
  run cs_client_install "$T/bad.json"
  [ "$status" -eq 1 ]
  cs_client_install "$T/client.json"
  cs_client_load
  [ "$CS_CLIENT_ID" = cid.apps.googleusercontent.com ]
  [ "$CS_CLIENT_SECRET" = sec ]
  cs_is_windows || [ "$(stat -c %a "$CLAUDE_SYNC_HOME/oauth-client.json")" = 600 ]
}

@test "auth URL carries PKCE, state, offline access, consent and the drive.file scope" {
  cs_client_install "$T/client.json"
  cs_client_load
  u=$(cs_auth_url 'http://127.0.0.1:5555/' CHAL ST)
  [[ $u == https://accounts.google.com/o/oauth2/v2/auth?* ]]
  for p in 'redirect_uri=http%3A%2F%2F127.0.0.1%3A5555%2F' 'code_challenge=CHAL' 'code_challenge_method=S256' 'state=ST' \
    'access_type=offline' 'prompt=consent' 'scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file' 'response_type=code'; do
    [[ $u == *"$p"* ]] || { echo "missing $p"; return 1; }
  done
}

@test "token storage round trip; Windows keeps it DPAPI-encrypted, Linux mode 600" {
  cs_token_save '{"refresh_token":"RT-secret","access_token":"AT","expires_at":1}'
  f=$(cs_token_file)
  ! grep -q RT-secret "$f"
  CS_TOKEN_CACHE=
  [ "$(cs_token_load | jq -r .refresh_token | tr -d '\r')" = RT-secret ]
  if cs_is_windows; then
    [[ $f == *.dpapi ]]
  else
    [ "$(stat -c %a "$f")" = 600 ]
  fi
  cs_token_forget
  run cs_token_load
  [ "$status" -eq 3 ]
}

@test "exchange: stores the token; Testing-mode warning; refusals without refresh token or Drive scope" {
  cs_client_install "$T/client.json"
  CS_OAUTH_TOKEN_EP=$(mock ok '{"access_token":"AT1","refresh_token":"RT1","expires_in":3599,"scope":"https://www.googleapis.com/auth/drive.file","refresh_token_expires_in":604799}')
  run cs_oauth_exchange code verifier http://127.0.0.1:1/
  [ "$status" -eq 0 ]
  [[ $output == *Testing* ]]
  CS_TOKEN_CACHE=
  [ "$(cs_token_load | jq -r .refresh_token | tr -d '\r')" = RT1 ]
  CS_OAUTH_TOKEN_EP=$(mock norefresh '{"access_token":"AT","expires_in":3599,"scope":"https://www.googleapis.com/auth/drive.file"}')
  run cs_oauth_exchange code verifier http://127.0.0.1:1/
  [ "$status" -eq 3 ]
  CS_OAUTH_TOKEN_EP=$(mock noscope '{"access_token":"AT","refresh_token":"R","expires_in":3599,"scope":"openid"}')
  run cs_oauth_exchange code verifier http://127.0.0.1:1/
  [ "$status" -eq 3 ]
  CS_OAUTH_TOKEN_EP=$(mock err '{"error":"invalid_grant","error_description":"Bad Request"}')
  run cs_oauth_exchange code verifier http://127.0.0.1:1/
  [ "$status" -eq 3 ]
}

@test "access token: valid one is reused without network; expired one is refreshed and the refresh token kept" {
  cs_client_install "$T/client.json"
  now=$(date +%s)
  cs_token_save "{\"refresh_token\":\"RT\",\"access_token\":\"FRESH\",\"expires_at\":$((now + 3000))}"
  CS_OAUTH_TOKEN_EP=file:///nonexistent
  [ "$(cs_access_token)" = FRESH ]
  cs_token_save "{\"refresh_token\":\"RT\",\"access_token\":\"OLD\",\"expires_at\":$((now - 10))}"
  CS_OAUTH_TOKEN_EP=$(mock refresh '{"access_token":"NEW","expires_in":3599,"scope":"https://www.googleapis.com/auth/drive.file"}')
  [ "$(cs_access_token)" = NEW ]
  CS_TOKEN_CACHE=
  [ "$(cs_token_load | jq -r '.refresh_token + " " + .access_token' | tr -d '\r')" = 'RT NEW' ]
}

@test "access token: revoked refresh token means login required (F6), no endless retry" {
  cs_client_install "$T/client.json"
  cs_token_save '{"refresh_token":"RT","access_token":"OLD","expires_at":1}'
  CS_OAUTH_TOKEN_EP=$(mock revoked '{"error":"invalid_grant","error_description":"Token has been expired or revoked."}')
  run cs_access_token
  [ "$status" -eq 3 ]
  run cs_access_token
  [ "$status" -eq 3 ]
}

@test "listener: answers 404 to stray requests and reports the OAuth callback query" {
  out="$T/listener.out"
  CS_LOGIN_TIMEOUT=30 cs_listener_start "$out"
  [[ $CS_PORT =~ ^[0-9]+$ ]]
  code=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "http://127.0.0.1:$CS_PORT/favicon.ico")
  [ "$code" = 404 ]
  body=$(curl -s --noproxy '*' "http://127.0.0.1:$CS_PORT/?state=S1&code=4%2Fabc")
  [[ $body == *claude-sync* ]]
  for _ in $(seq 1 50); do grep -q '^QUERY' "$out" && break; sleep 0.1; done
  [ "$(sed -n 's/^QUERY //p' "$out" | tr -d '\r')" = 'state=S1&code=4%2Fabc' ]
}

@test "full login without a browser: callback hits the loopback listener, token is stored, logout revokes" {
  cs_client_install "$T/client.json"
  export CS_OAUTH_TOKEN_EP CS_OAUTH_REVOKE_EP CS_NO_BROWSER=1 CS_LOGIN_TIMEOUT=60
  CS_OAUTH_TOKEN_EP=$(mock tok '{"access_token":"AT9","refresh_token":"RT9","expires_in":3599,"scope":"https://www.googleapis.com/auth/drive.file"}')
  CS_OAUTH_REVOKE_EP=$(mock revoke '{}')
  # The "browser": wait for the printed consent URL, then call the redirect URI with code and state.
  (
    for _ in $(seq 1 300); do grep -q 'state=' "$T/login.out" 2>/dev/null && break; sleep 0.1; done
    url=$(grep -o 'https://accounts.google.com/[^ ]*' "$T/login.out" | head -n 1)
    redirect=$(cs_qs_get "${url#*\?}" redirect_uri)
    state=$(cs_qs_get "${url#*\?}" state)
    curl -s --noproxy '*' "${redirect}?state=${state}&code=4%2Fxyz" >/dev/null
  ) 3>&- &
  helper=$!
  run bash -c 'bash "$CS_ROOT/bin/claude-sync" login </dev/null >"$1" 2>&1; echo "rc=$?" >>"$1"' _ "$T/login.out"
  wait "$helper"
  cat "$T/login.out"
  grep -q '^rc=0$' "$T/login.out"
  grep -q 'Signed in' "$T/login.out"
  CS_TOKEN_CACHE=
  [ "$(cs_token_load | jq -r .refresh_token | tr -d '\r')" = RT9 ]
  run cli logout
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_SYNC_HOME/token.json" ] && [ ! -e "$CLAUDE_SYNC_HOME/token.dpapi" ]
}

@test "login with a wrong state is refused" {
  cs_client_install "$T/client.json"
  export CS_NO_BROWSER=1 CS_LOGIN_TIMEOUT=60
  (
    for _ in $(seq 1 300); do grep -q 'state=' "$T/login.out" 2>/dev/null && break; sleep 0.1; done
    url=$(grep -o 'https://accounts.google.com/[^ ]*' "$T/login.out" | head -n 1)
    redirect=$(cs_qs_get "${url#*\?}" redirect_uri)
    curl -s --noproxy '*' "${redirect}?state=forged&code=x" >/dev/null
  ) 3>&- &
  helper=$!
  run bash -c 'bash "$CS_ROOT/bin/claude-sync" login </dev/null >"$1" 2>&1; echo "rc=$?" >>"$1"' _ "$T/login.out"
  wait "$helper"
  grep -q '^rc=3$' "$T/login.out"
  grep -q 'state mismatch' "$T/login.out"
}

@test "nothing secret reaches the log" {
  mkdir -p "$CLAUDE_SYNC_HOME/logs"
  cs_client_install "$T/client.json"
  CS_OAUTH_TOKEN_EP=$(mock ok '{"access_token":"AT-LEAK","refresh_token":"RT-LEAK","expires_in":3599,"scope":"https://www.googleapis.com/auth/drive.file"}')
  cs_oauth_exchange CODE-LEAK verifier http://127.0.0.1:1/
  CS_OAUTH_TOKEN_EP=$(mock bad '{"error":"invalid_grant"}')
  cs_token_save '{"refresh_token":"RT-LEAK","access_token":"x","expires_at":1}'
  cs_access_token || true
  ! grep -qE 'LEAK|sec\b' "$CLAUDE_SYNC_HOME/logs/claude-sync.log"
}
