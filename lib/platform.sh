# shellcheck shell=bash
# platform: nat(), path conversion, cc_slug, on-disk realpath, PID liveness, fd lock (SPEC §3.3, §4.1, §4.6, §14).
# Requires lib/core.sh (CS_OS set by cs_bootstrap).

[[ -n ${CS_PLATFORM_LOADED:-} ]] && return 0
CS_PLATFORM_LOADED=1

cs_is_msys() {
  [[ $OSTYPE == msys* || $OSTYPE == cygwin* ]]
}

# cs_nat_check_args ARGS...: rc 2 if an argument is an unconverted rooted POSIX path (/c/x/..., --f=/a/b).
# Single-component switches such as /TN or /Create are allowed.
cs_nat_check_args() {
  local a
  for a in "$@"; do
    if [[ $a =~ ^(-{1,2}[A-Za-z0-9-]+=)?/[^/]+/ ]]; then
      printf 'claude-sync: nat: refusing unconverted POSIX path argument: %s\n' "$a" >&2
      return 2
    fi
  done
}

# nat CMD ARGS...: run a native Windows executable with MSYS argv/env path conversion disabled.
# Path arguments must already be in Windows form (cs_to_win). Output may contain CR: strip it.
nat() {
  if cs_is_msys; then
    cs_nat_check_args "${@:2}" || return 2
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$@"
  else
    "$@"
  fi
}

