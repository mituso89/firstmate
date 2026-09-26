#!/usr/bin/env bash
# Portable Devin worker adapter regression. Vendor facts are refreshed by
# fm-devin-signals-live-e2e.test.sh; this suite needs no Devin credentials.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-devin-harness)
HARNESS="$ROOT/bin/fm-harness.sh"
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI

mkdir -p "$TMP_ROOT/names"
for name in devin devin-helper; do ln -s /bin/bash "$TMP_ROOT/names/$name"; done
# shellcheck disable=SC2016
out=$(CLAUDECODE=1 "$TMP_ROOT/names/devin" -c '"$1"; :' _ "$HARNESS")
[ "$out" = devin ] || fail "native Devin ancestry must beat foreign CLAUDECODE: $out"
# shellcheck disable=SC2016
out=$("$TMP_ROOT/names/devin-helper" -c '"$1" ancestry "$$"; :' _ "$HARNESS")
[ "$out" != 'comm devin' ] || fail "unrelated devin-helper claimed the adapter"
[ "$(fm_agent_process_classify_name /opt/bin/devin)" = agent ] || fail "liveness lost Devin"
[ "$(fm_agent_process_classify_name devin-helper)" = other ] || fail "liveness claims unrelated executable"
pass "Devin native identity; anchored liveness"

[ "$(fm_control_interrupt_key devin)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat devin)" = 2 ] || fail 'Devin needs double Escape'
[ -z "$(fm_control_interrupt_clear_key devin)" ] || fail 'Devin must not erase a composer draft'
[ "$(fm_control_exit_command devin)" = /quit ] || fail 'wrong exit command'
fm_control_harness_supports_kind devin ship || fail 'ship refused'
fm_control_harness_supports_kind devin scout || fail 'scout refused'
! fm_control_harness_supports_kind devin secondmate || fail 'secondmate accepted'
pass "worker-only resolution and lifecycle capabilities"

[ "$(fm_composer_classify_content 1 '❭ Ask Devin to build features, fix bugs, or work on your code' "$FM_COMPOSER_IDLE_RE_DEFAULT" sensitive '' 1 0)" = empty ] || fail 'idle placeholder not empty'
[ "$(fm_composer_classify_content 1 '❭ unsubmitted draft')" = pending ] || fail 'typed draft not preserved'
[ "$(fm_composer_classify_content 0 '❭')" = empty ] || fail 'Devin glyph not recognized'
for signal in 'Thinking · 5s (esc twice to interrupt)' '❭ Guide Devin while it works'; do
  printf '%s\n' "$signal" | fm_busy_lines_match devin || fail "independent delivery signal lost: $signal"
done
! printf '❭ unsubmitted draft\n' | fm_busy_lines_match devin || fail 'draft read busy'
! printf 'esc to cancel\n' | fm_busy_lines_match devin || fail 'borrowed another harness signal'
pass "composer draft safety and independent delivery signals"

state="$TMP_ROOT/hook state"
mkdir -p "$state"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker)
printf '%s\n' '{"agent":{"model":"swe-2-high"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}' > "$TMP_ROOT/user.json"
"$ROOT/bin/fm-devin-config.sh" "$state" worker "$gen" "$TMP_ROOT/user.json" || fail 'config writer failed'
config="$state/worker.devin-config.json"
jq -e '.agent.model == "swe-2-high" and (.hooks.Stop | length) == 2' "$config" >/dev/null || fail 'user settings/hooks lost'
run_hook() { bash -c "$(jq -r --arg event "$1" '.hooks[$event][-1].hooks[0].command' "$config")"; }
run_hook UserPromptSubmit
[ "$(fm_busy_classify tmux fake:w devin worker "$state")" = 'busy devin-hook' ] || fail 'submit did not open busy'
run_hook Stop
[ "$(fm_busy_classify tmux fake:w devin worker "$state")" = 'idle devin-hook' ] || fail 'Stop did not settle'
assert_present "$state/worker.turn-ended" 'Stop notification absent'
run_hook UserPromptSubmit
run_hook SessionEnd
[ "$(fm_busy_classify tmux fake:w devin worker "$state")" = 'idle devin-hook' ] || fail 'SessionEnd did not settle'
"$ROOT/bin/fm-busy-event.sh" arm "$state" worker >/dev/null
rm "$state/worker.turn-ended"
run_hook Stop
[ "$(fm_busy_classify tmux fake:w devin worker "$state")" = 'busy fm-spawn' ] || fail 'stale Stop cleared replacement'
assert_absent "$state/worker.turn-ended" 'stale Stop woke replacement'
[ "$(fm_control_harness_wiring_paths devin /unused "$state" worker)" = "$config" ] || fail 'config retirement missing'
printf 'broken' > "$TMP_ROOT/invalid.json"
! "$ROOT/bin/fm-devin-config.sh" "$state" worker "$gen" "$TMP_ROOT/invalid.json" 2>/dev/null || fail 'invalid source accepted'
jq -e . "$config" >/dev/null || fail 'failed write replaced valid config'
pass "private config preserves user hooks; lifecycle and stale-generation rejection"

