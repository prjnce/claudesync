#!/usr/bin/env bats
# Deterministic forks and the conflicts command (ticket #20). Machines B and C are POSIX-style.

load test_helper
load sim_helper

SID=0b7a1c2e-1111-4222-8333-444455556666

setup() {
  cs_test_setup
  cs_load platform version
  sim_init
  BROOT="$SIM/B/work/X"
  CROOT="$SIM/C/work/X"
  sim_machine B p "$BROOT"
  sim_machine C p "$CROOT"
  BSLUG=$(cc_slug "$BROOT")
  CSLUG=$(cc_slug "$CROOT")
  BCC="$SIM/B/claude"
  CCC="$SIM/C/claude"
  B_FILE="$BCC/projects/$BSLUG/$SID.jsonl"
  C_FILE="$CCC/projects/$CSLUG/$SID.jsonl"
}

# line MACHINE_ROOT UUID TIMESTAMP [SESSION]
line() { printf '{"type":"user","uuid":"%s","timestamp":"%s","cwd":"%s","sessionId":"%s","slug":"plan-one"}' "$2" "$3" "$1" "${4:-$SID}"; }

# Both machines have the session with one shared line, plus a subagent, a tool result, file-history, a plan.
shared_start() {
  sim_write B "$BSLUG" "$SID" "$(line "$BROOT" u0 2026-10-08T00:00:00Z)"
  mkdir -p "$BCC/projects/$BSLUG/$SID/subagents" "$BCC/projects/$BSLUG/$SID/tool-results" "$BCC/file-history/$SID" "$BCC/plans"
  printf '%s
' '{"type":"user","uuid":"g1","sessionId":"'"$SID"'"}' >"$BCC/projects/$BSLUG/$SID/subagents/agent-a1.jsonl"
  printf 'result
' >"$BCC/projects/$BSLUG/$SID/tool-results/t1.txt"
  printf 'snap
' >"$BCC/file-history/$SID/abcd1234abcd1234@v1"
  printf 'the plan
' >"$BCC/plans/plan-one.md"
  local m
  for m in B C B C; do sim_run "$m" >/dev/null; done
  [ -f "$C_FILE" ]
}

# diverge: B appends an early line, C a later one (nobody syncs in between).
diverge() {
  printf '%s
' "$(line "$BROOT" ub "$1")" >>"$B_FILE"
  printf '%s
' "$(line "$CROOT" uc "$2")" >>"$C_FILE"
}