# cs_to_win PATH...: Windows mixed form (C:/x/y) on MSYS, unchanged elsewhere. One line per path, one fork.
cs_to_win() {
  (($#)) || return 0
  if cs_is_msys; then
    cygpath -m -- "$@"
  else
    printf '%s\n' "$@"
  fi
}

# cs_ps NAME SCRIPT: run a PowerShell 5.1 script inline (-EncodedCommand works under RemoteSigned GPO).
# Data goes through environment variables, never through the script text. Output is UTF-8 without CR.
cs_ps() {
  local script=$2 enc
  script="\$ErrorActionPreference='Stop'; \$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8
$script"
  enc=$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  nat powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$enc" | tr -d '\r'
}

# cc_slug PATH: the ~/.claude/projects/<slug> name Claude Code uses for PATH (Claude Code 2.1.x):
#   k(e)  = e.replace(/[^a-zA-Z0-9]/g, "-")              -- per UTF-16 code unit
#   LA(e) = k(e) if k(e).length <= 200
#           else k(e).slice(0,200) + "-" + Math.abs(F7(e)).toString(36)
#   F7(e) = h=(h<<5)-h+charCodeAt(i)|0 over UTF-16 code units of the ORIGINAL string
# Pure bash (no forks). Iterates code points under C.UTF-8. Input must be valid UTF-8.
cc_slug() {
  local LC_ALL=C.UTF-8
  local s=$1 out='' ch i n cp h=0 hi lo q r digits=0123456789abcdefghijklmnopqrstuvwxyz b36=''
  n=${#s}
  for ((i = 0; i < n; i++)); do
    ch=${s:i:1}
    printf -v cp '%d' "'$ch"
    if ((cp >= 0x10000)); then # non-BMP: a surrogate pair is 2 code units
      hi=$((0xD800 + ((cp - 0x10000) >> 10)))
      lo=$((0xDC00 + ((cp - 0x10000) & 0x3FF)))
      h=$((((h << 5) - h + hi) & 0xFFFFFFFF))
      h=$((((h << 5) - h + lo) & 0xFFFFFFFF))
      out+='--'
    else
      h=$((((h << 5) - h + cp) & 0xFFFFFFFF))
      if (((cp >= 48 && cp <= 57) || (cp >= 65 && cp <= 90) || (cp >= 97 && cp <= 122))); then
        out+=$ch
      else
        out+='-'
      fi
    fi
  done
  if ((${#out} <= 200)); then
    printf '%s\n' "$out"
    return 0
  fi
  ((h >= 0x80000000)) && h=$((h - 0x100000000)) # to signed int32
  ((h < 0)) && h=$((-h))                         # Math.abs (2^31 stays 2^31 in 64-bit math)
  q=$h
  [[ $q == 0 ]] && b36=0
  while ((q > 0)); do
    r=$((q % 36))
    b36=${digits:r:1}$b36
    q=$((q / 36))
  done
  printf '%s-%s\n' "${out:0:200}" "$b36"
}

# cs_realpath_disk PATH...: the path as the OS resolves it on disk, one line per input (empty line and
# rc 1 if any path does not exist). Windows: GetFinalPathNameByHandle (true case, junctions, symlinks),
# printed as D:\x\y — what Claude Code stores in realParentDir. Linux: realpath -e.
cs_realpath_disk() {
  (($#)) || return 0
  local rc=0 p out
  if cs_is_msys; then
    out=$(CS_RP_PATHS=$(cygpath -w -- "$@") cs_ps realpath '
Add-Type -Namespace CS -Name Fp -MemberDefinition @"
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sec, uint d, uint f, IntPtr t);
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern uint GetFinalPathNameByHandleW(IntPtr h, System.Text.StringBuilder b, uint n, uint f);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
"@
foreach ($p in ($env:CS_RP_PATHS -split "`n")) {
  # share read/write/delete, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS (needed for directories)
  $h = [CS.Fp]::CreateFileW($p, 0, 7, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
  if ($h -eq [IntPtr](-1)) { [Console]::Out.WriteLine(">"); continue }
  $sb = New-Object System.Text.StringBuilder 32768
  [void][CS.Fp]::GetFinalPathNameByHandleW($h, $sb, 32768, 0)
  [void][CS.Fp]::CloseHandle($h)
  $r = $sb.ToString()
  if ($r.StartsWith("\\?\UNC\")) { $r = "\\" + $r.Substring(8) } elseif ($r.StartsWith("\\?\")) { $r = $r.Substring(4) }
  [Console]::Out.WriteLine(">" + $r)
}') || return 1
    # Every line is prefixed with ">" so that trailing empty results survive $(...).
    while IFS= read -r p; do
      p=${p#>}
      [[ -n $p ]] || rc=1
      printf '%s\n' "$p"
    done <<<"$out"
  else
    for p in "$@"; do
      realpath -e -- "$p" 2>/dev/null || {
        printf '\n'
        rc=1
      }
    done
  fi
  return "$rc"
}

# cs_live_pids: every live process id, one per line (Windows: native WINPIDs from one `ps -W`).
cs_live_pids() {
  if cs_is_msys; then
    ps -W | "${CS_AWK:-awk}" 'NR > 1 { print $4 }'
  else
    local d
    for d in /proc/[0-9]*; do printf '%s\n' "${d#/proc/}"; done
  fi
}

# cs_pid_alive PID: rc 0 if the (native, on Windows) pid is running.
cs_pid_alive() {
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  if cs_is_msys; then
    ps -W | "${CS_AWK:-awk}" -v w="$1" 'NR > 1 && $4 == w { f = 1 } END { exit !f }'
  else
    kill -0 "$1" 2>/dev/null || [[ -d /proc/$1 ]] # EPERM (other user) still means alive
  fi
}

# cs_proc_start_ids PID...: "pid<TAB>start id" for each running pid, in the encoding Claude Code stores
# in sessions/<pid>.json procStart. Windows: creation time as FILETIME (UTC); Linux: field 22 of
# /proc/<pid>/stat (starttime in clock ticks since boot) — verified against live WSL records.
cs_proc_start_ids() {
  (($#)) || return 0
  local p st IFS=' '
  local -a f
  if cs_is_msys; then
    CS_PIDS="$*" cs_ps procstart '
foreach ($id in ($env:CS_PIDS -split " ")) {
  $p = Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue
  if ($p) { try { [Console]::Out.WriteLine("$id`t" + $p.StartTime.ToFileTimeUtc()) } catch {} }
}'
  else
    for p in "$@"; do
      [[ $p =~ ^[0-9]+$ ]] || continue
      { IFS= read -r st <"/proc/$p/stat"; } 2>/dev/null || continue
      # comm (field 2) may contain spaces and ')': split after the last ')'; field 22 is then f[19].
      read -r -a f <<<"${st##*) }"
      printf '%s\t%s\n' "$p" "${f[19]}"
    done
  fi
}

# cs_lock_fd FD [WAIT_SECONDS]: take an exclusive OS lock on the already-open FD; rc 1 if still busy after
# WAIT_SECONDS (default 0 = do not wait). The OS releases it when the last holder of FD exits, so a
# killed or suspended run never leaves a stale lock. fd 9 is the sync lock (long-lived children should
# run with 9>&-); fd 8 is the token-refresh lock.
cs_lock_fd() {
  local fd=$1 wait=${2:-0}
  if command -v flock >/dev/null 2>&1; then
    if [[ $wait == 0 ]]; then flock -n "$fd"; else flock -w "$wait" "$fd"; fi
  else
    perl -MFcntl=:flock -MTime::HiRes=sleep,time -e '
      open(my $f, ">&=", $ARGV[0]) or die "claude-sync: fdopen $ARGV[0]: $!\n";
      my $deadline = time + $ARGV[1];
      until (flock($f, LOCK_EX | LOCK_NB)) { exit 1 if time >= $deadline; sleep 0.05 }
      exit 0' "$fd" "$wait"
  fi
}

cs_lock_fd9() {
  cs_lock_fd 9 "${1:-0}"
}

# cs_lock_acquire FILE [WAIT_SECONDS]: open FILE on fd 9 of the current shell and lock it (sync lock).
cs_lock_acquire() {
  exec 9>>"$1"
  cs_lock_fd 9 "${2:-0}"
}
