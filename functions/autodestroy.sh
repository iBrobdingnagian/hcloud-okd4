#!/usr/bin/env bash
# functions/autodestroy.sh — teardown scheduling (macOS launchd / Linux systemd or at)
# Sourced by deploy-okd.sh; not meant to be executed directly.

schedule_autodestroy() {
AD_DUR=${FLAG_AUTODESTROY_AT:-$DUR}
case "$AD_DUR" in
  *m) AD_HOURS=$(awk -v m="${AD_DUR%m}" 'BEGIN{printf "%.4f", m/60}') ;;
  *)  AD_HOURS=$AD_DUR ;;
esac
awk -v h="$AD_HOURS" 'BEGIN{exit !(h+0>0)}' || err "invalid --autodestroy-at: $FLAG_AUTODESTROY_AT"
DEADLINE_TS=$(( $(date +%s) + $(awk -v h="$AD_HOURS" 'BEGIN{printf "%d", h*3600}') ))
if [ "$(uname)" = "Darwin" ]; then
  DEADLINE_HUMAN=$(date -r "$DEADLINE_TS" '+%Y-%m-%d %H:%M')
else
  DEADLINE_HUMAN=$(date -d "@$DEADLINE_TS" '+%Y-%m-%d %H:%M')
fi
AUTODESTROY_NOTE="teardown deadline: $DEADLINE_HUMAN — NOT scheduled, run ./destroy-okd.sh yourself"
if [ "$(uname)" = "Darwin" ] && [ "$NO_AUTODESTROY" = 0 ]; then
  if [ "$ASSUME_YES" = 1 ]; then SCHED=y
  else
    printf '\nSchedule auto-destroy at %s? [Y/n]: ' "$DEADLINE_HUMAN"
    read -r SCHED; SCHED=${SCHED:-y}
  fi
  if [ "$SCHED" = "y" ] || [ "$SCHED" = "Y" ]; then
    LABEL=com.hcloud-okd4.autodestroy
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    UID_N=$(id -u)
    launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null || true
    mkdir -p "$HOME/Library/LaunchAgents"
    D_MON=$((10#$(date -r "$DEADLINE_TS" +%m)))
    D_DAY=$((10#$(date -r "$DEADLINE_TS" +%d)))
    D_HR=$((10#$(date -r "$DEADLINE_TS" +%H)))
    D_MIN=$((10#$(date -r "$DEADLINE_TS" +%M)))
    # the job boots itself out LAST (bootout SIGTERMs the job's own shell);
    # destroy-okd.sh skips its cancel logic when HCLOUD_OKD4_SCHEDULED=1
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>EnvironmentVariables</key><dict>
    <key>HCLOUD_OKD4_SCHEDULED</key><string>1</string>
  </dict>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>-c</string>
    <string>cd $PWD &amp;&amp; ./destroy-okd.sh --yes &gt;&gt; autodestroy.log 2&gt;&amp;1; rm -f $PLIST; launchctl bootout gui/$UID_N/$LABEL</string>
  </array>
  <key>StartCalendarInterval</key><dict>
    <key>Month</key><integer>$D_MON</integer>
    <key>Day</key><integer>$D_DAY</integer>
    <key>Hour</key><integer>$D_HR</integer>
    <key>Minute</key><integer>$D_MIN</integer>
  </dict>
</dict></plist>
PLISTEOF
    if launchctl bootstrap "gui/$UID_N" "$PLIST" 2>/dev/null; then
      AUTODESTROY_NOTE="auto-destroy : scheduled for $DEADLINE_HUMAN (fires on next wake if the Mac slept past it)
  cancel with : launchctl bootout gui/$UID_N/$LABEL   (a manual ./destroy-okd.sh also cancels it)"
    else
      rm -f "$PLIST"
      AUTODESTROY_NOTE="auto-destroy : scheduling FAILED — run ./destroy-okd.sh manually by $DEADLINE_HUMAN"
    fi
  fi
elif [ "$(uname)" = "Linux" ] && [ "$NO_AUTODESTROY" = 0 ]; then
  if [ "$ASSUME_YES" = 1 ]; then SCHED=y
  else
    printf '\nSchedule auto-destroy at %s? [Y/n]: ' "$DEADLINE_HUMAN"
    read -r SCHED; SCHED=${SCHED:-y}
  fi
  if [ "$SCHED" = "y" ] || [ "$SCHED" = "Y" ]; then
    UNIT=hcloud-okd4-autodestroy
    AD_SECONDS=$(( DEADLINE_TS - $(date +%s) ))
    [ "$AD_SECONDS" -gt 0 ] || AD_SECONDS=60
    # cancel any previous timer for this checkout first
    systemctl --user stop "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1 || true
    rm -f .autodestroy-atjob
    if command -v systemd-run >/dev/null 2>&1 && systemd-run --user \
        --unit="$UNIT" \
        --on-active="${AD_SECONDS}s" \
        bash -c "cd $PWD && HCLOUD_OKD4_SCHEDULED=1 ./destroy-okd.sh --yes >> autodestroy.log 2>&1" >/dev/null 2>&1; then
      AUTODESTROY_NOTE="auto-destroy : scheduled for $DEADLINE_HUMAN via systemd --user timer ($UNIT.timer)
  cancel with : systemctl --user stop $UNIT.timer $UNIT.service   (a manual ./destroy-okd.sh also cancels it)
  NOTE: --user timers only fire while you are logged in, unless lingering is
  enabled (sudo loginctl enable-linger \$USER)."
    elif command -v at >/dev/null 2>&1 && AT_OUT=$(printf 'cd %s && HCLOUD_OKD4_SCHEDULED=1 ./destroy-okd.sh --yes >> autodestroy.log 2>&1\n' "$PWD" \
        | at -M "now + $(( (AD_SECONDS + 59) / 60 )) minutes" 2>&1); then
      AT_JOB=$(echo "$AT_OUT" | grep -oE 'job [0-9]+' | awk '{print $2}')
      [ -n "$AT_JOB" ] && echo "$AT_JOB" > .autodestroy-atjob
      AUTODESTROY_NOTE="auto-destroy : scheduled for $DEADLINE_HUMAN via 'at' (job ${AT_JOB:-?})
  cancel with : atrm ${AT_JOB:-<job-id>}   (a manual ./destroy-okd.sh also cancels it)"
    else
      AUTODESTROY_NOTE="auto-destroy : scheduling FAILED (no systemd --user or at available) — run ./destroy-okd.sh manually by $DEADLINE_HUMAN"
    fi
  fi
fi
}
