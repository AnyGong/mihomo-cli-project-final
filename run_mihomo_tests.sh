#!/bin/bash
#
# run_mihomo_tests.sh — automated build/test/smoke-test harness for
# mihomo-cli-project-final. Run this ON THE TARGET MAC (Apple Silicon,
# the Swift package is pinned to macOS 27). It will NOT do anything
# useful on Linux or Intel.
#
# What it does, in order:
#   0. Self-heals a broken working tree left by a previous run whose
#      cleanup failed to revert (detects it, reverts via git, then
#      continues) rather than building on top of stale breakage
#   1. Records environment + repo state
#   2. Detects which service types the command layer references but the
#      repo doesn't define, and generates temporary stub implementations
#      so `swift build` can succeed (deleted again at the end — never
#      committed, regenerated fresh every run). Safe to re-run as real
#      implementations land — it stops stubbing whatever now exists.
#   3. Temporarily redirects EVERY home-directory-based storage path
#      (found by scanning the source, not a hardcoded list — so newly
#      added files like a logger are caught automatically) to an
#      isolated temp directory for this run, so it never touches your
#      real ~/.mihomo-cli (reverted at the end via `git checkout`, run
#      from the git root so the revert actually matches)
#   4. Runs `swift build` and `swift test`, capturing full logs
#   5. Runs a scripted smoke test of the commands that have real logic
#      (kernel list/fetch/use/rm, sub list) against the sandboxed home
#   6. Surveys the rest of the command surface (log/audit/doctor/net
#      status/etc.) and reports outcomes neutrally rather than asserting
#      they must fail — only flags actual crash signatures, since
#      whether these are implemented yet changes independently of this
#      script
#   7. Cleans up (kills any kernel process it started, reverts source
#      patches, removes generated stub files) and writes SUMMARY.txt
#
# Usage:
#   ./run_mihomo_tests.sh [path-to-repo-root]
#   (defaults to the current directory)
#
# Optional env vars:
#   EXTENDED=1   also fetch a second kernel release and exercise the
#                switch-between-two-versions + non-active-removal paths
#                (slower, more network use)
#
# After it finishes, send me the whole logs/run-<timestamp>/ directory
# (or at minimum SUMMARY.txt) and I'll analyze it.

set -u
set -o pipefail

# Normalize repo root to an absolute path so all downstream path handling
# (grep/sed/git checkout) is deterministic no matter how the script is called.
REPO_ROOT="$(cd "${1:-$(pwd)}" && pwd)" || {
    echo "ERROR: could not resolve repo root: ${1:-$(pwd)}" >&2
    exit 1
}

PKG_DIR="$REPO_ROOT/mihomo-cli"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$REPO_ROOT/logs/run-$TS"
STUB_FILE="$PKG_DIR/Sources/mihomo-cli/Support/_TestHarnessStubs.swift"
HOME_SHIM_FILE="$PKG_DIR/Sources/mihomo-cli/Support/_TestableHome.swift"
PATCHED_FILES=()
STARTED_PID=""
BUILD_OK=0
TEST_OK=0

mkdir -p "$LOG_DIR"
# Ensure the Support directory exists before writing generated files into it.
mkdir -p "$(dirname "$STUB_FILE")"

SUMMARY="$LOG_DIR/SUMMARY.txt"
touch "$SUMMARY"

log() { echo "$*" | tee -a "$SUMMARY"; }
section() { log ""; log "===== $* ====="; }

