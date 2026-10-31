#!/bin/zsh
# Runtime checks: builds a debug app with a sanitizer, runs a scripted scenario through
# the doppio:// URL scheme and reports sanitizer / Main Thread Checker findings.
#
#   scripts/qa.sh address     # Address Sanitizer + Main Thread Checker
#   scripts/qa.sh thread      # Thread Sanitizer
#   scripts/qa.sh leaks       # release build, scenario × N, then `leaks` and memory footprint
#
# The scenario creates and removes a virtual display, opens previews, shows the built-in
# display on it (software mirror), opens the menu bar panel, the floating panel and every
# settings section. It quits a running DoppioDisplay first.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

MODE="${1:-address}"
ROUNDS="${ROUNDS:-3}"
QA_APP="build/QA/DoppioDisplay.app"
LOG="build/QA/$MODE.log"

./scripts/build-app.sh >/dev/null
rm -rf build/QA && mkdir -p build/QA && cp -R build/DoppioDisplay.app "$QA_APP"

ENV=()
case "$MODE" in
    address|thread)
        swift build -c debug --sanitize="$MODE" --scratch-path ".build/qa-$MODE" >/dev/null
        cp ".build/qa-$MODE/debug/DoppioDisplay" "$QA_APP/Contents/MacOS/DoppioDisplay"
        ;;
    leaks)
        # Stack logging makes leak reports useful but inflates the footprint; NOMSL=1 measures memory only.
        [[ -z "${NOMSL:-}" ]] && ENV+=(MallocStackLogging=1)
        ;;
esac
if [[ "$MODE" == address ]]; then
    ENV+=(DYLD_INSERT_LIBRARIES="$DEVELOPER_DIR/usr/lib/libMainThreadChecker.dylib" MTC_RESET_INSERT_LIBRARIES=0)
fi
codesign --force --sign "DoppioDisplay Local Signing" --identifier app.doppiodisplay "$QA_APP" 2>/dev/null \
    || codesign --force --sign - --identifier app.doppiodisplay "$QA_APP"

osascript -e 'tell application id "app.doppiodisplay" to quit' 2>/dev/null || true
sleep 2
env ${ENV[@]+"${ENV[@]}"} "$QA_APP/Contents/MacOS/DoppioDisplay" >"$LOG" 2>&1 &
PID=$!
sleep 5

url() { open -g "doppio://$1"; sleep "${2:-1.5}"; }
footprint_mb() { footprint -p "$PID" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}'; }

echo "start footprint: $(footprint_mb)"
for round in $(seq 1 "$ROUNDS"); do
    url "create?width=1920&height=1080&name=QA%20Display" 4
    url "preview?name=QA&action=hide"
    url "preview?name=QA&action=show" 3
    url "resolution?name=QA&width=2560&height=1440" 5
    url "resolution?name=QA&width=1280&height=720&hidpi=0" 5
    url "show?name=QA&source=builtin&on=1" 3
    url "show?name=QA&source=builtin&on=0" 2
    url "menu" 1
    url "panel?expand=builtin,virtual,arrangement,color" 2
    for section in general preview brightness profiles shortcuts automation permissions about; do
        url "settings?section=$section" 0.8
    done
    url "xdr?on=1" 2
    url "xdr?on=0" 1
    url "remove?name=QA" 3
    echo "round $round footprint: $(footprint_mb)"
done

if [[ "$MODE" == leaks ]]; then
    leaks "$PID" > "build/QA/leaks.txt" 2>&1 || true
    grep -E "leaks for|total leaked bytes" "build/QA/leaks.txt" | head -3
fi

if [[ -n "${KEEP:-}" ]]; then
    echo "kept running: pid $PID"
    exit 0
fi
kill -TERM "$PID" 2>/dev/null || true
sleep 2
kill -KILL "$PID" 2>/dev/null || true
echo "--- findings ($LOG)"
grep -E "ERROR: AddressSanitizer|WARNING: ThreadSanitizer|Main Thread Checker|SUMMARY:" "$LOG" | sort | uniq -c | head -40 || echo "none"
