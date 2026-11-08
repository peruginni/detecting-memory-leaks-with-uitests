#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_STARTED_SECONDS=$SECONDS

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TOOL_DIR/" && pwd)"
APP_DIR="$REPO_ROOT/memory-leaking-app"

source "$TOOL_DIR/helpers/common.sh"

prepare_artifacts() {
  local root="${ARTIFACTS_DIR:-$APP_DIR/artifacts/xctrace-leaks}"
  mkdir -p "$root"
  RUN_DIR="$(mktemp -d "$root/run-ios-$(date +%Y-%m-%d_%H-%M-%S).XXXXXX")"
  TRACE_PATH="$RUN_DIR/Leaks.trace"
  TOC_XML="$RUN_DIR/toc.xml"
  LEAKS_XML="$RUN_DIR/leaks.xml"
  ALLOCATIONS_XML="$RUN_DIR/allocations.xml"
  BUILD_LOG="$RUN_DIR/build.log"
  TEST_LOG="$RUN_DIR/xcodebuild.log"
  RECORD_LOG="$RUN_DIR/xctrace.log"
  DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$APP_DIR/.derived-data}"
  XCTRACE_TEMPLATE="${XCTRACE_TEMPLATE:-Leaks}"
}

cleanup() {
  # Stop only the background jobs started by this run.
  local pid
  for pid in "${TEST_PID:-}" "${RECORD_PID:-}"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}

run_logged() {
  local log="$1"
  shift
  "$@" >"$log" 2>&1 || fail "Command failed. See $log."
}

find_app_pid() {
  # Convert the supported JSON process list to a plist for XPath lookup.
  # devicectl's predicate handling varies with the executable URL type.
  xcrun devicectl device info processes --device "$DEVICE_ID" \
    --json-output "$RUN_DIR/processes.json" --quiet --timeout 5 \
    >"$RUN_DIR/process-lookup.log" 2>&1 || return 1
  plutil -extract result.runningProcesses xml1 \
    -o "$RUN_DIR/processes.plist" "$RUN_DIR/processes.json" || return 1
  /usr/bin/xmllint --nonet --xpath \
    "string((//dict[key[.='executable']/following-sibling::*[1][substring(., string-length(.) - string-length('/MyApp') + 1) = '/MyApp']]/key[.='processIdentifier']/following-sibling::*[1])[last()])" \
    "$RUN_DIR/processes.plist"
}

wait_for_app() {
  local deadline=$((SECONDS + ${APP_START_WAIT_SECONDS:-60}))
  # Ignore a leftover app process until XCTest launches a new instance.
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    kill -0 "$TEST_PID" 2>/dev/null || fail "UI test ended before attachment. See $TEST_LOG."
    APP_PID="$(find_app_pid || true)"
    if [[ -n "$APP_PID" && "$APP_PID" != "$PREVIOUS_APP_PID" ]]; then
      log_detail "Attaching to MyApp on $DEVICE_ID (PID $APP_PID)."
      return
    fi
    sleep 0.25
  done
  fail "App did not launch in time. See $TEST_LOG and $RUN_DIR/process-lookup.log."
}

wait_for_recording() {
  local deadline=$((SECONDS + ${RECORD_START_WAIT_SECONDS:-30}))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if grep -Eq 'Starting recording|Ctrl-C to stop the recording' "$RECORD_LOG"; then
      return
    fi
    kill -0 "$RECORD_PID" 2>/dev/null || fail "Recorder stopped before starting. See $RECORD_LOG."
    sleep 0.5
  done
  fail "Recorder did not start in time. See $RECORD_LOG."
}

finish_recording() {
  local test_status=0 record_status=0
  wait "$TEST_PID" || test_status=$?
  TEST_PID=""
  # xctrace's time limit bounds the recording; wait also reaps its process.
  wait "$RECORD_PID" || record_status=$?
  RECORD_PID=""
  [[ "$test_status" -eq 0 ]] || fail "UI test exited $test_status. See $TEST_LOG."
  [[ -d "$TRACE_PATH" ]] || fail "No trace was saved. See $RECORD_LOG."
  if [[ "$record_status" -ne 0 ]]; then
    # The app may exit before the recording limit. Export must still succeed.
    echo "Recorder exited $record_status; validating the saved trace."
  fi
}

