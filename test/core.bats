#!/usr/bin/env bats
# core: config, atomic writes, logging.

load test_helper

setup() {
  cs_test_setup
  cs_load_core
}

@test "config get returns the default when unset, rc 1 without default" {
  run cs_config_get interval 5
  [ "$output" = 5 ]
  run cs_config_get interval
  [ "$status" -eq 1 ]
}

@test "config set then get; overwrite keeps other keys and order" {
  cs_config_set interval 5
  cs_config_set guard block
  cs_config_set interval 10
  [ "$(cs_config_get interval)" = 10 ]
  [ "$(cs_config_get guard)" = block ]
  [ "$(cat "$CLAUDE_SYNC_HOME/config")" = $'interval=10\nguard=block' ]
}

@test "config values may contain '=' and spaces" {
  cs_config_set proxy 'http://u:p@h:1/?a=b c'
  [ "$(cs_config_get proxy)" = 'http://u:p@h:1/?a=b c' ]
}

@test "config key that is a prefix of another key does not match it" {
  cs_config_set interval_extra x
  run cs_config_get interval
  [ "$status" -eq 1 ]
}

@test "invalid config key or multi-line value is rejected with exit 2" {
  run cs_config_set 'Bad-Key' 1
  [ "$status" -eq 2 ]
  run cs_config_set guard $'a\nb'
  [ "$status" -eq 2 ]
}

@test "atomic write replaces the target on success" {
  f="$BATS_TEST_TMPDIR/t"
  printf old >"$f"
  cs_write_atomic "$f" printf new
  [ "$(cat "$f")" = new ]
  [ -z "$(ls "$BATS_TEST_TMPDIR" | grep csync-tmp || true)" ]
}

@test "atomic write leaves the target untouched when the producer fails" {
  f="$BATS_TEST_TMPDIR/t"
  printf old >"$f"
  run cs_write_atomic "$f" bash -c 'printf partial; exit 3'
  [ "$status" -eq 3 ]
  [ "$(cat "$f")" = old ]
  [ -z "$(ls "$BATS_TEST_TMPDIR" | grep csync-tmp || true)" ]
}

@test "atomic write leaves the target untouched when killed mid-write" {
  f="$BATS_TEST_TMPDIR/t"
  printf old >"$f"
  (
    source "$CS_ROOT/lib/core.sh"
    cs_write_atomic "$f" bash -c 'printf partial; sleep 3'
  ) >/dev/null 2>&1 3>&- &
  pid=$!
  sleep 1
  kill -9 "$pid"
  wait "$pid" 2>/dev/null || true
  [ "$(cat "$f")" = old ]
}

@test "log lines are local ISO time with a UTC offset, carry trigger and level, and only go to an existing logs dir" {
  cs_log info "no dir yet"
  [ ! -e "$CLAUDE_SYNC_HOME/logs/claude-sync.log" ]
  mkdir -p "$CLAUDE_SYNC_HOME/logs"
  CS_TRIGGER=timer cs_log info "hello world"
  line=$(cat "$CLAUDE_SYNC_HOME/logs/claude-sync.log")
  [[ $line =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}\ trigger=timer\ level=info\ hello\ world$ ]]
}

@test "log timestamps follow the machine time zone" {
  mkdir -p "$CLAUDE_SYNC_HOME/logs"
  TZ=Etc/GMT-7 cs_log info zone
  [[ $(cat "$CLAUDE_SYNC_HOME/logs/claude-sync.log") == *'+0700 trigger='* ]]
}

@test "warn goes to stderr, info is silent unless verbose" {
  run cs_log info quiet
  [ -z "$output" ]
  run cs_log warn loud
  [[ $output == *"warn: loud"* ]]
  CS_VERBOSE=1 run cs_log info chatty
  [[ $output == *chatty* ]]
}
