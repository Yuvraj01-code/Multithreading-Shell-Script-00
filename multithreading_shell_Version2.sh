#!/usr/bin/env bash
# Spawn N instances of a script every second (backgrounded), continuously.
# Usage:
#   ./multithreading_shell.sh <instances_per_second> /path/to/scriptA [scriptA-arg1 ...]
#
# Optional environment variables:
#   MAX_CONCURRENT  - if set, don't start new instances when pgrep count for script >= this
#   LOGFILE         - default ./multithreading_shell.log
#   USE_NOHUP       - if set to "0" don't use nohup, otherwise uses nohup (default: use nohup)
#
# Notes:
#  - This doesn't "wait" for spawned jobs; it backgrounds them and continues to spawn.
#  - Ensure your /path/to/scriptA sets any Oracle env (ORACLE_HOME, ORACLE_SID, PATH, etc.)
#    and is safe to run many times in parallel.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  cat <<EOF
Usage: $0 <instances_per_second> /path/to/scriptA [scriptA-arg1 ...]
Optional environment variables:
  MAX_CONCURRENT (integer) - maximum concurrent processes matching scriptA (skip spawn until below)
  LOGFILE - where spawn logs are written (default: ./multithreading_shell.log)
  USE_NOHUP - "0" to disable nohup, otherwise nohup is used (default enabled)
Example:
  MAX_CONCURRENT=500 LOGFILE=/tmp/multi.log ./multithreading_shell.sh 25 /home/me/run_oracle_job.sh arg1 arg2
EOF
  exit 2
fi

INSTANCES="$1"
shift
SCRIPT="$1"
shift
SCRIPT_ARGS=("$@")

# Validate INSTANCES
if ! [[ "$INSTANCES" =~ ^[0-9]+$ ]] || [[ "$INSTANCES" -le 0 ]]; then
  echo "Error: instances_per_second must be a positive integer." >&2
  exit 2
fi

# Validate script
if [[ ! -x "$SCRIPT" ]]; then
  echo "Error: script '$SCRIPT' not found or not executable." >&2
  exit 2
fi

LOGFILE="${LOGFILE:-./multithreading_shell.log}"
USE_NOHUP="${USE_NOHUP:-1}"
MAX_CONCURRENT="${MAX_CONCURRENT:-}"

# Graceful shutdown
STOP=0
trap 'STOP=1; echo "$(date -Is) - SIG received, stopping spawner (no wait for spawned children)";' SIGINT SIGTERM

echo "$(date -Is) - Starting spawner: $INSTANCES/s -> $SCRIPT ${SCRIPT_ARGS[*]}" | tee -a "$LOGFILE"

# Helper to count running instances (simple pgrep; adjust pattern if necessary)
count_running() {
  # count processes matching the script path (may need tuning for your environment)
  pgrep -f -- "$SCRIPT" >/dev/null 2>&1 || { echo 0; return; }
  pgrep -f -- "$SCRIPT" | wc -l
}

# Main loop: spawn INSTANCES every 1 second (attempt to keep the 1s interval)
while [[ $STOP -eq 0 ]]; do
  start_ns=$(date +%s%N)

  for i in $(seq 1 "$INSTANCES"); do
    # If MAX_CONCURRENT is set, wait until number of running instances is below that limit
    if [[ -n "$MAX_CONCURRENT" ]]; then
      # busy wait briefly but yield CPU
      while :; do
        current=$(count_running)
        if (( current < MAX_CONCURRENT )); then
          break
        fi
        # If stop requested, break out
        if [[ $STOP -eq 1 ]]; then break 2; fi
        sleep 0.1
      done
    fi

    if [[ "$USE_NOHUP" == "0" ]]; then
      "$SCRIPT" "${SCRIPT_ARGS[@]}" >/dev/null 2>&1 &
      pid=$!
    else
      nohup "$SCRIPT" "${SCRIPT_ARGS[@]}" >/dev/null 2>&1 &
      pid=$!
      disown "$pid" 2>/dev/null || true
    fi

    echo "$(date -Is) spawned pid=$pid instance=$i" >>"$LOGFILE" || true
  done

  # Keep a 1-second cadence (account for time used to spawn)
  end_ns=$(date +%s%N)
  elapsed_ns=$((end_ns - start_ns))
  # compute remaining nanoseconds to reach 1s
  rem_ns=$((1000000000 - elapsed_ns))
  if (( rem_ns > 0 )); then
    # convert to seconds with microsecond precision
    rem_s=$(awk -v n="$rem_ns" 'BEGIN{printf "%.6f", n/1e9}')
    # sleep supports fractional seconds
    sleep "$rem_s"
  else
    # took longer than 1s to spawn; continue immediately (no sleep)
    :
  fi
done

echo "$(date -Is) - Spawner exiting." | tee -a "$LOGFILE"
exit 0