# ---------------------------------------------------------------------
# Cleanup — always runs, even on early failure/Ctrl-C
# ---------------------------------------------------------------------
cleanup() {
  section "CLEANUP"
  if [ -n "$STARTED_PID" ] && kill -0 "$STARTED_PID" 2>/dev/null; then
    log "Killing leftover kernel process (pid $STARTED_PID) started by this run..."
    kill -9 "$STARTED_PID" 2>/dev/null
  fi
  if [ -f "$STUB_FILE" ]; then
    rm -f "$STUB_FILE"
    log "Removed generated stub file: $STUB_FILE"
  fi
  if [ -f "$HOME_SHIM_FILE" ]; then
    rm -f "$HOME_SHIM_FILE"
    log "Removed generated home-shim file: $HOME_SHIM_FILE"
  fi
  if [ "${#PATCHED_FILES[@]}" -gt 0 ]; then
    # PATCHED_FILES are stored relative to REPO_ROOT (the git root) —
    # git checkout must run from there, or the pathspec silently fails
    # to match and the patch is left in place.
    if git -C "$REPO_ROOT" checkout -- "${PATCHED_FILES[@]}" 2>>"$LOG_DIR/cleanup.log"; then
      log "Reverted NSHomeDirectory() patch in: ${PATCHED_FILES[*]}"
    else
      log "WARNING: failed to revert patch in: ${PATCHED_FILES[*]} — see cleanup.log."
      log "  Fix manually: cd '$REPO_ROOT' && git checkout -- ${PATCHED_FILES[*]}"
    fi
  fi
  if [ -n "${TEST_HOME:-}" ] && [ -d "$TEST_HOME" ]; then
    rm -rf "$TEST_HOME"
    log "Removed sandboxed test home: $TEST_HOME"
  fi
  log "Logs written to: $LOG_DIR"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------
# 1. Environment + repo state
# ---------------------------------------------------------------------
section "ENVIRONMENT"
{
  echo "date: $(date)"
  echo "uname: $(uname -a)"
  echo "arch: $(uname -m)"
  sw_vers 2>/dev/null || echo "sw_vers not available"
  swift --version 2>&1 || echo "swift not found on PATH"
  xcodebuild -version 2>&1 || echo "xcodebuild not found"
} | tee -a "$SUMMARY"

if [ ! -d "$PKG_DIR" ]; then
  log "ERROR: expected Swift package at $PKG_DIR — pass the repo root as arg 1."
  exit 1
fi

section "REPO STATE"
(
  cd "$REPO_ROOT" || exit 1
  echo "HEAD: $(git rev-parse HEAD 2>/dev/null || echo 'not a git repo')"
  echo "status:"
  git status --porcelain 2>/dev/null
) | tee -a "$SUMMARY"

SRC_DIR="$PKG_DIR/Sources/mihomo-cli"

# ---------------------------------------------------------------------
# 0. Self-heal: detect a broken working tree left over from a previous
#    run whose cleanup failed (e.g. testableHomeDirectory() referenced
#    but the shim that defines it is gone). Revert before doing anything
#    else, so we never build on top of stale breakage.
# ---------------------------------------------------------------------
if grep -rq "testableHomeDirectory()" "$SRC_DIR" 2>/dev/null \
   && [ ! -f "$SRC_DIR/Support/_TestableHome.swift" ]; then
  section "SELF-HEAL: reverting leftover patch from a previous failed run"
  LEFTOVER="$(grep -rl "testableHomeDirectory()" "$SRC_DIR" 2>/dev/null | sed "s|^$REPO_ROOT/||")"
  log "Found leftover testableHomeDirectory() references with no shim file present:"
  log "$LEFTOVER"
  if git -C "$REPO_ROOT" checkout -- $LEFTOVER 2>>"$LOG_DIR/selfheal.log"; then
    log "Reverted successfully. Continuing."
  else
    log "ERROR: could not auto-revert. Fix manually before rerunning:"
    log "  cd '$REPO_ROOT' && git checkout -- $LEFTOVER"
    exit 1
  fi
fi

# ---------------------------------------------------------------------
# 2. Detect missing service types and generate stubs only for what's
#    actually missing (safe to re-run once real implementations land —
#    it will just stop generating stubs for whichever ones now exist).
# ---------------------------------------------------------------------
section "BUILD-GATE: detecting missing symbols"

is_defined() {
  # $1 = symbol name
  grep -rqE "\b(struct|class|enum|actor)\s+$1\b" "$SRC_DIR" 2>/dev/null
}

MISSING=()
for sym in AppLogger LogLevel DoctorService UninstallService LifecycleService \
           NetService ModeService SubscriptionService DaemonService \
           KernelCheckService KernelStatusService; do
  if ! is_defined "$sym"; then
    MISSING+=("$sym")
  fi
done

CONFIRM_MISSING=0
if ! grep -rq "func confirm(" "$SRC_DIR" 2>/dev/null; then
  CONFIRM_MISSING=1
fi

log "Missing types: ${MISSING[*]:-none}"
log "Missing confirm() helper: $CONFIRM_MISSING"

if [ "${#MISSING[@]}" -gt 0 ] || [ "$CONFIRM_MISSING" -eq 1 ]; then
  log "Generating temporary stub file so the package can build: $STUB_FILE"
  {
    echo "import Foundation"
    echo ""
    echo "// AUTO-GENERATED by run_mihomo_tests.sh — safe to delete."
    echo "// Provides throw-not-implemented stubs for symbols the command layer"
    echo "// references but the repo does not yet define, purely so the package"
    echo "// compiles for testing. Remove this file once real implementations exist."
    echo ""

    for sym in "${MISSING[@]}"; do
      case "$sym" in
        LogLevel)
          echo 'enum LogLevel: String { case info, warning, error }'
          ;;
        AppLogger)
          cat <<'EOF'
