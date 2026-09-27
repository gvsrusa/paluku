#!/bin/zsh
# Unit tests (no network). Set PALUKU_LIVE=1 to also hit local Ollama/Whisper/MCP.
# Full log (each line prefixed with seconds since start) goes to /tmp/paluku-test.log. On failure, or if the run exceeds
# PALUKU_TEST_TIMEOUT seconds (default 300), it prints slow/unfinished tests and a stack sample of the test process.
set -uo pipefail
cd "$(dirname "$0")/../Packages/PalukuCore"
LOG=/tmp/paluku-test.log
: > $LOG
swift build --build-tests -q 2>&1 | grep -E "error:" && exit 1
swift test --skip-build --parallel 2>&1 | perl -MTime::HiRes=time -ne 'BEGIN{$|=1; $t=time} printf "%7.2f %s", time-$t, $_' > $LOG &
RUN=$!
LIMIT=${PALUKU_TEST_TIMEOUT:-300}
SAMPLE=/tmp/paluku-test-sample.txt; : > $SAMPLE
testpid() { pgrep -n -f "testing-helper --test-bundle-path" || pgrep -n -x PalukuCoreTests; }
for (( i = 0; i < LIMIT; i++ )); do
  kill -0 $RUN 2>/dev/null || break
  # The suite takes ~1 s; anything still running at 15 s is stalled, so capture where.
  (( i == 15 )) && PID=$(testpid) && { sample "$PID" 2 -file $SAMPLE >/dev/null 2>&1 & SPID=$!; }
  sleep 1
done
[[ -n ${SPID:-} ]] && wait $SPID 2>/dev/null

report() {
  echo "--- tests that took over 5 s or never finished:"
  perl -ne 'if (/^\s*([\d.]+) .*Test (\S+?)\(.*\) started/) { $s{$2}=$1 } if (/^\s*([\d.]+) .*Test (\S+?)\(.*\) (passed|failed) after/) { printf "%-60s %6.1fs\n", $2, $1-$s{$2} if $1-$s{$2} > 5; delete $s{$2} } END { print "$_ (never finished)\n" for keys %s }' $LOG
}

if kill -0 $RUN 2>/dev/null; then
  echo "✘ unit tests still running after ${LIMIT}s"
  report
  [[ -s $SAMPLE ]] && { echo "--- stack sample at 15 s:"; grep -vE "^\s*$" $SAMPLE | head -200; }
  pkill -f "testing-helper --test-bundle-path"; kill $RUN 2>/dev/null
  exit 1
fi
grep -E "✘|error:|Test run|passed|failed" $LOG | grep -vE "✔ Test [a-z]" | cut -c9-
if [[ -s $SAMPLE ]]; then  # passed, but something stalled for 15 s+
  report
  echo "--- stack sample at 15 s:"; grep -vE "^\s*$" $SAMPLE | head -200
fi
grep -q "Test run with .* passed" $LOG || { report; exit 1; }
