import XCTest
@testable import mihomo_cli

final class NetworkSetupTests: XCTestCase {

    func testParseServiceList() {
        let sampleOutput = """
        An asterisk (*) denotes that a network service is disabled.
        Wi-Fi
        *Bluetooth PAN
        Thunderbolt Bridge
        USB 10/100/1000 LAN

        """
        let services = NetworkSetup.parseServiceList(sampleOutput)
        XCTAssertEqual(services, ["Wi-Fi", "Thunderbolt Bridge", "USB 10/100/1000 LAN"])
    }

    func testIsServiceActive() {
        let activeInfo = """
        DHCP Configuration
        IP address: 192.168.1.105
        Subnet mask: 255.255.255.0
        Router: 192.168.1.1
        Client ID: 
        IPv6: Automatic
        """
        XCTAssertTrue(NetworkSetup.isServiceActive(infoOutput: activeInfo))

        let inactiveInfo = """
        IP address: none
        Subnet mask: none
        Router: none
        """
        XCTAssertFalse(NetworkSetup.isServiceActive(infoOutput: inactiveInfo))

        let zeroInfo = """
        IP address: 0.0.0.0
        """
        XCTAssertFalse(NetworkSetup.isServiceActive(infoOutput: zeroInfo))
    }

    func testParseWebProxyOutput() {
        let sampleEnabled = """
        Enabled: Yes
        Server: 127.0.0.1
        Port: 7890
        Authenticated Proxy Enabled: 0
        """
        let info1 = NetworkSetup.parseWebProxyOutput(sampleEnabled)
        XCTAssertTrue(info1.enabled)
        XCTAssertEqual(info1.server, "127.0.0.1")
        XCTAssertEqual(info1.port, 7890)

        let sampleDisabled = """
        Enabled: No
        Server: 
        Port: 0
        Authenticated Proxy Enabled: 0
        """
        let info2 = NetworkSetup.parseWebProxyOutput(sampleDisabled)
        XCTAssertFalse(info2.enabled)
        XCTAssertEqual(info2.server, "")
        XCTAssertEqual(info2.port, 0)
    }

    func testPortInspectorParseLsofOutput() {
        let sampleLsof = """
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        mihomo  58301 john    7u  IPv4 0x2e06cbfa7c32bf97      0t0  TCP *:7890 (LISTEN)
        """
        let info = PortInspector.parseLsofOutput(sampleLsof)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.command, "mihomo")
        XCTAssertEqual(info?.pid, 58301)

        let emptyLsof = """
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        """
        XCTAssertNil(PortInspector.parseLsofOutput(emptyLsof))
    }
}
