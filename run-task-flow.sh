#!/usr/bin/env bash
#
# One-click task flow for the Tun/proxy-mode/doctor fixes:
#   apply patch (if present & not yet applied) -> swift build -> swift test -> optional doctor sanity check
#
# Usage:
#   ./run-task-flow.sh              # full flow (apply -> build -> test)
#   ./run-task-flow.sh apply        # just apply changes.patch
#   ./run-task-flow.sh build        # just swift build (debug)
#   ./run-task-flow.sh test         # just swift test
#   ./run-task-flow.sh install      # release build -> /usr/local/bin/mihomo-cli
#   ./run-task-flow.sh doctor       # swift run mihomo-cli doctor (requires a real Mac + kernel installed)
#   ./run-task-flow.sh verify       # apply -> build -> test (same as no args)
#
# NOTE ON NAMING: the real mihomo kernel/proxy binary (e.g. from
# `brew install mihomo`) typically occupies the name "mihomo" on PATH
# already. This project's own executable target is named "mihomo-cli"
# (see Package.swift) specifically so `install` never collides with or
# overwrites it — installs to /usr/local/bin/mihomo-cli, never
# /opt/homebrew/bin/mihomo. Always invoke this tool as `mihomo-cli`,
# never as bare `mihomo`.
#
# This is meant to be double-clicked (as run-task-flow.command) or run via
# `npm run verify` (see package.json) — it does the real work either way.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$ROOT_DIR/mihomo-cli"
PATCH_FILE="$ROOT_DIR/changes.patch"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
ok()   { printf '\033[1;32m✅ %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m⚠️  %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m❌ %s\033[0m\n' "$1"; exit 1; }

cmd="${1:-verify}"

require_swift() {
    if ! command -v swift >/dev/null 2>&1; then
        fail "swift not found on PATH. This script must run on macOS with Xcode/Swift toolchain installed — it will not work in a plain Linux shell."
    fi
}

do_apply() {
    step "Checking for pending fix patch"
    if [ ! -f "$PATCH_FILE" ]; then
        warn "No changes.patch found at repo root — skipping (assuming fixes are already applied, or you copied the files in manually)."
        return 0
    fi

    cd "$ROOT_DIR"
    if git apply --check "$PATCH_FILE" >/dev/null 2>&1; then
        step "Applying changes.patch"
        git apply "$PATCH_FILE"
        ok "Patch applied."
    else
        warn "changes.patch does not apply cleanly (most likely it's already applied). Continuing without re-applying."
    fi
}

do_build() {
    require_swift
    step "swift build"
    cd "$PACKAGE_DIR"
    if swift build; then
        ok "Build succeeded."
    else
        fail "Build failed — fix compile errors above before continuing. (I could not compile this myself; see README.md in the fixes bundle.)"
    fi
}

do_test() {
    require_swift
    step "swift test"
    cd "$PACKAGE_DIR"
    if swift test; then
        ok "All tests passed."
    else
        fail "Some tests failed — see output above."
    fi
}

do_doctor() {
    require_swift
    step "swift run mihomo-cli doctor"
    warn "This talks to a real running kernel and real sudo/networksetup — only meaningful on the actual Mac Mini with a kernel installed."
    cd "$PACKAGE_DIR"
    swift run mihomo-cli doctor || warn "doctor reported warnings/errors above — that's the tool working correctly, not this script failing."
}

do_install() {
    require_swift
    local INSTALL_PATH="/usr/local/bin/mihomo-cli"

    step "swift build -c release"
    cd "$PACKAGE_DIR"
    if ! swift build -c release; then
        fail "Release build failed — fix compile errors above before installing."
    fi
    ok "Release build succeeded."

    local BUILT_BINARY="$PACKAGE_DIR/.build/release/mihomo-cli"
    if [ ! -f "$BUILT_BINARY" ]; then
        fail "Expected release binary not found at $BUILT_BINARY — did the target name change in Package.swift?"
    fi

    step "Installing to $INSTALL_PATH"
    # Deliberately never installs as plain "mihomo" — that name is very
    # likely already taken by the real mihomo kernel/proxy binary (e.g.
    # from `brew install mihomo`), which lives at /opt/homebrew/bin/mihomo
    # and is a completely different program this tool manages, not is.
    # Overwriting it would silently break your proxy engine.
    if [ -e /opt/homebrew/bin/mihomo ] || command -v mihomo >/dev/null 2>&1; then
        warn "Detected an existing 'mihomo' on PATH (likely the real kernel/proxy binary, e.g. from Homebrew) — installing this CLI as 'mihomo-cli' instead, never overwriting it."
    fi

    sudo cp "$BUILT_BINARY" "$INSTALL_PATH"
    sudo chmod +x "$INSTALL_PATH"
    ok "Installed to $INSTALL_PATH"

    echo
    local FOUND_PATHS
    FOUND_PATHS="$(which -a mihomo-cli 2>/dev/null || true)"
    if [ "$(echo "$FOUND_PATHS" | wc -l | tr -d ' ')" != "1" ]; then
        warn "Multiple 'mihomo-cli' found on PATH — make sure the one that runs first is $INSTALL_PATH:"
        echo "$FOUND_PATHS"
    else
        ok "PATH resolves 'mihomo-cli' to: $FOUND_PATHS"
    fi
    echo "   Use 'mihomo-cli <command>' from now on — never bare 'mihomo', which is the kernel binary, not this tool."
}

case "$cmd" in
    apply)   do_apply ;;
    build)   do_build ;;
    test)    do_test ;;
    install) do_install ;;
    doctor)  do_doctor ;;
    verify)
        do_apply
        do_build
        do_test
        echo
        ok "Verify flow complete: patch applied (if needed), build succeeded, tests passed."
        echo "   Run './run-task-flow.sh install' next to build+install the release binary as 'mihomo-cli',"
        echo "   then './run-task-flow.sh doctor' (or 'mihomo-cli doctor') on the real machine to sanity-check Tun/doctor behavior live."
        ;;
    *)
        fail "Unknown command '$cmd'. Use: apply | build | test | install | doctor | verify"
        ;;
esac