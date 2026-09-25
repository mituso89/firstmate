#!/usr/bin/env bash
# tests/fm-devin-herdr-restore-e2e.test.sh - isolated real-Herdr regression for
# a Devin worker coming back after a Herdr server restart.
#
# Herdr saves each pane's top-level shell cwd and, on restore, types the pane's
# recorded agent session back into a fresh shell there (`devin --resume <id>`).
# Spawns used to leave that top-level shell in the project and enter the task
# worktree through an interactive `treehouse get` subshell, so every restored
# Devin worker resumed in the project and stopped on Devin's "Resume this
# session from which directory?" chooser, where every answer but the first ran
# it in the primary checkout.
#
# This drives the REAL bin/fm-spawn.sh against real Treehouse and a real,
# isolated Herdr lab session. The launched agent is a stand-in executable named
# `devin`, so Herdr recognizes it as a Devin agent, and it reports a Devin
# session id the way Herdr's own Devin integration does. The test then stops
# and restarts the lab server and asserts the restored pane's top-level shell
# and the resumed `devin --resume <id>` both run in the task's recorded
# worktree, never the project.
#
# Safety (tests/herdr-test-safety.sh): every Herdr lifecycle call goes through
# bin/fm-herdr-lab.sh against this test's own session; the live `default`
# session is never touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-devin-restore.XXXXXX")
SESSION="fm-lab-devin-restore-$$"
export HERDR_SESSION="$SESSION"
WT=
cleanup_all() {
  [ -z "$WT" ] || (cd "$PROJ" && treehouse return --force "$WT") >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# The stand-in `devin` must be what a restored shell resolves, so it leads the
# PATH the lab server, and every pane shell it starts, inherits.
FAKEBIN="$TMP_ROOT/fakebin"
RESUME_LOG="$TMP_ROOT/resume.log"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/devin" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --resume ]; then
  printf '%s %s\n' "\$2" "\$(pwd -P)" >> '$RESUME_LOG'
else
  herdr pane report-agent-session "\$HERDR_PANE_ID" --source herdr:devin --agent devin \\
    --agent-session-id fm-e2e-resume --session "\$HERDR_SESSION" >/dev/null 2>&1
fi
exec sleep 600
SH
chmod +x "$FAKEBIN/devin"
export PATH="$FAKEBIN:$PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/dv1" "$HOME_DIR/config"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
cat > "$HOME_DIR/data/dv1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise a Devin worker surviving a Herdr restart.

## Firstmate spec
Verify the restored worker resumes in its own worktree.
EOF

PROJ="$TMP_ROOT/project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
PROJ_REAL=$(cd "$PROJ" && pwd -P)

OUT="$TMP_ROOT/spawn.out"
FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" dv1 "$PROJ" "$FAKEBIN/devin start" --mode no-mistakes --yolo off --backend herdr \
  >"$OUT" 2>&1 || fail "the Devin-shaped spawn failed"$'\n'"$(cat "$OUT")"

META="$HOME_DIR/state/dv1.meta"
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
[ -n "$WT" ] && [ -n "$PANE" ] || fail "spawn did not record a worktree and a Herdr pane"$'\n'"$(cat "$META")"
WT_REAL=$(cd "$WT" && pwd -P)
[ "$WT_REAL" != "$PROJ_REAL" ] || fail "spawn recorded the project itself as the worktree"

pane_cwd() {
  fm_herdr_lab_cli "$SESSION" pane get "$PANE" 2>/dev/null | jq -r '.result.pane.cwd // empty'
}
real_or_raw() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

[ "$(real_or_raw "$(pane_cwd)")" = "$WT_REAL" ] ||
  fail "the task pane's top-level shell is in '$(pane_cwd)', not the recorded worktree '$WT'"
pass "real herdr E2E: a spawned task pane's top-level shell sits in the recorded worktree"

reported=
for _ in $(seq 1 40); do
  reported=$(fm_herdr_lab_cli "$SESSION" pane get "$PANE" 2>/dev/null | jq -r '.result.pane.agent_session.value // empty')
  [ -z "$reported" ] || break
  sleep 0.5
done
[ "$reported" = fm-e2e-resume ] || fail "Herdr never recorded the stand-in Devin session (got '${reported:-none}')"

fm_herdr_lab_stop "$SESSION" >/dev/null 2>&1 || fail "could not stop the isolated session for the restart"
sleep 0.5
fm_backend_herdr_server_ensure "$SESSION" || fail "the isolated session's server did not come back up after the restart"

resumed=
for _ in $(seq 1 60); do
  [ -s "$RESUME_LOG" ] && resumed=$(head -n 1 "$RESUME_LOG") && break
  sleep 0.5
done
[ -n "$resumed" ] ||
  fail "Herdr did not resume the recorded Devin session after the restart; pane shows:"$'\n'"$(fm_herdr_lab_cli "$SESSION" pane read "$PANE" --source visible --format text 2>/dev/null)"
[ "$resumed" = "fm-e2e-resume $WT_REAL" ] ||
  fail "the restored Devin session resumed as '$resumed', expected 'fm-e2e-resume $WT_REAL' (the recorded worktree, never the project '$PROJ_REAL')"
[ "$(real_or_raw "$(pane_cwd)")" = "$WT_REAL" ] ||
  fail "the restored pane's top-level shell is in '$(pane_cwd)', not the recorded worktree '$WT'"
pass "real herdr E2E: after a server restart Herdr resumes the Devin session inside the recorded worktree, so no directory chooser appears"