struct AppLogger {
    static let shared = AppLogger()
    func queryLogs(minLevel: LogLevel?, json: Bool) throws -> [String] {
        throw CLIError(what: "not implemented", cause: "logging is not built yet", exitCode: .validationFailure)
    }
    func queryAudit(since: String?, actionFilter: String?, json: Bool) throws -> [String] {
        throw CLIError(what: "not implemented", cause: "audit trail is not built yet", exitCode: .validationFailure)
    }
}
EOF
          ;;
        DoctorService)
          cat <<'EOF'
struct DoctorService {
    func run(json: Bool) async throws {
        throw CLIError(what: "not implemented", cause: "doctor is not built yet", exitCode: .validationFailure)
    }
}
EOF
          ;;
        UninstallService)
          cat <<'EOF'
struct UninstallService {
    func uninstall(purgeData: Bool, yes: Bool) async throws {
        throw CLIError(what: "not implemented", cause: "uninstall is not built yet", exitCode: .validationFailure)
    }
}
EOF
          ;;
        LifecycleService)
          cat <<'EOF'
struct LifecycleService {
    func start(version: String?) async throws {
        throw CLIError(what: "not implemented", cause: "start is not built yet", exitCode: .validationFailure)
    }
    func stop() async throws {
        throw CLIError(what: "not implemented", cause: "stop is not built yet", exitCode: .validationFailure)
    }
    func restart() async throws {
        throw CLIError(what: "not implemented", cause: "restart is not built yet", exitCode: .validationFailure)
    }
}
EOF
          ;;
        NetService)
          cat <<'EOF'
struct NetService {
    func status(json: Bool) async throws { throw CLIError(what: "not implemented", cause: "net is not built yet", exitCode: .validationFailure) }
    func systemProxyOn(interface: String?, yes: Bool) async throws { throw CLIError(what: "not implemented", cause: "net is not built yet", exitCode: .validationFailure) }
    func systemProxyOff() async throws { throw CLIError(what: "not implemented", cause: "net is not built yet", exitCode: .validationFailure) }
    func tunOn(yes: Bool) async throws { throw CLIError(what: "not implemented", cause: "net is not built yet", exitCode: .validationFailure) }
    func tunOff() async throws { throw CLIError(what: "not implemented", cause: "net is not built yet", exitCode: .validationFailure) }
    func proxyModeOn(port: Int?) async throws { throw CLIError(what: "not implemented", cause: "net is not built yet", exitCode: .validationFailure) }
    func proxyModeOff() async throws { throw CLIError(what: "not implemented", cause: "net is not built yet", exitCode: .validationFailure) }
    func off() async throws { throw CLIError(what: "not implemented", cause: "net is not built yet", exitCode: .validationFailure) }
}
EOF
          ;;
        ModeService)
          cat <<'EOF'
