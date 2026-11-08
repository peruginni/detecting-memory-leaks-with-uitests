#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_STARTED_SECONDS=$SECONDS

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TOOL_DIR/" && pwd)"
APP_DIR="$REPO_ROOT/memory-leaking-app"

source "$TOOL_DIR/helpers/common.sh"

# Give each run its own paths so its result, graphs, and logs stay together.
prepare_artifacts() {
  local artifacts_root="${ARTIFACTS_DIR:-$APP_DIR/artifacts/xctest-memory-diagnostics}"
  mkdir -p "$artifacts_root"
  # Keep previous runs, including logs from failed checks.
  RUN_DIR="$(mktemp -d "$artifacts_root/run-ios-$(date +%Y-%m-%d_%H-%M-%S).XXXXXX")"
  RESULT_BUNDLE="$RUN_DIR/MemoryDiagnostics.xcresult"
  ATTACHMENTS_DIR="$RUN_DIR/attachments"
  MEMGRAPHS_DIR="$RUN_DIR/memgraphs"
  TEST_LOG="$RUN_DIR/xcodebuild.log"
}

# Keep xcodebuild output visible while preserving its real exit status and log.
run_and_log_test() {
  local pipeline_status
  if [[ "${LOG_VERBOSE:-1}" -eq 0 ]]; then
    "$@" >"$TEST_LOG" 2>&1 \
      || fail "xcodebuild failed. See $TEST_LOG."
    [[ -f "$RESULT_BUNDLE/Info.plist" ]] \
      || fail "Xcode did not write a complete result bundle. See $TEST_LOG."
    return
  fi
  # Stream test output to the terminal and save it. pipefail checks both commands.
  if "$@" 2>&1 | tee "$TEST_LOG"; then
    # A partial result directory alone is not enough to proceed with export.
    [[ -f "$RESULT_BUNDLE/Info.plist" ]] \
      || fail "Xcode did not write a complete result bundle. See $TEST_LOG."
  else
    # Capture both statuses immediately: the next command would replace them.
    pipeline_status=("${PIPESTATUS[@]}")
    fail "xcodebuild exited ${pipeline_status[0]}, log writer exited ${pipeline_status[1]}. See $TEST_LOG."
  fi
}

# Unpack xcresult attachments and select only graphs captured after the test.
extract_post_test_graphs() {
  local archive contents archive_dir graph
  local archive_count=0

  mkdir -p "$MEMGRAPHS_DIR"
  # Save the file list first so a failed search stops the check. NUL separators
  # keep filenames with spaces or newlines intact when reading the list.
  find "$ATTACHMENTS_DIR" -type f ! -name manifest.json -print0 > "$RUN_DIR/attachments.list"

  while IFS= read -r -d '' archive; do
    # Exported attachments can have opaque names; inspect their contents.
    if ! contents="$(/usr/bin/tar -tf "$archive" 2>/dev/null)"; then
      continue
    fi
    if ! grep -Eq '(^|/)post_[^/]*\.memgraph$' <<<"$contents"; then
      continue
    fi

    # Separate archives may contain identical graph names; extract each on its own.
    archive_count=$((archive_count + 1))
    archive_dir="$MEMGRAPHS_DIR/$archive_count"
    mkdir -p "$archive_dir"
    /usr/bin/tar -xf "$archive" -C "$archive_dir"
  done < "$RUN_DIR/attachments.list"

  # Check snapshots taken after the flow. Ignore pre-test graphs, and require
  # at least one post-test graph before allowing a successful leak check.
  find "$MEMGRAPHS_DIR" -type f -name 'post_*.memgraph' -print0 > "$RUN_DIR/graphs.list"
  POST_TEST_GRAPHS=()
  while IFS= read -r -d '' graph; do
    POST_TEST_GRAPHS+=("$graph")
  done < "$RUN_DIR/graphs.list"
  [[ "${#POST_TEST_GRAPHS[@]}" -gt 0 ]] \
    || fail "No post-test memory graph was exported."
}

# Combine results from every post-test graph without losing an earlier leak.
record_leaks_result() {
  local status="$1"
  local output="$2"
  # Keep any previous leak finding: a later clean graph must not clear it.
  # Decide from the tool's exit status, not from the displayed summary.
  case "$status" in
    0) ;;
    1) FOUND_LEAKS=1 ;;
    *) fail "leaks exited with unexpected status $status. See $output." ;;
  esac
  python3 "$TOOL_DIR/helpers/leak_report.py" "$output" \
    > "$output.summary.txt" 2>&1 \
    || fail "Could not summarize leaks. See $output.summary.txt."
  cat "$output.summary.txt"
  echo
  log_detail "📄 Full report: $output"
}

# Show the complete workflow as test, export, extract, and check in that order.
main() {
  # Unexpected command failures stop the workflow and report an incomplete check.
  trap 'fail "Command failed at line $LINENO."' ERR
  configure_output "$@"
  configure_xcode --require-system-tools
  select_device
  prepare_artifacts

  log_step "🧪" "1/3" "Running the memory performance UI test..."
  run_and_log_test xcodebuild test \
    -quiet \
    -project "$APP_DIR/MyApp.xcodeproj" \
    -scheme MyApp \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath "${DERIVED_DATA_PATH:-$APP_DIR/.derived-data}" \
    -parallel-testing-enabled NO \
    -enableCodeCoverage NO \
    -only-testing:MyAppUITests/MyAppUITests/testRepeatedFlowWithXCTestMemoryDiagnostics \
    -enablePerformanceTestsDiagnostics YES \
    -resultBundlePath "$RESULT_BUNDLE" \
    "${SIGNING_ARGS[@]}"

  log_step "📦" "2/3" "Exporting the post-test memory graphs..."
  xcrun xcresulttool export attachments \
    --path "$RESULT_BUNDLE" \
    --output-path "$ATTACHMENTS_DIR" \
    > "$RUN_DIR/export.log" 2>&1
  if [[ "$LOG_VERBOSE" -eq 1 ]]; then
    cat "$RUN_DIR/export.log"
  fi
  extract_post_test_graphs

  log_step "🔎" "3/3" "Checking the memory graphs for leaks..."
  local graph output status
  FOUND_LEAKS=0
  for graph in "${POST_TEST_GRAPHS[@]}"; do
    output="$graph.leaks.txt"
    status=0
    # A leak finding is an expected nonzero exit; capture it and check every graph.
    /usr/bin/leaks --quiet --list "$graph" > "$output" 2>&1 || status=$?
    record_leaks_result "$status" "$output"
  done

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