forks_of() { echo $(($(ls "$SIM/$1"/claude/projects/*/ | grep -c '^[0-9a-f]\{8\}-.*\.jsonl$') - 1)); } # session files other than $SID

@test "A4/F1: both machines continue offline; the earlier branch keeps the id, the other becomes a separate session, no line is lost" {
  shared_start
  diverge 2026-10-08T01:00:00Z 2026-10-08T02:00:00Z
  for m in B C B C B C; do sim_run "$m" >/dev/null; done
  # B's branch is earlier: it wins on both machines
  [ "$(grep -c uc "$B_FILE")" -eq 0 ]
  [ "$(grep -c ub "$B_FILE")" -eq 1 ]
  [ "$(sim_canon B "$B_FILE")" = "$(sim_canon C "$C_FILE")" ]
  # C lost: its branch lives on as a separate session with all its lines and a conflict title
  fork=$(sim_exec C 'cs_fork_sid "$1" uc' "$SID" | tr -d '\r')
  ff=$(sim_find C "$fork")
  [ -n "$ff" ]
  grep -q 'uc' "$ff"
  grep -q "\"sessionId\":\"$fork\"" "$ff"
  ! grep -q "\"sessionId\":\"$SID\"" "$ff"
  grep -q '"type":"custom-title".*conflict' "$ff"
  [ "$(wc -l <"$ff")" -eq 3 ]
  # the fork travels to B like any session
  [ -n "$(sim_find B "$fork")" ]
  for m in B C B C; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
  run sim_cli C conflicts list
  [[ $output == *"$fork"* ]]
}

@test "H2: the same winner and the same fork id whichever machine runs first" {
  shared_start
  diverge 2026-10-08T01:00:00Z 2026-10-08T02:00:00Z
  for m in C B C B C B; do sim_run "$m" >/dev/null; done
  [ "$(grep -c ub "$C_FILE")" -eq 1 ]
  [ "$(grep -c uc "$C_FILE")" -eq 0 ]
  fork=$(sim_exec C 'cs_fork_sid "$1" uc' "$SID" | tr -d '\r')
  [ -n "$(sim_find C "$fork")" ]
  [ "$(ls "$CCC"/projects/*/ | grep -c "^$fork.jsonl$")" -eq 1 ]
  [ "$(forks_of C)" -eq 1 ]
}

@test "the later machine winning is symmetric: when C is earlier, B forks" {
  shared_start
  diverge 2026-10-08T03:00:00Z 2026-10-08T02:00:00Z
  for m in B C B C B C; do sim_run "$m" >/dev/null; done
  [ "$(grep -c uc "$B_FILE")" -eq 1 ]
  fork=$(sim_exec B 'cs_fork_sid "$1" ub' "$SID" | tr -d '\r')
  [ -n "$(sim_find B "$fork")" ]
}

@test "M10: the fork has the subagent, tool results, file-history, plan and title; running again makes no second copy" {
  shared_start
  diverge 2026-10-08T01:00:00Z 2026-10-08T02:00:00Z
  for m in B C B C B C; do sim_run "$m" >/dev/null; done
  fork=$(sim_exec C 'cs_fork_sid "$1" uc' "$SID" | tr -d '\r')
  d="$CCC/projects/$CSLUG/$fork"
  [ -f "$d/subagents/agent-a1.jsonl" ]
  grep -q "\"sessionId\":\"$fork\"" "$d/subagents/agent-a1.jsonl"
  [ "$(cat "$d/tool-results/t1.txt")" = result ]
  [ -f "$CCC/file-history/$fork/abcd1234abcd1234@v1" ]
  [ -f "$d/custom-title.json" ]
  grep -q 'plan-one-c' "$(sim_find C "$fork")"
  [ -n "$(ls "$CCC"/plans/plan-one-c*.md)" ]
  sim_exec C 'CS_PDIR="$(cs_claude_dir)/projects"; cs_fork_materialize "$1" "$2" "$3" "$4" p1 "{}"' "$SID" "$fork" "$C_FILE" "$CSLUG"
  [ "$(forks_of C)" -eq 1 ]
}

# What Claude appends when a session is only reopened: resume hook attachment, the synthetic task-notification user
# line, bridge-session, cost-state, atis-latch (no prompt, no answer).
reopen_lines() { # TIMESTAMP
  printf '%s\n' \
    '{"parentUuid":"u0","isSidechain":false,"attachment":{"type":"hook_cancelled","hookName":"SessionStart:resume"},"type":"attachment","uuid":"hk1","timestamp":"'"$1"'","sessionId":"'"$SID"'"}' \
    '{"parentUuid":"hk1","isSidechain":false,"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>t1</task-id>\n</task-notification>"},"uuid":"tn1","timestamp":"'"$1"'","sessionId":"'"$SID"'"}' \
    '{"type":"bridge-session","sessionId":"'"$SID"'","bridgeSessionId":"cse_1"}' \
    '{"type":"cost-state","sessionId":"'"$SID"'","totalCostUSD":0}' \
    '{"type":"atis-latch","atis":"","sessionId":"'"$SID"'"}'
}

@test "a branch that only reopened the session loses without a separate session, even when it is the earlier one" {
  shared_start
  reopen_lines 2026-10-08T01:00:00Z >>"$B_FILE"
  printf '%s\n' "$(line "$CROOT" uc 2026-10-08T02:00:00Z)" >>"$C_FILE"
  for m in B C B C B C; do sim_run "$m" >/dev/null; done
  # C's real line wins on both machines; B's reopening is saved as a backup, not as a session
  [ "$(grep -c uc "$B_FILE")" -eq 1 ]
  [ "$(grep -c tn1 "$B_FILE")" -eq 0 ]
  [ "$(forks_of B)" -eq 0 ]
  [ "$(forks_of C)" -eq 0 ]
  [ "$(sim_canon B "$B_FILE")" = "$(sim_canon C "$C_FILE")" ]
  [ -n "$(ls "$SIM/B/home/.claude-sync/backups" | grep fork-)" ]
}

@test "two machines that both only reopened the session make no separate session" {
  shared_start
  reopen_lines 2026-10-08T01:00:00Z >>"$B_FILE"
  reopen_lines 2026-10-08T02:00:00Z | sed 's/hk1/hk2/;s/tn1/tn2/' >>"$C_FILE"
  for m in B C B C B C; do sim_run "$m" >/dev/null; done
  [ "$(forks_of B)" -eq 0 ]
  [ "$(forks_of C)" -eq 0 ]
  [ "$(sim_canon B "$B_FILE")" = "$(sim_canon C "$C_FILE")" ]
}

@test "a task-notification followed by an answer is real work: it is not swallowed as a reopening" {
  shared_start
  {
    reopen_lines 2026-10-08T01:00:00Z
    printf '%s\n' '{"type":"assistant","uuid":"as1","parentUuid":"tn1","timestamp":"2026-10-08T01:00:05Z","sessionId":"'"$SID"'"}'
  } >>"$B_FILE"
  printf '%s\n' "$(line "$CROOT" uc 2026-10-08T02:00:00Z)" >>"$C_FILE"
  for m in B C B C B C; do sim_run "$m" >/dev/null; done
  # B's answer is the earlier chat line: B wins, and C's later work lives on as a separate session
  [ "$(grep -c as1 "$B_FILE")" -eq 1 ]
  [ "$(grep -c uc "$B_FILE")" -eq 0 ]
  fork=$(sim_exec C 'cs_fork_sid "$1" uc' "$SID" | tr -d '\r')
  [ -n "$(sim_find C "$fork")" ]
}

@test "the conflict title is the session's aiTitle when it has no customTitle, and a customTitle wins over it" {
  sim_write B "$BSLUG" "$SID" "$(line "$BROOT" u0 2026-10-08T00:00:00Z)" '{"type":"ai-title","aiTitle":"Auto \"quoted\" title","sessionId":"'"$SID"'"}'
  local m
  for m in B C B C; do sim_run "$m" >/dev/null; done
  diverge 2026-10-08T01:00:00Z 2026-10-08T02:00:00Z
  for m in B C B C B C; do sim_run "$m" >/dev/null; done
  fork=$(sim_exec C 'cs_fork_sid "$1" uc' "$SID" | tr -d '\r')
  ff=$(sim_find C "$fork")
  [ -n "$ff" ]
  [ "$(tail -n 1 "$ff" | jq -r .customTitle)" = '[conflict C] Auto "quoted" title' ]
  # a /rename hides the aiTitle in Claude, so it is the title to carry
  printf '%s\n' '{"type":"custom-title","customTitle":"My name","sessionId":"'"$SID"'"}' >"$BATS_TEST_TMPDIR/t.jsonl"
  [ "$(sim_exec C 'cs_fork_title "$1"' "$BATS_TEST_TMPDIR/t.jsonl" | tr -d '\r')" = 'My name' ]
  printf '%s\n' '{"type":"ai-title","aiTitle":"Auto","sessionId":"x"}' '{"type":"custom-title","customTitle":"My name","sessionId":"x"}' >"$BATS_TEST_TMPDIR/t.jsonl"
  [ "$(sim_exec C 'cs_fork_title "$1"' "$BATS_TEST_TMPDIR/t.jsonl" | tr -d '\r')" = 'My name' ]
  : >"$BATS_TEST_TMPDIR/t.jsonl"
  [ "$(sim_exec C 'cs_fork_title "$1"' "$BATS_TEST_TMPDIR/t.jsonl" | tr -d '\r')" = '(untitled)' ]
}

@test "a branch that only differs in metadata loses without a separate session" {
  shared_start
  printf '%s
' '{"type":"last-prompt","lastPrompt":"x","sessionId":"'"$SID"'"}' >>"$B_FILE"
  printf '%s
' "$(line "$CROOT" uc 2026-10-08T02:00:00Z)" >>"$C_FILE"
  for m in B C B C B C; do sim_run "$m" >/dev/null; done
  [ "$(grep -c uc "$B_FILE")" -eq 1 ]
  [ "$(forks_of B)" -eq 0 ]
  [ "$(sim_canon B "$B_FILE")" = "$(sim_canon C "$C_FILE")" ]
  [ -n "$(ls "$SIM/B/home/.claude-sync/backups" | grep fork-)" ]
}