struct ModeService {
    func status(json: Bool) async throws { throw CLIError(what: "not implemented", cause: "mode is not built yet", exitCode: .validationFailure) }
    func switchMode(to: String, yes: Bool) async throws { throw CLIError(what: "not implemented", cause: "mode is not built yet", exitCode: .validationFailure) }
}
EOF
          ;;
        SubscriptionService)
          cat <<'EOF'
struct SubscriptionService {
    func addLocal(path: String, preferredName: String?, yes: Bool) async throws { throw CLIError(what: "not implemented", cause: "sub add is not built yet", exitCode: .validationFailure) }
    func addRemote(url: String, interval: Int, preferredName: String?, yes: Bool) async throws { throw CLIError(what: "not implemented", cause: "sub add is not built yet", exitCode: .validationFailure) }
    func use(name: String, force: Bool) async throws { throw CLIError(what: "not implemented", cause: "sub use is not built yet", exitCode: .validationFailure) }
    func edit(name: String, customEditor: String?) async throws { throw CLIError(what: "not implemented", cause: "sub edit is not built yet", exitCode: .validationFailure) }
    func remove(name: String, yes: Bool) async throws { throw CLIError(what: "not implemented", cause: "sub rm is not built yet", exitCode: .validationFailure) }
    func refresh(name: String) async throws { throw CLIError(what: "not implemented", cause: "sub refresh is not built yet", exitCode: .validationFailure) }
    func validate(name: String) async throws { throw CLIError(what: "not implemented", cause: "sub validate is not built yet", exitCode: .validationFailure) }
}
EOF
          ;;
        DaemonService)
          cat <<'EOF'
struct DaemonService {
    func install(yes: Bool) async throws { throw CLIError(what: "not implemented", cause: "daemon is not built yet", exitCode: .validationFailure) }
    func remove(yes: Bool) async throws { throw CLIError(what: "not implemented", cause: "daemon is not built yet", exitCode: .validationFailure) }
    func status(json: Bool) async throws { throw CLIError(what: "not implemented", cause: "daemon is not built yet", exitCode: .validationFailure) }
}
EOF
          ;;
        KernelCheckService)
          cat <<'EOF'
struct KernelCheckService {
    func check(yes: Bool) async throws { throw CLIError(what: "not implemented", cause: "kernel check is not built yet", exitCode: .validationFailure) }
}
EOF
          ;;
        KernelStatusService)
          cat <<'EOF'
struct KernelStatusService {
    struct Report {}
    func report() async throws -> Report {
        throw CLIError(what: "not implemented", cause: "kernel status is not built yet", exitCode: .validationFailure)
    }
    static func jsonOutput(from report: Report) throws -> String { "{}" }
    static func humanOutput(from report: Report) -> String { "not implemented" }
}
EOF
          ;;
      esac
      echo ""
    done

    if [ "$CONFIRM_MISSING" -eq 1 ]; then
      cat <<'EOF'
enum ConfirmResult { case confirmed, cancelled }

/// Minimal confirmation helper. Never blocks indefinitely: if stdin isn't
/// a TTY (e.g. run from this script) and --yes wasn't passed, it treats
/// EOF on stdin as "cancelled" rather than hanging.
func confirm(_ prompt: String, yes: Bool) throws -> ConfirmResult {
    if yes { return .confirmed }
    print("\(prompt) [y/N] ", terminator: "")
    guard let line = readLine(strippingNewline: true) else { return .cancelled }
    return ["y", "yes"].contains(line.lowercased()) ? .confirmed : .cancelled
}
EOF
    fi
  } > "$STUB_FILE"
