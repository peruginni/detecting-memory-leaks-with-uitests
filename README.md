# Detecting memory leaks with UI tests

A small SwiftUI app with an intentional retain cycle, plus two scripts for detecting it on a physical iPhone.

`DetailScreenModel` owns a closure that strongly captures the model. Each test opens and closes the detail screen three times per flow. Surviving models and their payloads give the tools something to detect.

## Requirements

- macOS with full Xcode installed; tested with Xcode 26.6.
- A paired, unlocked, trusted physical iPhone. The sample currently targets iOS 26.4 or later.
- An Apple development team configured in Xcode, or supplied through `DEVELOPMENT_TEAM`.
- Python 3. The helpers use only the standard library.

The XCTest diagnostics collector also requires full Xcode to be selected in `xcode-select`. If necessary, run `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.

## Run

From this repository:

```sh
./detect-leaks-via-xctest-memory-diagnostics.sh
./detect-leaks-via-xctrace-leaks-instruments.sh
```

Both scripts build and run the sample on the first paired physical iPhone. To choose a device and signing team explicitly:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID DEVICE_ID=YOUR_DEVICE_UDID \
  ./detect-leaks-via-xctest-memory-diagnostics.sh
```

The same environment variables work with the xctrace script. Use `--verbose` to show tool output and full paths, or `--help` for output options. Quiet output is the default; full logs are still saved.

You can also open `memory-leaking-app/MyApp.xcodeproj` and select your own signing team to run the app manually.

## What each script checks

| Script | Collection | Analysis |
| --- | --- | --- |
| `detect-leaks-via-xctest-memory-diagnostics.sh` | `XCTMemoryMetric` and performance-test diagnostics in an `.xcresult` | Export post-test memory graphs and run `/usr/bin/leaks` |
| `detect-leaks-via-xctrace-leaks-instruments.sh` | Built-in Instruments `Leaks` template, recorded with `xctrace` | Export Leaks and Allocations tables; recover generic type names by matching live allocation addresses and sizes |

Both print app-specific counts first, then every detected leak grouped by type. Unnamed `Malloc` allocations remain included. A failed test, missing graph/table, malformed report, or failed export makes the check incomplete rather than clean.

Exit codes:

- `0`: no leaks detected.
- `1`: leaks detected. **This is expected for this intentionally leaking sample.**
- `2`: the check could not finish.

Each run saves its artifacts under `memory-leaking-app/artifacts/`, in a timestamped folder. Set `ARTIFACTS_DIR` to change the root location.

## Limits and diagnostics

- The metric records memory use; `leaks` performs the graph analysis. XCTest may execute the measured block more than once. In our device runs, even `iterationCount = 0` executed it twice, relaunching the app between flows.
- A model still reachable from a singleton or cache may escape `leaks`. `heap` can compare instance counts in saved pre/post graphs, but that comparison is not automated here. Growing counts are investigation signals, not proof of leaks.
- The recorder attaches after the app launches. Its default limit is 60 seconds; override it with `XCTRACE_TIME_LIMIT=90s`. Attachment and scan timing can affect how many instances are detected.
- If Apple's exporter segfaults, the script retries once using the saved trace and validates the XML. It does not rerun the UI test. A repeated crash fails the check.
- Quiet output omits routine paths and device/signing identifiers. Logs, traces, graphs, and Xcode user settings can contain personal or device information; they are excluded from Git. Review artifacts before sharing them separately.

## Check the helpers without a device

```sh
python3 -B -m unittest discover -s tests
```

The Python helpers can also process previously exported files; run either helper without arguments to see its usage.

## License

MIT; see [LICENSE](LICENSE).
