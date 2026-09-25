#!/usr/bin/env bash
# Behavior tests for the verified Devin CLI crewmate/scout adapter.
#
# The facts pinned here are the ones a Devin release could silently change and
# the ones a wrong guess would make dangerous:
#   1. Devin is detected by process ancestry only (an anchored `devin` comm
#      name), never by an env marker. CHISEL_SESSION_DB is exported to Devin's
#      tool subprocesses but must never be promoted to a detection source: a
#      markerless crewmate launched from a Devin primary inherits it.
#   2. Devin shares Claude's lifecycle-hook dialect, so its busy source is
#      `devin-hook` and its per-task wiring is the worktree's
#      `.devin/hooks.v1.json` (no outer "hooks" wrapper key, no StopFailure).
#   3. Devin is a crewmate/scout adapter only: it has no primary supervision
#      protocol, so its control mechanics are verified while a secondmate launch
#      on it is refused loudly by bin/fm-spawn.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop them so the asserted verdict does
# not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT \
  CURSOR_INVOKED_AS FM_OMP_HARNESS GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-devin-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

# A fake ps that answers the ancestry walk's `comm=` / `args=` / `ppid=` reads
# from environment so each case drives the exact process shape it needs. The
# walk stops when ppid resolves to 1, so one hop is enough to reach a verdict.
make_fake_ps() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid= prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=${arg%%=*}
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm:1) printf '%s\n' 'init' ;;
  comm:*) printf '%s\n' "${FAKE_PS_COMM:-bash}" ;;
  args:*) printf '%s\n' "${FAKE_PS_ARGS:-bash}" ;;
  ppid:*) printf '%s\n' "${FAKE_PS_PPID:-1}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

run_harness() {  # <fakebin> [env assignments...]
  local fakebin=$1
  shift
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_OMP_HARNESS -u GEMINI_CLI \
    -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI \
    PATH="$fakebin:$BASE_PATH" "$@" "$HARNESS"
}

test_devin_ancestry_detects_the_native_binary() {
  local fakebin out
  fakebin=$(make_fake_ps "$TMP_ROOT/anc-native")
  out=$(run_harness "$fakebin" FAKE_PS_COMM=devin FAKE_PS_ARGS='devin --permission-mode dangerous')
  [ "$out" = devin ] \
    || fail "an anchored 'devin' ancestor must be detected as devin, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named devin command"
}

test_devin_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(make_fake_ps "$TMP_ROOT/anc-negatives")
  # A command that merely contains "devin" is not anchored and must not match.
  out=$(run_harness "$fakebin" FAKE_PS_COMM=devin-helper FAKE_PS_ARGS='devin-helper --serve')
  [ "$out" != devin ] \
    || fail "an unrelated devin-helper command must not be read as devin, got '$out'"
  # A later interpreter argument naming devin must not claim the identity.
  out=$(run_harness "$fakebin" FAKE_PS_COMM=node FAKE_PS_ARGS='node server.js --agent devin')
  [ "$out" != devin ] \
    || fail "a node argument naming devin must not be read as devin, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated devin mentions"
}

test_devin_chisel_session_db_is_not_a_marker() {
  local fakebin out
  fakebin=$(make_fake_ps "$TMP_ROOT/chisel")
  # CHISEL_SESSION_DB rides into Devin's tool subprocesses and would be
  # inherited by a markerless crewmate launched from a Devin primary. It must
  # never be promoted to a Layer-1 marker: with no devin ancestor, the verdict
  # stays unknown.
  out=$(run_harness "$fakebin" FAKE_PS_COMM=bash FAKE_PS_ARGS=bash \
    CHISEL_SESSION_DB=/tmp/chisel.sqlite)
  [ "$out" != devin ] \
    || fail "CHISEL_SESSION_DB must never claim the devin identity, got '$out'"
  [ "$out" = unknown ] \
    || fail "a markerless non-harness ancestry should resolve unknown, got '$out'"
  pass "fm-harness.sh: CHISEL_SESSION_DB is not promoted to a detection marker"
}

test_devin_control_mechanics_are_the_verified_ones() {
  local out
  fm_control_harness_supported devin \
    || fail "devin must be a supported control harness"
  out=$(fm_control_harness_family devin-3000.6.12)
  [ "$out" = devin ] || fail "a recorded devin* harness must resolve to devin, got '$out'"
  out=$(fm_control_interrupt_key devin)
  [ "$out" = Escape ] || fail "devin interrupts on Escape, got '$out'"
  out=$(fm_control_interrupt_repeat devin)
  [ "$out" = 2 ] || fail "devin interrupts on a double press, got '$out'"
  out=$(fm_control_interrupt_clear_key devin)
  [ "$out" = Escape ] || fail "devin closes a stray rewind picker with one more Escape, got '$out'"
  out=$(fm_control_interrupt_ack_source devin)
  [ "$out" = none ] || fail "devin has no interrupt acknowledgement source, got '$out'"
  out=$(fm_control_exit_command devin)
  [ "$out" = /exit ] || fail "devin exits with /exit, got '$out'"
  pass "fm-control-lib.sh: devin carries its verified interrupt and exit mechanics"
}

test_devin_is_crewmate_and_scout_only() {
  fm_control_harness_supports_kind devin ship \
    || fail "devin must be verified for ship work"
  fm_control_harness_supports_kind devin scout \
    || fail "devin must be verified for scout work"
  ! fm_control_harness_supports_kind devin secondmate \
    || fail "devin has no primary supervision protocol and must be refused for secondmates"
  pass "fm-control-lib.sh: devin is a crewmate/scout adapter only"
}