else
  log "No missing symbols detected — package should build without stubs."
fi

# ---------------------------------------------------------------------
# 3. Sandbox the home-directory-based storage paths for this run only.
#    NSHomeDirectory() on Darwin does not reliably follow $HOME, so we
#    inject a small shim and point the default parameters at it. This
#    patches tracked files; PATCHED_FILES is reverted in cleanup().
# ---------------------------------------------------------------------
section "SANDBOXING: redirecting storage paths"

TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-cli-test.XXXXXX")"
export MIHOMO_CLI_TEST_HOME="$TEST_HOME"
log "Sandboxed home for this run: $TEST_HOME"

cat > "$HOME_SHIM_FILE" <<'EOF'
import Foundation

// AUTO-GENERATED by run_mihomo_tests.sh — safe to delete.
// Lets storage paths be redirected into a throwaway directory for testing,
// via MIHOMO_CLI_TEST_HOME, without changing production behavior (falls
// back to the real NSHomeDirectory() whenever that env var isn't set).
func testableHomeDirectory() -> String {
    ProcessInfo.processInfo.environment["MIHOMO_CLI_TEST_HOME"] ?? NSHomeDirectory()
}
EOF

# Scan every source file for NSHomeDirectory() rather than a hardcoded
# list — a hardcoded list misses files like AppLogger's storage path,
# which then silently reads/writes the REAL ~/.mihomo-cli during "sandboxed"
# runs. Skip the shim file itself (it intentionally calls NSHomeDirectory()
# as its fallback).
while IFS= read -r full; do
  [ "$full" = "$HOME_SHIM_FILE" ] && continue
  sed -i '' 's/NSHomeDirectory()/testableHomeDirectory()/g' "$full"
  # Store the path relative to REPO_ROOT (the git root) so cleanup's
  # `git checkout` — which must run from REPO_ROOT — can find it.
  rel="${full#"$REPO_ROOT"/}"
  PATCHED_FILES+=("$rel")
done < <(grep -rl "NSHomeDirectory()" "$SRC_DIR" 2>/dev/null)

log "Patched files (reverted at end of run): ${PATCHED_FILES[*]:-none}"
if [ "${#PATCHED_FILES[@]}" -eq 0 ]; then
  log "WARNING: no NSHomeDirectory() usages found at all — storage paths may not be sandboxed. Investigate before trusting this run's log/audit/doctor output as isolated."
fi

# ---------------------------------------------------------------------
# 4. Build + unit tests
# ---------------------------------------------------------------------
section "swift build"
( cd "$PKG_DIR" && swift build 2>&1 ) | tee "$LOG_DIR/build.log"
BUILD_OK=${PIPESTATUS[0]}
log "swift build exit code: $BUILD_OK"

if [ "$BUILD_OK" -ne 0 ]; then
  log "BUILD FAILED — skipping tests and smoke tests. See build.log."
  exit 1
fi

section "swift test"
( cd "$PKG_DIR" && swift test --disable-sandbox 2>&1 ) | tee "$LOG_DIR/test.log"
TEST_OK=${PIPESTATUS[0]}
log "swift test exit code: $TEST_OK"
log "--- test summary lines ---"
grep -E "Test Suite|passed|failed" "$LOG_DIR/test.log" | tail -40 | tee -a "$SUMMARY"

# ---------------------------------------------------------------------
# 5. Locate the built binary
# ---------------------------------------------------------------------
BIN_PATH="$(cd "$PKG_DIR" && swift build --show-bin-path 2>/dev/null)/mihomo-cli"
if [ ! -x "$BIN_PATH" ]; then
  log "ERROR: built binary not found at expected path: $BIN_PATH"
  exit 1
fi
log "Binary: $BIN_PATH"

