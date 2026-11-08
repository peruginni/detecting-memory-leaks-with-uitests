#!/usr/bin/env bash
# Shared setup. Sourcing only defines functions.

# Choose how much output to show.
configure_output() {
  LOG_VERBOSE=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --quiet) LOG_VERBOSE=0 ;;
      --verbose) LOG_VERBOSE=1 ;;
      -h|--help)
        echo "Usage: ${0##*/} [--quiet|--verbose]"
        echo "  --quiet    Show progress and leaks; save tool output and paths to logs (default)."
        echo "  --verbose  Show tool output and full paths."
        exit 0 ;;
      *) fail "Unknown option: $1" ;;
    esac
    shift
  done
}

# Print a phase with its start time.
log_step() {
  printf '\n%s [%s] [%s] %s\n' "$1" "$2" "$(date +%H:%M:%S)" "$3"
}

# Show elapsed time since the script started.
show_duration() {
  if [[ -n "${SCRIPT_STARTED_SECONDS:-}" ]]; then
    local elapsed=$((SECONDS - SCRIPT_STARTED_SECONDS))
    printf '⏱️ Total time: %02d:%02d:%02d\n' \
      "$((elapsed / 3600))" "$((elapsed / 60 % 60))" "$((elapsed % 60))"
  fi
}

# Show details only when requested.
log_detail() {
  if [[ "${LOG_VERBOSE:-0}" -eq 1 ]]; then
    echo "$@"
  fi
}

# Identify the saved run without exposing its full path in quiet mode.
show_artifacts() {
  if [[ "${LOG_VERBOSE:-0}" -eq 1 ]]; then
    echo "📁 Artifacts: $RUN_DIR"
  else
    echo "📁 Logs saved for ${RUN_DIR##*/}"
  fi
}

# Report an error and exit with status 2.
fail() {
  if [[ "${LOG_VERBOSE:-0}" -eq 1 ]]; then
    printf '\n⚠️ Leak check could not be completed: %s\n' "$*" >&2
  else
    printf '\n⚠️ Leak check could not be completed. Rerun with --verbose for details.\n' >&2
    if [[ -n "${RUN_DIR:-}" ]]; then
      printf '%s\n' "$*" >> "$RUN_DIR/errors.log"
    fi
  fi
  show_duration >&2
  if [[ -n "${RUN_DIR:-}" ]]; then
    show_artifacts >&2
  fi
  exit 2
}

# Set up Xcode tools and app signing.
configure_xcode() {
  # Respect an explicit Xcode path, otherwise use the standard installation.
  if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
  fi

  if [[ "${1:-}" == --require-system-tools ]]; then
    # The diagnostics collector also uses the system-selected Xcode.
    env -u DEVELOPER_DIR /usr/bin/xcrun --find devicectl >/dev/null 2>&1 \
      || fail "Select the full Xcode installation with xcode-select."
  fi

  # Use the supplied signing team or the first team saved in Xcode's preferences.
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$(
    defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
      | awk '/teamID =/ { gsub(/[;"]/, "", $3); print $3; exit }' || true
  )}"
  [[ -n "$DEVELOPMENT_TEAM" ]] \
    || fail "Select a team in Xcode or set DEVELOPMENT_TEAM=YOUR_TEAM_ID."

  # Build the signing arguments once so the test command stays readable.
  SIGNING_ARGS=(
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    ENABLE_DEBUG_DYLIB="${ENABLE_DEBUG_DYLIB:-NO}"
  )
  if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    SIGNING_ARGS+=(CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY")
  fi
  if [[ "${ALLOW_PROVISIONING_UPDATES:-YES}" == YES ]]; then
    SIGNING_ARGS+=(-allowProvisioningUpdates)
  fi
  log_detail "Using Xcode development team: $DEVELOPMENT_TEAM"
}

# Choose a paired iPhone for the test.
select_device() {
  # Select a paired physical iOS device, optionally restricted to DEVICE_ID.
  local filter="hardwareProperties.platform == 'iOS' AND hardwareProperties.reality == 'physical' AND connectionProperties.pairingState == 'paired'"
  local device_name
  if [[ -n "${DEVICE_ID:-}" ]]; then
    filter="$filter AND hardwareProperties.udid == '$DEVICE_ID'"
  fi

  # Read structured device data; remove the temporary file even if discovery fails.
  DEVICES_JSON="$(mktemp -t leak-check-ios-devices.XXXXXX)"
  trap 'rm -f "$DEVICES_JSON"' EXIT
  xcrun devicectl list devices --filter "$filter" \
    --json-output "$DEVICES_JSON" --quiet --timeout 10 \
    || fail "Could not list iOS devices."

  # Pick the first match. Xcode will check whether it is ready to run tests.
  DEVICE_ID="$(plutil -extract result.devices.0.hardwareProperties.udid raw -o - "$DEVICES_JSON" 2>/dev/null || true)"
  device_name="$(plutil -extract result.devices.0.deviceProperties.name raw -o - "$DEVICES_JSON" 2>/dev/null || true)"
  rm -f "$DEVICES_JSON"
  trap - EXIT

  [[ -n "$DEVICE_ID" ]] || fail "Connect, unlock, and trust an iPhone."
  log_detail "Using iOS device: ${device_name:-iPhone} ($DEVICE_ID)"
}