# Retry one exporter crash without repeating the test or recording.
export_trace() {
  local output="$1"
  shift
  local attempt status
  for attempt in 1 2; do
    if { xcrun xctrace export --input "$TRACE_PATH" "$@" --output "$output"; } \
      >>"$RECORD_LOG" 2>&1; then
      /usr/bin/xmllint --nonet --noout "$output" >>"$RECORD_LOG" 2>&1 \
        || fail "Invalid exported XML. See $RECORD_LOG."
      return
    else
      status=$?
    fi
    if [[ "$status" -ne 139 || "$attempt" -eq 2 ]]; then
      fail "Trace export exited $status. See $RECORD_LOG."
    fi
    echo "⚠️ Instruments export crashed; retrying once..."
    # Discard partial output before retrying in a fresh exporter process.
    rm -f "$output"
  done
}

check_leaks() {
  local status=0
  python3 "$TOOL_DIR/helpers/check_xctrace_leaks.py" \
    "$LEAKS_XML" "$ALLOCATIONS_XML" "$RUN_DIR" \
    > "$RUN_DIR/analysis.log" 2>&1 || status=$?
  if [[ "$LOG_VERBOSE" -eq 1 || "$status" -le 1 ]]; then
    cat "$RUN_DIR/analysis.log"
  fi
  case "$status" in
    0|1) FOUND_LEAKS="$status" ;;
    *) fail "Leak analysis failed. Inspect $LEAKS_XML and $ALLOCATIONS_XML." ;;
  esac
}

main() {
  trap 'fail "Command failed at line $LINENO."' ERR
  configure_output "$@"
  configure_xcode
  select_device
  prepare_artifacts
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # Share destination and signing options across build and test commands.
  local build_args=(
    -project "$APP_DIR/MyApp.xcodeproj"
    -scheme MyApp
    -destination "platform=iOS,id=$DEVICE_ID"
    -derivedDataPath "$DERIVED_DATA_PATH"
    -only-testing:MyAppUITests/MyAppUITests/testRepeatedFlowForInstrumentsAndXctrace
    "${SIGNING_ARGS[@]}"
  )

  log_step "🔨" "1/5" "Building and installing the app..."
  run_logged "$BUILD_LOG" xcodebuild build-for-testing "${build_args[@]}"
  xcrun devicectl device install app --device "$DEVICE_ID" \
    "${APP_BUNDLE_PATH:-$DERIVED_DATA_PATH/Build/Products/Debug-iphoneos/MyApp.app}" \
    --quiet --timeout 30 >>"$BUILD_LOG" 2>&1

  log_step "🧪" "2/5" "Starting the UI test..."
  PREVIOUS_APP_PID="$(find_app_pid || true)"
  xcodebuild test-without-building "${build_args[@]}" \
    -parallel-testing-enabled NO -enableCodeCoverage NO \
    >"$TEST_LOG" 2>&1 &
  TEST_PID=$!
  wait_for_app

  log_step "🎥" "3/5" "Recording with the Leaks instrument..."
  xcrun xctrace record \
    --template "$XCTRACE_TEMPLATE" \
    --device "$DEVICE_ID" \
    --attach "$APP_PID" \
    --time-limit "${XCTRACE_TIME_LIMIT:-60s}" \
    --output "$TRACE_PATH" \
    --no-prompt >"$RECORD_LOG" 2>&1 &
  RECORD_PID=$!
  wait_for_recording
  finish_recording

  log_step "📦" "4/5" "Exporting Leaks and Allocations tables..."
  export_trace "$TOC_XML" --toc
  export_trace "$LEAKS_XML" \
    --xpath "${LEAKS_EXPORT_XPATH:-/trace-toc/run[@number=\"1\"]/tracks/track[@name=\"Leaks\"]/details/detail[@name=\"Leaks\"]}"
  export_trace "$ALLOCATIONS_XML" \
    --xpath "${ALLOCATIONS_EXPORT_XPATH:-/trace-toc/run[@number=\"1\"]/tracks/track[@name=\"Allocations\"]/details/detail[@name=\"Allocations List\"]}"

  log_step "🔎" "5/5" "Checking leaks..."
  check_leaks
  echo
  if [[ "$FOUND_LEAKS" -eq 1 ]]; then
    echo "❌ Leak check failed: leaks were found."
  else
    echo "✅ Leak check passed: no leaks found."
  fi
  show_duration
  show_artifacts
  exit "$FOUND_LEAKS"
}

main "$@"
