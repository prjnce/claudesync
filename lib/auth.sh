# shellcheck shell=bash
# auth: Google OAuth for an installed (Desktop) client — PKCE S256 + state + loopback 127.0.0.1 on an
# OS-assigned port, paste-the-URL fallback, token storage (DPAPI on Windows, mode 600 elsewhere),
# refresh under a lock, revoke (SPEC §2, §15.1, §15.2). Code: docs/prototypes/cs_gdrive_proto.sh.
# Never log tokens, codes or secrets. Requires lib/core.sh, lib/platform.sh, lib/version.sh (cs_jq).

[[ -n ${CS_AUTH_LOADED:-} ]] && return 0
CS_AUTH_LOADED=1

CS_OAUTH_AUTH_EP=${CS_OAUTH_AUTH_EP:-https://accounts.google.com/o/oauth2/v2/auth}
CS_OAUTH_TOKEN_EP=${CS_OAUTH_TOKEN_EP:-https://oauth2.googleapis.com/token}
CS_OAUTH_REVOKE_EP=${CS_OAUTH_REVOKE_EP:-https://oauth2.googleapis.com/revoke}
CS_OAUTH_SCOPE=https://www.googleapis.com/auth/drive.file
CS_LOGIN_TIMEOUT=${CS_LOGIN_TIMEOUT:-300}

cs_b64url() {
  base64 -w0 | tr '+/' '-_' | tr -d '='
}

cs_urlenc() {
  jq -rn --arg v "$1" '$v | @uri' | tr -d '\r'
}

# cs_qs_get QUERY KEY: percent-decoded value of KEY in an application/x-www-form-urlencoded QUERY.
cs_qs_get() {
  local q=$1 k=$2 pair v
  local -a pairs
  IFS='&' read -r -a pairs <<<"$q"
  for pair in "${pairs[@]}"; do
    if [[ $pair == "$k="* ]]; then
      v=${pair#*=}
      v=${v//+/ }
      printf '%b\n' "${v//%/\\x}"
      return 0
    fi
  done
  printf '\n'
}

# cs_pkce_challenge VERIFIER -> base64url(sha256(VERIFIER)) (RFC 7636 S256).
cs_pkce_challenge() {
  printf '%s' "$1" | openssl dgst -sha256 -binary | cs_b64url
}

cs_random_token() {
  head -c "${1:-32}" /dev/urandom | cs_b64url
}

# --- OAuth client JSON ------------------------------------------------------------------------------------

cs_client_file() {
  printf '%s\n' "$CS_HOME/oauth-client.json"
}

# cs_client_install FILE: validate a downloaded client JSON and copy it to ~/.claude-sync (mode 600).
cs_client_install() {
  local src=$1 dst
  jq -e '(.installed // .web) | .client_id and .client_secret' "$src" >/dev/null 2>&1 ||
    cs_die_t "$CS_EXIT_ERROR" auth.bad_client "$src"
  dst=$(cs_client_file)
  mkdir -p -- "${dst%/*}"
  cs_write_atomic "$dst" cat -- "$src"
  chmod 600 -- "$dst" 2>/dev/null || true
}

# cs_client_load: sets CS_CLIENT_ID and CS_CLIENT_SECRET.
cs_client_load() {
  local f
  f=$(cs_client_file)
  [[ -f $f ]] || cs_die_t "$CS_EXIT_LOGIN" auth.no_client "$f"
  CS_CLIENT_ID=$(jq -r '(.installed // .web).client_id // empty' "$f" | tr -d '\r')
  CS_CLIENT_SECRET=$(jq -r '(.installed // .web).client_secret // empty' "$f" | tr -d '\r')
  [[ -n $CS_CLIENT_ID && -n $CS_CLIENT_SECRET ]] || cs_die_t "$CS_EXIT_ERROR" auth.bad_client "$f"
}

# --- token storage ----------------------------------------------------------------------------------------

cs_token_file() {
  if [[ $CS_OS == windows && ${CS_TOKEN_PLAIN:-0} != 1 ]]; then
    printf '%s\n' "$CS_HOME/token.dpapi"
  else
    printf '%s\n' "$CS_HOME/token.json"
  fi
}

# DPAPI (CurrentUser) through PowerShell; the secret travels in an environment variable, never in argv.
cs_dpapi_protect() {
  CS_DP_IN=$1 cs_ps dpapi-protect '
$s = ConvertTo-SecureString -String $env:CS_DP_IN -AsPlainText -Force
[Console]::Out.Write((ConvertFrom-SecureString -SecureString $s))'
}

cs_dpapi_unprotect() {
  CS_DP_IN=$1 cs_ps dpapi-unprotect '
$s = ConvertTo-SecureString -String $env:CS_DP_IN
$b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
try { [Console]::Out.Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }'
}

# cs_token_save JSON: persist the token object (refresh_token, access_token, expires_at, scope).
cs_token_save() {
  local f
  f=$(cs_token_file)
  mkdir -p -- "$CS_HOME"
  [[ $CS_OS == linux ]] && chmod 700 -- "$CS_HOME"
  if [[ $f == *.dpapi ]]; then
    local enc
    enc=$(cs_dpapi_protect "$1") || return 1
    [[ -n $enc ]] || return 1
    cs_write_atomic "$f" printf '%s\n' "$enc"
  else
    (umask 077 && cs_write_atomic "$f" printf '%s\n' "$1")
    chmod 600 -- "$f"
  fi
  CS_TOKEN_CACHE=$1
}

# cs_token_load: token JSON on stdout (cached for the rest of the process); rc 3 if there is none.
cs_token_load() {
  if [[ -n ${CS_TOKEN_CACHE:-} ]]; then
    printf '%s\n' "$CS_TOKEN_CACHE"
    return 0
  fi
  local f j
  f=$(cs_token_file)
  [[ -s $f ]] || return "$CS_EXIT_LOGIN"
  if [[ $f == *.dpapi ]]; then
    j=$(cs_dpapi_unprotect "$(tr -d '\r\n' <"$f")") || return "$CS_EXIT_LOGIN"
  else
    j=$(<"$f")
  fi
  cs_jq -e '.refresh_token' <<<"$j" >/dev/null 2>&1 || return "$CS_EXIT_LOGIN"
  CS_TOKEN_CACHE=$j
  printf '%s\n' "$j"
}

cs_token_forget() {
  rm -f -- "$CS_HOME/token.dpapi" "$CS_HOME/token.json"
  CS_TOKEN_CACHE=
}

# --- HTTP to the token endpoint ---------------------------------------------------------------------------

# cs_oauth_post URL FIELD=VALUE...: form POST; prints "<http code>\n<body>". file:// URLs (tests) count as 200.
cs_oauth_post() {
  local url=$1 out code
  shift
  local -a args=()
  local kv
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  out=$(nat curl -sS --connect-timeout 10 --max-time 60 -w '\n%{http_code}' "${args[@]}" "$url" 2>/dev/null) || {
    printf '000\n'
    return 6
  }
  code=${out##*$'\n'}
  [[ $code == 000 && $url == file://* ]] && code=200
  printf '%s\n%s\n' "$code" "${out%$'\n'*}" | tr -d '\r'
}

# cs_oauth_error_rc BODY -> 3 for errors that need a new login, 6 otherwise.
cs_oauth_error_rc() {
  case $(cs_jq -r '.error // empty' <<<"$1" 2>/dev/null) in
    invalid_grant | invalid_client | deleted_client | unauthorized_client) return "$CS_EXIT_LOGIN" ;;
  esac
  return 6
}

# cs_token_from_response BODY NOW [OLD_REFRESH]: our stored token object from a token-endpoint response.
cs_token_from_response() {
  cs_jq -c --argjson now "$2" --arg old "${3:-}" '
    {refresh_token: (.refresh_token // $old), access_token, scope, token_type,
     expires_at: ($now + (.expires_in // 3600) - 60)}' <<<"$1"
}

# cs_oauth_exchange CODE VERIFIER REDIRECT: trade the code for tokens and save them. Prints a warning when
# the app is still in Testing (refresh tokens then expire after 7 days).
cs_oauth_exchange() {
  local resp code body now
  cs_client_load
  resp=$(cs_oauth_post "$CS_OAUTH_TOKEN_EP" "client_id=$CS_CLIENT_ID" "client_secret=$CS_CLIENT_SECRET" \
    "code=$1" "code_verifier=$2" "redirect_uri=$3" "grant_type=authorization_code") || true
  code=${resp%%$'\n'*}
  body=${resp#*$'\n'}
  if [[ $code != 200 ]] || ! cs_jq -e '.access_token and (.error | not)' <<<"$body" >/dev/null 2>&1; then
    cs_log error "login: token exchange failed (http $code, $(cs_jq -r '.error // "?"' <<<"$body" 2>/dev/null))"
    cs_say auth.exchange_failed "$(cs_jq -r '.error_description // .error // "network"' <<<"$body" 2>/dev/null)" >&2
    return "$CS_EXIT_LOGIN"
  fi
  if ! cs_jq -e --arg s "$CS_OAUTH_SCOPE" '.refresh_token and ((.scope // "") | split(" ") | index([$s]))' <<<"$body" >/dev/null; then
    cs_say auth.no_drive_scope >&2
    return "$CS_EXIT_LOGIN"
  fi
  if cs_jq -e '.refresh_token_expires_in' <<<"$body" >/dev/null 2>&1; then
    cs_say auth.testing_mode >&2
  fi
  now=$(date +%s)
  cs_token_save "$(cs_token_from_response "$body" "$now")"
  cs_log info "login: token stored"
}

# cs_access_token: a valid access token on stdout, refreshed (under the fd-8 lock) when it expires
# within 60 s. rc 3 = login required, 6 = network.
cs_access_token() {
  local tok now exp
  tok=$(cs_token_load) || return "$CS_EXIT_LOGIN"
  now=$(date +%s)
  exp=$(cs_jq -r '.expires_at // 0' <<<"$tok")
  if ((exp > now + 60)); then
    cs_jq -r .access_token <<<"$tok"
    return 0
  fi
  exec 8>>"$CS_HOME/token.lock"
  cs_lock_fd 8 30 || return 6
  # Another process may have refreshed while we waited.
  CS_TOKEN_CACHE=
  tok=$(cs_token_load) || {
    exec 8>&-
    return "$CS_EXIT_LOGIN"
  }
  exp=$(cs_jq -r '.expires_at // 0' <<<"$tok")
  if ((exp <= $(date +%s) + 60)); then
    local resp code body rt rc
    cs_client_load
    rt=$(cs_jq -r .refresh_token <<<"$tok")
    resp=$(cs_oauth_post "$CS_OAUTH_TOKEN_EP" "client_id=$CS_CLIENT_ID" "client_secret=$CS_CLIENT_SECRET" \
      "refresh_token=$rt" "grant_type=refresh_token") || true
    code=${resp%%$'\n'*}
    body=${resp#*$'\n'}
    if [[ $code != 200 ]] || ! cs_jq -e '.access_token and (.error | not)' <<<"$body" >/dev/null 2>&1; then
      cs_oauth_error_rc "$body" && rc=0 || rc=$?
      cs_log warn "token refresh failed (http $code, $(cs_jq -r '.error // "?"' <<<"$body" 2>/dev/null))"
      exec 8>&-
      return "$rc"
    fi
    tok=$(cs_token_from_response "$body" "$(date +%s)" "$rt")
    cs_token_save "$tok"
  fi
  exec 8>&-
  cs_jq -r .access_token <<<"$tok"
}

# --- loopback listener ------------------------------------------------------------------------------------
# Prints "PORT n" once listening, then "QUERY <raw query>" when the browser comes back (or "ERROR ...").

read -r -d '' CS_PS_LISTENER <<'PS' || true
$timeout = [int]$env:CS_TIMEOUT_SEC; if (-not $timeout) { $timeout = 300 }
$listener = $null
for ($i = 0; $i -lt 10 -and -not $listener; $i++) {
  $tl = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $tl.Start(); $port = $tl.LocalEndpoint.Port; $tl.Stop()
  $l = New-Object System.Net.HttpListener; $l.Prefixes.Add("http://127.0.0.1:$port/")
  try { $l.Start(); $listener = $l } catch { $l.Close() }
}
if (-not $listener) { [Console]::Out.WriteLine('ERROR no-port'); exit 2 }
[Console]::Out.WriteLine("PORT $port"); [Console]::Out.Flush()
$deadline = (Get-Date).AddSeconds($timeout)
try {
  while ($true) {
    $t = $listener.GetContextAsync()
    while (-not $t.Wait(500)) { if ((Get-Date) -ge $deadline) { [Console]::Out.WriteLine('ERROR timeout'); exit 3 } }
    $c = $t.Result; $q = $c.Request.Url.Query
    $done = $q -match '(^|[?&])(code|error)='
    $html = if ($done) { $env:CS_DONE_HTML } else { 'not found' }
    $b = [Text.Encoding]::UTF8.GetBytes($html)
    $c.Response.StatusCode = $(if ($done) { 200 } else { 404 }); $c.Response.ContentType = 'text/html; charset=utf-8'
    $c.Response.ContentLength64 = $b.Length; $c.Response.OutputStream.Write($b, 0, $b.Length); $c.Response.Close()
    if ($done) { [Console]::Out.WriteLine('QUERY ' + $c.Request.Url.Query.TrimStart('?')); [Console]::Out.Flush(); exit 0 }
  }
} finally { $listener.Close() }
PS

read -r -d '' CS_PY_LISTENER <<'PY' || true
import http.server, os, sys, time, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.urlsplit(self.path).query
        done = any(k in ('code', 'error') for k, _ in urllib.parse.parse_qsl(q))
        b = os.environ.get('CS_DONE_HTML', 'done').encode('utf-8') if done else b'not found'
        self.send_response(200 if done else 404)
        self.send_header('Content-Type', 'text/html; charset=utf-8'); self.send_header('Content-Length', str(len(b)))
        self.send_header('Connection', 'close'); self.end_headers(); self.wfile.write(b)
        if done:
            print('QUERY ' + q, flush=True); self.server.done = True
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H); s.done = False; s.timeout = 1
print('PORT %d' % s.server_address[1], flush=True)
end = time.time() + int(os.environ.get('CS_TIMEOUT_SEC', '300'))
while not s.done and time.time() < end:
    s.handle_request()
if not s.done: print('ERROR timeout', flush=True)
sys.exit(0 if s.done else 3)
PY

# cs_listener_start OUTFILE: start the listener in the background; sets CS_LISTENER_PID and CS_PORT.
cs_listener_start() {
  local out=$1 i
  CS_PORT=
  export CS_TIMEOUT_SEC=$CS_LOGIN_TIMEOUT CS_DONE_HTML
  CS_DONE_HTML="<!doctype html><meta charset=\"utf-8\"><title>claude-sync</title><h2>$(cs_t auth.browser_done)</h2>"
  if [[ $CS_OS == windows ]]; then
    local enc
    enc=$(printf '%s' "\$ErrorActionPreference='Stop'; \$ProgressPreference='SilentlyContinue'
$CS_PS_LISTENER" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
    # Started directly (not through the nat function) so that $! is the listener itself.
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -EncodedCommand "$enc" >"$out" 2>/dev/null 9>&- &
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "$CS_PY_LISTENER" >"$out" 2>/dev/null 9>&- &
  else
    return 1
  fi
  CS_LISTENER_PID=$!
  for ((i = 0; i < 200; i++)); do
    CS_PORT=$(sed -n 's/^PORT \([0-9]*\).*/\1/p' "$out" 2>/dev/null | tr -d '\r')
    [[ -n $CS_PORT ]] && return 0
    kill -0 "$CS_LISTENER_PID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

# cs_open_browser URL: best effort (the URL is always printed as well).
cs_open_browser() {
  [[ ${CS_NO_BROWSER:-0} == 1 || -n ${SSH_CONNECTION:-} ]] && return 1
  if [[ $CS_OS == windows ]] || ((CS_WSL)); then
    CS_URL=$1 powershell.exe -NoProfile -NonInteractive -Command 'Start-Process $env:CS_URL' >/dev/null 2>&1 && return 0
  elif [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1" >/dev/null 2>&1 &
    return 0
  fi
  return 1
}

# cs_auth_url REDIRECT CHALLENGE STATE -> the Google consent URL.
cs_auth_url() {
  printf '%s?client_id=%s&redirect_uri=%s&response_type=code&scope=%s&code_challenge=%s&code_challenge_method=S256&state=%s&access_type=offline&prompt=consent\n' \
    "$CS_OAUTH_AUTH_EP" "$(cs_urlenc "$CS_CLIENT_ID")" "$(cs_urlenc "$1")" "$(cs_urlenc "$CS_OAUTH_SCOPE")" "$2" "$3"
}

# cs_auth_login: interactive login (loopback; or paste the final URL when the browser cannot reach us).
cs_auth_login() {
  local verifier challenge state redirect url out query line err code
  cs_client_load
  verifier=$(cs_random_token 48)
  challenge=$(cs_pkce_challenge "$verifier")
  state=$(cs_random_token 24)
  out=$(mktemp)
  if cs_listener_start "$out"; then
    redirect="http://127.0.0.1:$CS_PORT/"
  else
    redirect="http://127.0.0.1:1/"
    CS_LISTENER_PID=
  fi
  url=$(cs_auth_url "$redirect" "$challenge" "$state")
  cs_say auth.open_url
  printf '  %s\n\n' "$url"
  cs_open_browser "$url" || true
  cs_say auth.waiting
  query=
  while :; do
    if [[ -n $CS_LISTENER_PID ]] && ! kill -0 "$CS_LISTENER_PID" 2>/dev/null; then break; fi
    if [[ -t 0 ]]; then
      if IFS= read -r -t 1 line && [[ $line == *\?* ]]; then
        query=${line#*\?}
        break
      fi
    elif [[ -z $CS_LISTENER_PID ]]; then
      IFS= read -r line || break
      query=${line#*\?}
      break
    else
      sleep 1
    fi
  done
  [[ -n $query ]] || query=$(sed -n 's/^QUERY //p' "$out" | tr -d '\r')
  [[ -n $CS_LISTENER_PID ]] && kill "$CS_LISTENER_PID" 2>/dev/null
  rm -f -- "$out"
  query=${query%%#*}
  [[ -n $query ]] || {
    cs_say auth.timeout >&2
    return "$CS_EXIT_LOGIN"
  }
  [[ $(cs_qs_get "$query" state) == "$state" ]] || {
    cs_say auth.state_mismatch >&2
    return "$CS_EXIT_LOGIN"
  }
  err=$(cs_qs_get "$query" error)
  [[ -z $err ]] || {
    cs_say auth.denied "$err" >&2
    return "$CS_EXIT_LOGIN"
  }
  code=$(cs_qs_get "$query" code)
  cs_oauth_exchange "$code" "$verifier" "$redirect"
}

# cs_auth_logout: revoke the refresh token at Google (best effort) and delete it locally.
cs_auth_logout() {
  local tok rt
  if tok=$(cs_token_load 2>/dev/null); then
    rt=$(cs_jq -r '.refresh_token // empty' <<<"$tok")
    if [[ -n $rt ]]; then
      cs_oauth_post "$CS_OAUTH_REVOKE_EP" "token=$rt" >/dev/null || true
    fi
  fi
  cs_token_forget
  cs_log info "logout: token revoked and removed"
}