# A user config that opts into both must still produce a worker config with no
# commit attribution and no imported Claude Code hooks; other import choices
# the user made survive.
printf '%s\n' '{"attribution":true,"read_config_from":{"claude":true,"cursor":false}}' > "$TMP_ROOT/opted-in.json"
"$ROOT/bin/fm-devin-config.sh" "$state" worker "$gen" "$TMP_ROOT/opted-in.json" || fail 'config writer failed'
jq -e '.attribution == false' "$config" >/dev/null \
  || fail 'worker config keeps Devin commit attribution (Co-Authored-By: Devin trailer)'
jq -e '.read_config_from.claude == false and .read_config_from.cursor == false' "$config" >/dev/null \
  || fail 'worker config imports Claude Code hooks or dropped a user import choice'
"$ROOT/bin/fm-devin-config.sh" "$state" worker "$gen" /nonexistent/config.json || fail 'absent source refused'
jq -e '.attribution == false and .read_config_from.claude == false' "$config" >/dev/null \
  || fail 'an absent user config must still disable attribution and Claude hook import'
pass "worker config forces attribution off and Claude Code hook import off"

case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
fm_fake_exit0 "$fakebin" devin
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home" devin
fm_git_worktree "$proj" "$wt" devin-test
fm_test_spawn_brief "$home" devin-worker
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch" fm_test_run_spawn "$home" "$wt" "$fakebin" devin-worker "$proj" --scout --harness devin --model fusion-claude-fable-5-1-high-sidekick-swe-2-medium --effort xhigh 2>&1)
then fail "spawn failed: $out"; fi
launch=$(cat "$case_dir/launch")
assert_contains "$launch" '--permission-mode dangerous --respect-workspace-trust false' 'autonomy/trust flags missing'
assert_contains "$launch" "--config '$home/state/devin-worker.devin-config.json'" 'private config missing'
assert_contains "$launch" "--model 'fusion-claude-fable-5-1-high-sidekick-swe-2-medium'" 'Fusion model lost'
assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
case "$launch" in *--effort*|*--thinking*) fail 'independent effort reached Devin argv' ;; esac
assert_grep 'effort=xhigh' "$home/state/devin-worker.meta" 'effort not recorded'
assert_present "$home/state/devin-worker.devin-config.json" 'spawn did not wire hooks'
[ "$(fm_busy_classify tmux fake:w devin devin-worker "$home/state")" = 'busy fm-spawn' ] || fail 'launch not armed'
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" devin-sm "$proj" --secondmate --harness devin 2>&1)
then fail 'Devin secondmate launch accepted'; fi
assert_contains "$out" 'crewmate/scout adapter only' 'wrong secondmate refusal'
pass "scout launch carries Fusion, autonomy, typed brief and hooks; effort recorded only"

# A Herdr restore resumes a recorded Devin session (`devin --resume <id>`) in the
# pane's saved TOP-LEVEL shell cwd, and Devin stops on its directory chooser when
# that is not the session's own directory (the real restore is pinned by
# tests/fm-devin-herdr-restore-e2e.test.sh). The fake tmux here models a pane
# whose reported cwd is its top-level shell's, which moves only on a top-level
# `cd` or where its window was created, never into a subshell such as an
# interactive `treehouse get`. A Devin spawn must durably lease its slot and
# leave that top-level shell in exactly the leased worktree.
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
if ! out=$(FM_FAKE_SHELL_CWD="$case_dir/shell-cwd" FM_FAKE_TYPED_LOG="$case_dir/typed.log" \
  FM_FAKE_TREEHOUSE_LEASE_PATH="$wt" FM_TREEHOUSE_LOG="$case_dir/treehouse.log" \
  fm_test_run_spawn "$home" "$proj" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
then fail "a devin spawn did not bring the pane's top-level shell into its worktree:"$'\n'"$out"; fi
[ "$(cat "$case_dir/shell-cwd")" = "$wt" ] ||
  fail "the pane's top-level shell ended in '$(cat "$case_dir/shell-cwd")', not the leased worktree '$wt'"
assert_grep "worktree=$wt" "$home/state/$id.meta" 'the task record did not name the leased worktree'
assert_grep "get --lease --lease-holder fm-$id" "$case_dir/treehouse.log" \
  'the spawn did not durably lease its slot under its own holder'
assert_no_grep "treehouse get" "$case_dir/typed.log" \
  'the spawn still typed an interactive treehouse get into the pane'
pass "a devin spawn leaves the pane's top-level shell in its leased worktree, where Herdr resumes it"