test_devin_wiring_is_the_worktree_hooks_file() {
  local out
  out=$(fm_control_harness_wiring_paths devin /wt /state task-1)
  [ "$out" = "/wt/.devin/hooks.v1.json" ] \
    || fail "devin's per-task wiring is the worktree's .devin/hooks.v1.json, got '$out'"
  pass "fm-control-lib.sh: devin's per-task wiring is its worktree hooks file"
}

test_devin_busy_source_is_devin_hook() {
  local sources
  sources=$(fm_busy_sources_for_harness devin)
  case " $sources " in
    *" devin-hook "*) ;;
    *) fail "devin's busy source must be devin-hook, got '$sources'" ;;
  esac
  fm_busy_source_trusted devin devin-hook \
    || fail "devin-hook must be a trusted busy source for devin"
  fm_busy_source_trusted devin gemini-hook \
    && fail "a foreign adapter's hook must not be trusted for devin"
  pass "bin/fm-busy-lib.sh: devin's semantic busy source is devin-hook"
}

test_devin_tmux_names_the_native_binary_an_agent() {
  local got
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  got=$(fm_agent_process_classify_name devin)
  [ "$got" = agent ] || fail "tmux liveness must read the devin binary as an agent, got '$got'"
  got=$(fm_agent_process_classify_name devinator)
  [ "$got" = other ] || fail "tmux liveness must not read devinator as an agent, got '$got'"
  pass "bin/fm-agent-process-lib.sh: devin is an agent, look-alike names are not"
}

test_devin_secondmate_spawn_is_refused() {
  local id home fakebin rc out
  id="devin-secondmate-$$"
  home="$TMP_ROOT/spawn/home"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  fakebin=$(fm_fakebin "$TMP_ROOT/spawn/fake")
  fm_fake_treehouse "$fakebin"
  fm_fake_exit0 "$fakebin" gh-axi gh devin
  rc=0
  out=$(HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate devin 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a devin secondmate spawn must be refused"
  assert_contains "$out" "devin is a verified crewmate/scout adapter only" \
    "devin secondmate refusal lacked its concrete reason"
  pass "fm-spawn.sh: devin cannot be launched as a secondmate"
}

# A Herdr restore resumes a recorded Devin session (`devin --resume <id>`) in the
# pane's saved TOP-LEVEL shell cwd, and Devin stops on its directory chooser when
# that is not the session's own directory (the real restore is pinned by
# tests/fm-devin-herdr-restore-e2e.test.sh). The fake tmux here models a pane
# whose reported cwd is its top-level shell's, which moves only on a top-level
# `cd` or where its window was created, never into a subshell such as an
# interactive `treehouse get`. A Devin spawn must durably lease its slot and
# leave that top-level shell in exactly the leased worktree.
test_devin_spawn_leaves_the_top_level_shell_in_the_worktree() {
  local id case_dir home proj wt fakebin out rc
  id="devin-toplevel-$$"
  case_dir="$TMP_ROOT/toplevel"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/slot"
  fm_test_spawn_home "$home" devin
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "slot-$id"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) cat "$FM_FAKE_SHELL_CWD"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window)
    prev=
    for a in "$@"; do
      [ "$prev" != -c ] || printf '%s\n' "$a" > "$FM_FAKE_SHELL_CWD"
      prev=$a
    done
    exit 0
    ;;
  send-keys)
    if [ "$#" -eq 5 ] && [ "$2" = -t ] && [ "$5" = Enter ]; then
      printf '%s\n' "$4" >> "$FM_FAKE_TYPED_LOG"
      case "$4" in
        "cd -- '"*"'") path=${4#"cd -- '"}; printf '%s\n' "${path%"'"}" > "$FM_FAKE_SHELL_CWD" ;;
      esac
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  fm_fake_exit0 "$fakebin" gh-axi gh devin
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$proj" > "$case_dir/shell-cwd"
  : > "$case_dir/typed.log"
  rc=0
  out=$(FM_FAKE_SHELL_CWD="$case_dir/shell-cwd" FM_FAKE_TYPED_LOG="$case_dir/typed.log" \
    FM_FAKE_TREEHOUSE_LEASE_PATH="$wt" FM_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    fm_test_run_spawn "$home" "$proj" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off) || rc=$?
  [ "$rc" -eq 0 ] || fail "a devin spawn did not bring the pane's top-level shell into its worktree:"$'\n'"$out"
  [ "$(cat "$case_dir/shell-cwd")" = "$wt" ] ||
    fail "the pane's top-level shell ended in '$(cat "$case_dir/shell-cwd")', not the leased worktree '$wt'"
  assert_grep "worktree=$wt" "$home/state/$id.meta" "the task record did not name the leased worktree"
  assert_grep "get --lease --lease-holder fm-$id" "$case_dir/treehouse.log" \
    "the spawn did not durably lease its slot under its own holder"
  assert_no_grep "treehouse get" "$case_dir/typed.log" \
    "the spawn still typed an interactive treehouse get into the pane"
  pass "fm-spawn.sh: a devin spawn leaves the pane's top-level shell in its leased worktree, where Herdr resumes it"
}

test_devin_ancestry_detects_the_native_binary
test_devin_ancestry_rejects_unrelated_mentions
test_devin_chisel_session_db_is_not_a_marker
test_devin_control_mechanics_are_the_verified_ones
test_devin_is_crewmate_and_scout_only
test_devin_wiring_is_the_worktree_hooks_file
test_devin_busy_source_is_devin_hook
test_devin_tmux_names_the_native_binary_an_agent
test_devin_secondmate_spawn_is_refused
test_devin_spawn_leaves_the_top_level_shell_in_the_worktree
