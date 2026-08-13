#!/bin/bash
# tun_privilege_spike.sh
#
# Validates the Tun-mode privilege escalation mechanism for mihomo-cli.
# See ../docs/mihomo_tun_privilege_spike_guide.md for full background.
#
# This script PROBES and REPORTS. It does not modify system security
# policy (sudoers) itself — that one step is printed as instructions for
# you to run manually via `visudo`, deliberately, so you review it before
# it takes effect.
#
# Safe to run repeatedly. Cleans up any test interface it creates.

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

pass() { echo -e "${GREEN}✅ PASS${RESET} — $1"; }
fail() { echo -e "${RED}❌ FAIL${RESET} — $1"; }
info() { echo -e "${YELLOW}ℹ${RESET}  $1"; }
step() { echo; echo -e "${BOLD}== $1 ==${RESET}"; }

TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

# --- Step 0: sanity check -----------------------------------------------
step "Step 0: confirm not already running as root"
if [ "$EUID" -eq 0 ]; then
    fail "This script is running as root already. Run it as your normal user (no sudo) so the test actually exercises the unprivileged→privileged transition."
    exit 1
fi
pass "running as user $(whoami), not root"

# --- Minimal utun-creation test program ----------------------------------
# Opens a PF_SYSTEM/SYSPROTO_CONTROL socket and connects to the
# com.apple.net.utun_control kernel control — the same primitive mihomo's
# Tun mode needs. Prints the assigned interface name on success.
cat > "$TESTDIR/utun_probe.c" << 'EOF'
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>
#include <sys/ioctl.h>
#include <net/if_utun.h>

int main(void) {
    struct ctl_info info;
    struct sockaddr_ctl addr;
    int fd;

    fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) {
        fprintf(stderr, "socket() failed: %s (errno %d)\n", strerror(errno), errno);
        return 1;
    }

    memset(&info, 0, sizeof(info));
    strncpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof(info.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &info) < 0) {
        fprintf(stderr, "ioctl(CTLIOCGINFO) failed: %s (errno %d)\n", strerror(errno), errno);
        close(fd);
        return 1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sc_len = sizeof(addr);
    addr.sc_family = AF_SYSTEM;
    addr.ss_sysaddr = AF_SYS_CONTROL;
    addr.sc_id = info.ctl_id;
    addr.sc_unit = 0; // let the kernel assign the next free utun unit

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "connect() failed: %s (errno %d)\n", strerror(errno), errno);
        close(fd);
        return 1;
    }

    char ifname[64];
    socklen_t ifname_len = sizeof(ifname);
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, ifname, &ifname_len) < 0) {
        fprintf(stderr, "getsockopt(UTUN_OPT_IFNAME) failed: %s (errno %d)\n", strerror(errno), errno);
        close(fd);
        return 1;
    }

    printf("%s\n", ifname);
    // Deliberately keep the fd open briefly so the interface is visible to
    // `ifconfig` for the cleanup step, then close (which tears it down).
    fflush(stdout);
    sleep(2);
    close(fd);
    return 0;
}
EOF

step "Compiling minimal utun probe (uses system clang)"
if ! clang -o "$TESTDIR/utun_probe" "$TESTDIR/utun_probe.c" 2> "$TESTDIR/compile.log"; then
    fail "compile failed — is Xcode Command Line Tools installed? (xcode-select --install)"
    cat "$TESTDIR/compile.log"
    exit 1
fi
pass "compiled"

# --- Step 1: unprivileged attempt (expect failure) ------------------------
step "Step 1: attempt utun creation WITHOUT elevation (expect this to fail)"
OUT="$("$TESTDIR/utun_probe" 2>&1)"
RC=$?
if [ $RC -ne 0 ]; then
    pass "failed as expected (this confirms root is genuinely required, not a false assumption)"
    info "error was: $OUT"
else
    fail "UNEXPECTED: utun creation succeeded without elevation ($OUT). This changes the whole premise of item #1 — no privilege escalation mechanism may be needed at all on this OS build. Do not proceed with sudoers setup; investigate this result first and update docs/mihomo_tun_privilege_spike_guide.md with what you find."
    exit 0
fi

# --- Step 2: print (don't apply) the sudoers instructions -----------------
step "Step 2: sudoers NOPASSWD rule (manual step — not applied automatically)"
MIHOMO_BINARY_PATH="/path/to/your/mihomo/kernel/binary"
cat << EOF
To allow passwordless elevation for this exact binary, run:

    sudo visudo -f /etc/sudoers.d/mihomo-cli

and add this single line (replace the path with the real mihomo kernel
binary path once you have one downloaded via 'mihomo kernel fetch'):

    $(whoami) ALL=(root) NOPASSWD: ${MIHOMO_BINARY_PATH}

Save and exit. This scopes passwordless sudo to ONLY that exact binary
path — not a blanket NOPASSWD for all commands, which would be a much
bigger security loosening than this needs.

Press Enter once you've done this (or if you'd rather just test plain
interactive 'sudo' first without NOPASSWD — either is fine for this step,
enter your password when prompted below if so), or Ctrl-C to stop here
and do this later.
EOF
read -r _

# --- Step 3: privileged attempt (expect success) ---------------------------
step "Step 3: attempt utun creation WITH sudo (expect success)"
OUT="$(sudo "$TESTDIR/utun_probe" 2>&1)"
RC=$?
if [ $RC -eq 0 ]; then
    IFNAME="$OUT"
    pass "utun creation succeeded under sudo, interface name: $IFNAME"
else
    fail "utun creation FAILED even under sudo: $OUT — this is the 'something more fundamental is wrong' case from the guide (SIP, macOS 27 Beta regression, etc). Stop and investigate before writing Swift code."
    exit 1
fi

# --- Step 4: confirm the interface actually existed, then clean up ---------
step "Step 4: confirm interface visibility and clean up"
sleep 0.5
if ifconfig "$IFNAME" > /dev/null 2>&1; then
    pass "interface $IFNAME was visible to ifconfig"
    sudo ifconfig "$IFNAME" destroy 2>/dev/null
    if ifconfig "$IFNAME" > /dev/null 2>&1; then
        fail "interface $IFNAME still exists after destroy — clean it up manually: sudo ifconfig $IFNAME destroy"
    else
        pass "interface $IFNAME cleanly destroyed, no orphaned utun device left behind"
    fi
else
    info "interface may have already been torn down when the probe process's fd closed (this is normal utun behavior — it can auto-destroy when the owning fd closes). Not a failure."
fi

step "Summary"
echo "If every step above passed: Option A (sudoers NOPASSWD) is confirmed viable."
echo "Next: apply the sudoers rule for real (if you only tested interactive sudo above,"
echo "go back and do the visudo step), then re-run this script once more end-to-end to"
echo "confirm NO password prompt appears on step 3."
echo
echo "Report the result back so Support/TunPrivilege.swift can be implemented against"
echo "a confirmed mechanism. See docs/mihomo_tun_privilege_spike_guide.md §5."
