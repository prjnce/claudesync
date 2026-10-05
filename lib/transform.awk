# transform.awk — byte-exact path translation of Claude Code JSONL (SPEC §7.2). POSIX awk (mawk 1.3.4, gawk).
# Run as: LC_ALL=C awk -v BINMODE=3 -f transform.awk < in > out      (see cs_transform_file for the final newline)
# ENVIRON:
#   CS_MODE   canon (local paths -> tokens) | local (tokens -> local paths)
#   CS_SEP    w | p: separator style of THIS machine, used for relative paths when localizing
#   CS_ROOTS  newline-separated rows "scope<TAB>token<TAB>root<TAB>style<TAB>ci"
#             scope: P = every key except realParentDir, R = realParentDir only, A = every key
#             root : JSON-escaped, exactly as it appears in the file (D:\\Projects\\X, /home/u/x)
#             style: w (separator is the escaped backslash) | p (separator is /)
#             ci   : 1 = ASCII case-insensitive match (Windows drive paths, /mnt/<x>), 0 = exact
#             In local mode the first row carrying a token wins (put a project's primary root first).
# Only JSON string values that follow one of the keys "cwd", "relocatedCwd", "trackingPath",
# "realParentDir", or an object key directly followed by {"backupFileName" (trackedFileBackups), are
# touched, and only if they start with a mapped root at a path boundary (canon) or with a token (local).
# Everything else, including CR bytes, escapes and UTF-8, is copied unchanged. No sub()/gsub(): their
# replacement strings treat \ and & differently in mawk and gawk.

function strend(s, st) {                 # index of the closing quote of the JSON string starting at st
  if (match(substr(s, st), /^([^"\\]|\\.)*"/)) return st + RLENGTH - 1
  return 0
}
function repl(s, from, to,   o, p) {     # literal replace-all
  o = ""
  while ((p = index(s, from)) > 0) { o = o substr(s, 1, p - 1) to; s = substr(s, p + length(from)) }
  return o s
}
function isrel(v,   c) {                 # relative path (not drive, not rooted, not UNC, not a token)
  c = substr(v, 1, 1)
  return !(v ~ /^[A-Za-z]:/ || c == "/" || c == BS || c == "{")
}
function canon(v, key,   i, rl, best, bl, c, nx, suf) {
  best = 0; bl = 0
  for (i = 1; i <= n; i++) {
    if (SC[i] == "R" && key != "realParentDir") continue
    if (SC[i] == "P" && key == "realParentDir") continue
    rl = RL[i]
    if (rl <= bl) continue                                   # longest root wins (nested roots)
    c = substr(v, 1, rl)
    if (CI[i] == "1" ? tolower(c) != LR[i] : c != RO[i]) continue
    nx = substr(v, rl + 1, 1)                                # path boundary right after the root
    if (nx != "" && nx != "/" && !(ST[i] == "w" && substr(v, rl + 1, 2) == BS BS)) continue
    best = i; bl = rl
  }
  if (best) {
    suf = substr(v, bl + 1)
    if (ST[best] == "w") suf = repl(suf, BS BS, "/")
    return TK[best] suf
  }
  if (REL[key] && isrel(v)) return repl(v, BS BS, "/")
  return v
}
function loc(v, key,   i, tl, suf) {
  for (i = 1; i <= n; i++) {
    tl = length(TK[i])
    if (substr(v, 1, tl) != TK[i]) continue
    suf = substr(v, tl + 1)
    if (suf != "" && substr(suf, 1, 1) != "/") continue
    if (ST[i] == "w") suf = repl(suf, "/", BS BS)
    return RO[i] suf
  }
  if (REL[key] && SEP == "w" && isrel(v)) return repl(v, "/", BS BS)
  return v
}
function x(v, key) {
  return MODE == "canon" ? canon(v, key) : loc(v, key)
}
BEGIN {
  BS = "\\"
  MODE = ENVIRON["CS_MODE"]; SEP = ENVIRON["CS_SEP"]
  if (MODE != "canon" && MODE != "local") { print "transform.awk: CS_MODE must be canon or local" > "/dev/stderr"; exit 2 }
  n = 0
  m = split(ENVIRON["CS_ROOTS"], rows, "\n")
  for (r = 1; r <= m; r++) {
    if (rows[r] == "") continue
    if (split(rows[r], f, "\t") != 5) { print "transform.awk: bad root row: " rows[r] > "/dev/stderr"; exit 2 }
    n++; SC[n] = f[1]; TK[n] = f[2]; RO[n] = f[3]; ST[n] = f[4]; CI[n] = f[5]; LR[n] = tolower(f[3]); RL[n] = length(f[3])
  }
  nk = split("cwd relocatedCwd trackingPath realParentDir", KN, " ")
  for (k = 1; k <= nk; k++) K[k] = "\"" KN[k] "\":\""
  REL["trackingPath"] = 1; REL["backupKey"] = 1
}
{
  line = $0
  if (!index(line, "\":\"")) { print line; next }           # no string-valued key at all: fast path
  out = ""
  while (1) {
    best = 0; bk = 0
    for (k = 1; k <= nk; k++) { p = index(line, K[k]); if (p && (!best || p < best)) { best = p; bk = k } }
    q = 0
    if (index(line, "\"backupFileName\"") && match(line, /[{,]"([^"\\]|\\.)*":\{"backupFileName"/)) q = RSTART
    if (q && (!best || q < best)) {
      st = q + 2; e = strend(line, st)
      if (!e) break
      out = out substr(line, 1, st - 1) x(substr(line, st, e - st), "backupKey") "\""
      line = substr(line, e + 1)
      continue
    }
    if (!best) break
    st = best + length(K[bk]); e = strend(line, st)
    if (!e) break                                            # unterminated (cut) line: leave the rest as is
    out = out substr(line, 1, st - 1) x(substr(line, st, e - st), KN[bk]) "\""
    line = substr(line, e + 1)
  }
  print out line
}
