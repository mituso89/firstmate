#!/usr/bin/env bash
# Lab-only driver: replays bin/fm-watch.sh's secondmate_liveness_tick body
# (probe poll -> relaunch bound check -> fm_secondmate_liveness_relaunch) every
# 60s against ONE lab secondmate whose endpoint is a pane in an fm-lab-* herdr
# session. FM_ROOT points at a lab fakeroot whose bin/fm-spawn.sh only records
# its invocation, so the relaunch cannot create panes anywhere real.
# Usage: driver.sh <worktree> <lab-home> <id> <ticks> <logfile>
set -u
WT=$1 LAB=$2 ID=$3 TICKS=$4 LOG=$5
export FM_HOME=$LAB FM_ROOT=$LAB/fakeroot STATE=$LAB/state
export FM_SECONDMATE_LIVENESS_SECS=60
unset FM_WEDGE_ALARM_EXEC FM_WEDGE_ALARM_CHANNEL
. "$WT/bin/fm-secondmate-liveness-lib.sh"
meta=$STATE/$ID.meta
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
MAX_ATTEMPTS=3 WINDOW_SECS=3600 TIMEOUT=120
for ((t = 0; t < TICKS; t++)); do
  mode=poll
  [ "$t" -gt 0 ] || mode=full
  fm_secondmate_liveness_lock "$ID" || { log "tick=$t lock busy"; sleep 60; continue; }
  fm_secondmate_liveness_probe "$meta" "$ID" "$mode"
  rec=$(tr '\t' ' ' < "$STATE/.secondmate-wedge-$ID" 2>/dev/null)
  log "tick=$t mode=$mode status=$FM_SM_LIVE_STATUS state=$FM_SM_LIVE_STATE kill=$FM_SM_LIVE_KILL wedge=$FM_SM_LIVE_WEDGE record=[$rec]"
  if [ "$FM_SM_LIVE_STATUS" = relaunchable ]; then
    attempts=$(fm_secondmate_liveness_recent_attempts "$ID" "$WINDOW_SECS")
    log "tick=$t cause=\"$FM_SM_LIVE_CAUSE\" where=$FM_SM_LIVE_WHERE recent_attempts=$attempts"
    if [ "$attempts" -lt "$MAX_ATTEMPTS" ]; then
      rc=0
      fm_secondmate_liveness_relaunch "$meta" "$ID" "$TIMEOUT" || rc=$?
      log "tick=$t relaunch rc=$rc status=$FM_SM_LIVE_STATUS reason=\"$FM_SM_LIVE_REASON\" capture=$FM_SM_LIVE_WEDGE_CAPTURE killed=[$FM_SM_LIVE_WEDGE_KILLED]"
      log "tick=$t spawn output: $(printf '%s' "$FM_SM_LIVE_OUT" | tr '\n' ' ')"
      fm_secondmate_liveness_unlock "$ID"
      log "tick=$t post-kill ps: $(ps -o pid=,stat=,args= -p "$CHECK_PIDS" 2>&1 | tr '\n' ';')"
      log "tick=$t post-relaunch panes: $(HERDR_SESSION=$HS herdr pane list --session "$HS" 2>&1 | tr '\n' ' ')"
      log "DONE after recovery"
      exit 0
    fi
  fi
  fm_secondmate_liveness_unlock "$ID"
  [ "$t" -eq $((TICKS - 1)) ] || sleep 60
done
log "DONE without a recovery"
