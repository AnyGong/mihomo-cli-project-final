import Foundation
import XCTest
@testable import mihomo_cli

/// Regression coverage for `PortInspector.hasActiveUtunTunnel`.
///
/// Originally `isUtunInterfacePresent()` ran `ifconfig -l` and treated any
/// interface *named* `utunN` as "claimed by a VPN". macOS pre-allocates
/// several idle utun slots at boot for its own frameworks (Continuity,
/// Personal Hotspot, etc.), so that check false-positived on essentially
/// every Mac and permanently blocked `mihomo net tun on` with "utun
/// interface already claimed" even with no VPN running at all. The fix
/// requires the interface to be both `UP` and carrying a real (non
/// link-local) address before treating it as a live tunnel.
final class PortInspectorTests: XCTestCase {

    func testIdleMacWithNoVPNIsNotReportedAsClaimed() {
        // Real-world shape: several pre-allocated utun slots, UP/RUNNING,
        // each with nothing but an auto-assigned link-local IPv6 address —
        // this is the exact false-positive case from the bug report.
        let output = """
        lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        \tinet 127.0.0.1 netmask 0xff000000
        \tinet6 ::1 prefixlen 128
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255
        utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
        \tinet6 fe80::afaa:2233:4455:6677%utun0 prefixlen 64 scopeid 0x14
        utun1: flags=8010<POINTOPOINT,MULTICAST> mtu 1380
        utun2: flags=8010<POINTOPOINT,MULTICAST> mtu 1500
        utun3: flags=8010<POINTOPOINT,MULTICAST> mtu 1500
        """

        XCTAssertFalse(PortInspector.hasActiveUtunTunnel(ifconfigOutput: output))
    }

    func testLiveVPNWithIPv4TunnelAddressIsReportedAsClaimed() {
        let output = """
        lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        \tinet 127.0.0.1 netmask 0xff000000
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255
        utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
        \tinet6 fe80::afaa:2233:4455:6677%utun0 prefixlen 64 scopeid 0x14
        utun1: flags=8010<POINTOPOINT,MULTICAST> mtu 1380
        utun3: flags=80d1<UP,POINTOPOINT,RUNNING,NOARP,MULTICAST> mtu 1380
        \tinet 10.8.0.4 --> 10.8.0.1 netmask 0xffffffff
        """

        XCTAssertTrue(PortInspector.hasActiveUtunTunnel(ifconfigOutput: output))
    }

    func testLiveVPNWithRoutableIPv6TunnelAddressIsReportedAsClaimed() {
        let output = """
        utun4: flags=80d1<UP,POINTOPOINT,RUNNING,NOARP,MULTICAST> mtu 1280
        \tinet6 fe80::1%utun4 prefixlen 64 scopeid 0x16
        \tinet6 2001:db8:1234::2 prefixlen 64
        """

        XCTAssertTrue(PortInspector.hasActiveUtunTunnel(ifconfigOutput: output))
    }

    func testUtunUpWithNoAddressAtAllIsNotReportedAsClaimed() {
        // Some idle slots report UP without ever getting even a link-local
        // address assigned — still not a real tunnel.
        let output = """
        utun2: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
        """

        XCTAssertFalse(PortInspector.hasActiveUtunTunnel(ifconfigOutput: output))
    }

    func testUtunDownWithStaleAddressIsNotReportedAsClaimed() {
        // Flags without UP — interface administratively down. Even if an
        // address is still attached from a prior session, it isn't a live
        // tunnel right now.
        let output = """
        utun5: flags=8010<POINTOPOINT,MULTICAST> mtu 1380
        \tinet 10.8.0.4 --> 10.8.0.1 netmask 0xffffffff
        """

        XCTAssertFalse(PortInspector.hasActiveUtunTunnel(ifconfigOutput: output))
    }

    func testNonUtunInterfacesNeverCount() {
        // en0/lo0/etc. having real addresses must never trip the utun check,
        // regardless of how their blocks are formatted.
        let output = """
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255
        bridge0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.2.1 netmask 0xffffff00 broadcast 192.168.2.255
        """

        XCTAssertFalse(PortInspector.hasActiveUtunTunnel(ifconfigOutput: output))
    }

    func testEmptyOutputIsNotReportedAsClaimed() {
        XCTAssertFalse(PortInspector.hasActiveUtunTunnel(ifconfigOutput: ""))
    }

    // MARK: - lsof parsing (pre-existing helper, no behavior change — smoke
    // test only, since this file is now the natural home for PortInspector
    // coverage and there wasn't one before).

    func testParseLsofOutputExtractsFirstMatchingProcess() {
        let output = """
        COMMAND   PID   USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        mihomo  4102   john    7u  IPv4 0x1234      0t0  TCP 127.0.0.1:9090 (LISTEN)
        """

        let result = PortInspector.parseLsofOutput(output)
        XCTAssertEqual(result, ProcessPortInfo(pid: 4102, command: "mihomo"))
    }

    func testParseLsofOutputReturnsNilForHeaderOnlyOutput() {
        let output = "COMMAND   PID   USER   FD   TYPE DEVICE SIZE/OFF NODE NAME"
        XCTAssertNil(PortInspector.parseLsofOutput(output))
    }
}