run_cli() {
  # Runs the CLI with the sandboxed home, logs stdout/stderr/exit code.
  local label="$1"; shift
  local out
  out="$("$BIN_PATH" "$@" 2>&1)"
  local code=$?
  {
    echo "--- $label ---"
    echo "\$ mihomo $*"
    echo "$out"
    echo "(exit code: $code)"
    echo ""
  } >> "$LOG_DIR/smoke.log"
  echo "$out"
  return $code
}

extract_json_field() {
  # crude but dependency-free: extract first "field": "value" match
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" <<<"$1" | head -1 | sed -E 's/.*: *"([^"]*)"/\1/'
}

# ---------------------------------------------------------------------
# 6. Smoke test the real command surface
# ---------------------------------------------------------------------
section "SMOKE TESTS (real components)"
PASS=0
FAIL=0
check() {
  # $1 = description, $2 = actual exit code, $3 = expected exit code
  if [ "$2" -eq "$3" ]; then
    log "PASS: $1 (exit $2)"
    PASS=$((PASS+1))
  else
    log "FAIL: $1 (expected exit $3, got $2)"
    FAIL=$((FAIL+1))
  fi
}

run_cli "version" --version >/dev/null; check "mihomo --version" $? 0

out="$(run_cli "kernel list (empty)" kernel list)"; ec=$?
check "kernel list on empty store" $ec 0
[[ "$out" == *"No kernels installed"* ]] && log "  (confirmed empty-state message)"

run_cli "kernel list json (empty)" kernel list --json >/dev/null; check "kernel list --json on empty store" $? 0

log "Fetching latest stable release (network required — this is the real GitHub Releases integration)..."
out="$(run_cli "kernel fetch (latest stable)" kernel fetch)"; ec=$?
check "kernel fetch (default = latest stable)" $ec 0

out_json="$(run_cli "kernel list json (after fetch)" kernel list --json)"
VERSION="$(extract_json_field "$out_json" version)"
if [ -z "$VERSION" ]; then
  log "FAIL: could not determine fetched kernel version from 'kernel list --json' output — aborting remaining smoke tests."
  FAIL=$((FAIL+1))
else
  log "Fetched version detected: $VERSION"

  out="$(run_cli "kernel use (first switch)" kernel use "$VERSION")"; ec=$?
  check "kernel use $VERSION (first switch, should launch + pass liveness)" $ec 0

  # capture pid for cleanup safety net
  store_json="$TEST_HOME/.mihomo-cli/store.json"
  if [ -f "$store_json" ]; then
    STARTED_PID="$(grep -o '"pid"[[:space:]]*:[[:space:]]*[0-9]*' "$store_json" | head -1 | grep -o '[0-9]*$')"
    log "Tracked kernel pid for cleanup: ${STARTED_PID:-none}"
  fi

  out="$(run_cli "kernel use (already active)" kernel use "$VERSION")"; ec=$?
  check "kernel use $VERSION (already active — fast path, no relaunch)" $ec 0
  [[ "$out" == *"already the active kernel"* ]] && log "  (confirmed already-active message)"

  out="$(run_cli "kernel list json (active flag)" kernel list --json)"
  ACTIVE_FLAG="$(grep -o '"isActive"[[:space:]]*:[[:space:]]*[a-z]*' <<<"$out" | head -1 | grep -o '[a-z]*$')"
  if [ "$ACTIVE_FLAG" = "true" ]; then
    log "PASS: kernel list reflects isActive=true after use"; PASS=$((PASS+1))
  else
    log "FAIL: kernel list did not reflect isActive=true after use (got '$ACTIVE_FLAG')"; FAIL=$((FAIL+1))
  fi

  run_cli "kernel rm active (should be blocked)" kernel rm "$VERSION" --yes; ec=$?
  check "kernel rm on the ACTIVE kernel (must be refused, §1.1.2)" $ec 2

  out="$(run_cli "sub list (empty)" sub list)"; ec=$?
  check "sub list on empty store" $ec 0
  [[ "$out" == *"No subscriptions configured"* ]] && log "  (confirmed empty-state message)"

  if [ "${EXTENDED:-0}" = "1" ]; then
    section "EXTENDED: second kernel + switch + non-active removal"
    out="$(run_cli "kernel fetch --all" kernel fetch --all)"; ec=$?
    check "kernel fetch --all (latest 10 releases)" $ec 0
    out_json="$(run_cli "kernel list json (after fetch --all)" kernel list --json)"
    ALL_VERSIONS="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$out_json" | sed -E 's/.*"([^"]*)"$/\1/')"
    OTHER_VERSION="$(comm -23 <(echo "$ALL_VERSIONS" | sort -u) <(echo "$VERSION") | head -1)"
    if [ -n "$OTHER_VERSION" ]; then
      out="$(run_cli "kernel use (switch to second version)" kernel use "$OTHER_VERSION")"; ec=$?
      check "kernel use $OTHER_VERSION (switch away from $VERSION, should stop old + rollback-safe)" $ec 0
      store_json="$TEST_HOME/.mihomo-cli/store.json"
      [ -f "$store_json" ] && STARTED_PID="$(grep -o '"pid"[[:space:]]*:[[:space:]]*[0-9]*' "$store_json" | head -1 | grep -o '[0-9]*$')"
      run_cli "kernel rm (now-inactive first version)" kernel rm "$VERSION" --yes; ec=$?
      check "kernel rm $VERSION (now inactive, should succeed)" $ec 0
    else
      log "SKIP: could not find a second distinct version to switch to."
    fi
  fi
fi

# ---------------------------------------------------------------------
# 7. Report on the remaining command surface WITHOUT assuming it's still
#    a stub — the project evolves independently of this script, and
#    asserting "must fail" here goes stale the moment a real
#    implementation lands. We only flag actual crash signatures; every
#    other outcome (success or a clean error) is logged neutrally for
#    you/me to read, not judged pass/fail.
# ---------------------------------------------------------------------
section "COMMAND SURFACE REPORT (not asserted — for review, not judged)"
SURVEY_CMDS=(
  "log"
  "audit"
  "doctor"
  "start"
  "stop"
  "restart"
  "net status"
  "mode status"
  "daemon status"
)
CRASH_SIGNS=("Fatal error" "Segmentation fault" "Illegal instruction" "Trace/BPT trap" "precondition failed" "fatalError")
for cmd in "${SURVEY_CMDS[@]}"; do
  # shellcheck disable=SC2086
  out="$(run_cli "survey: $cmd" $cmd)"
  ec=$?
  crashed=0
  # A real crash: killed by a signal (exit code > 128, excluding our own
  # 130 for Ctrl-C) or a recognizable crash signature in the output.
  if { [ "$ec" -gt 128 ] && [ "$ec" -ne 130 ]; }; then
    crashed=1
  fi
  for sign in "${CRASH_SIGNS[@]}"; do
    [[ "$out" == *"$sign"* ]] && crashed=1
  done
  if [ "$crashed" -eq 1 ]; then
    log "CRASH: '$cmd' looks like a real crash (exit $ec) — see smoke.log for output."
    FAIL=$((FAIL+1))
  else
    firstline="$(echo "$out" | head -1)"
    log "INFO: '$cmd' -> exit $ec, first line: ${firstline:-<empty>}"
  fi
done

# ---------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------
section "RESULT"
log "swift build: $([ "$BUILD_OK" -eq 0 ] && echo OK || echo FAILED)"
log "swift test:  $([ "$TEST_OK" -eq 0 ] && echo OK || echo FAILED) (see test.log for per-test detail)"
log "smoke tests: $PASS passed, $FAIL failed"
log ""
log "Full logs in: $LOG_DIR"
log "Send SUMMARY.txt (and build.log/test.log/smoke.log if anything failed) back for analysis."

[ "$BUILD_OK" -eq 0 ] && [ "$TEST_OK" -eq 0 ] && [ "$FAIL" -eq 0 ]
exit $?