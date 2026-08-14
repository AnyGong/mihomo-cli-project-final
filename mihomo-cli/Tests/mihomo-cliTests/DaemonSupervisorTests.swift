import XCTest
@testable import mihomo_cli

final class DaemonSupervisorTests: XCTestCase {

    func testTick_noRunningKernelTracked_doesNothing() async throws {
        var startCalls: [String?] = []
        let supervisor = DaemonSupervisor(
            runningKernel: { nil },
            daemonState: { DaemonState() },
            updateDaemonState: { _ in XCTFail("should not update daemon state") },
            isProcessRunning: { _ in XCTFail("should not check liveness"); return false },
            startKernel: { v in startCalls.append(v) }
        )

        await supervisor.tick()

        XCTAssertTrue(startCalls.isEmpty)
    }

    func testTick_kernelStillAlive_doesNothing() async throws {
        var startCalls: [String?] = []
        let running = RunningKernelState(
            version: "v1.19.29", pid: 4242, startedAt: Date(),
            controlPort: 9090, mixedPort: 7890,
            configPath: "/tmp/config.yaml", stdoutPath: "/tmp/out.log", stderrPath: "/tmp/err.log"
        )
        let supervisor = DaemonSupervisor(
            runningKernel: { running },
            daemonState: { DaemonState() },
            updateDaemonState: { _ in XCTFail("should not update daemon state") },
            isProcessRunning: { pid in pid == 4242 },
            startKernel: { v in startCalls.append(v) }
        )

        await supervisor.tick()

        XCTAssertTrue(startCalls.isEmpty)
    }

    func testTick_kernelGoneAfterUserInitiatedStop_doesNotRestart() async throws {
        var startCalls: [String?] = []
        let running = RunningKernelState(
            version: "v1.19.29", pid: 4242, startedAt: Date(),
            controlPort: 9090, mixedPort: 7890,
            configPath: "/tmp/config.yaml", stdoutPath: "/tmp/out.log", stderrPath: "/tmp/err.log"
        )
        let supervisor = DaemonSupervisor(
            runningKernel: { running },
            daemonState: { DaemonState(lastStopWasUserInitiated: true) },
            updateDaemonState: { _ in XCTFail("should not update daemon state — user-initiated stop must not count as a restart") },
            isProcessRunning: { _ in false },
            startKernel: { v in startCalls.append(v) }
        )

        await supervisor.tick()

        XCTAssertTrue(startCalls.isEmpty, "must not relaunch after a user-initiated 'mihomo stop'")
    }

    func testTick_kernelGoneUnexpectedly_restartsAndRecordsCount() async throws {
        var startCalls: [String?] = []
        var updatedState: DaemonState?
        let running = RunningKernelState(
            version: "v1.19.29", pid: 4242, startedAt: Date(),
            controlPort: 9090, mixedPort: 7890,
            configPath: "/tmp/config.yaml", stdoutPath: "/tmp/out.log", stderrPath: "/tmp/err.log"
        )
        let supervisor = DaemonSupervisor(
            runningKernel: { running },
            daemonState: { DaemonState(restartCount: 2, lastStopWasUserInitiated: false) },
            updateDaemonState: { body in
                var s = DaemonState(restartCount: 2, lastStopWasUserInitiated: false)
                body(&s)
                updatedState = s
            },
            isProcessRunning: { _ in false },
            startKernel: { v in startCalls.append(v) }
        )

        await supervisor.tick()

        XCTAssertEqual(startCalls, ["v1.19.29"], "must relaunch the exact version that was running")
        XCTAssertEqual(updatedState?.restartCount, 3, "restart count must increment — this is the exact bug: it stayed at 0")
        XCTAssertNotNil(updatedState?.lastRestartAt)
        XCTAssertEqual(updatedState?.lastRestartReason, "kernel exited unexpectedly (was pid 4242)")
    }

    func testTick_restartFails_doesNotCrashAndLeavesCountUnchangedForNextTick() async throws {
        var updateCalled = false
        let running = RunningKernelState(
            version: "v1.19.29", pid: 4242, startedAt: Date(),
            controlPort: 9090, mixedPort: 7890,
            configPath: "/tmp/config.yaml", stdoutPath: "/tmp/out.log", stderrPath: "/tmp/err.log"
        )
        let supervisor = DaemonSupervisor(
            runningKernel: { running },
            daemonState: { DaemonState() },
            updateDaemonState: { _ in updateCalled = true },
            isProcessRunning: { _ in false },
            startKernel: { _ in throw CLIError(what: "kernel binary missing", cause: "gone", exitCode: .sourceVerificationFailure) }
        )

        await supervisor.tick() // must not throw/crash the loop

        XCTAssertFalse(updateCalled, "a failed restart attempt must not be recorded as a successful one")
    }
}
