import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Implements the cross-invocation concurrency guard from the design doc §3:
/// config-mutating commands (kernel switch, sub switch, sub add, net, mode)
/// take this lock before touching anything, so a second invocation racing
/// the first is rejected cleanly instead of corrupting state.
///
/// Backed by a real flock(2) exclusive lock on a file under
/// ~/.mihomo-cli/. flock is held by the OS for the lifetime of the file
/// descriptor, so it is released automatically on process exit — including
/// crashes and SIGKILL — with no cleanup code required. This is why flock
/// was chosen over a "lockfile containing a PID" convention: a stale PID
/// file can outlive a crashed process and wedge every future invocation,
/// whereas a kernel-held flock cannot.
final class AdvisoryLock {
    enum LockError: Error {
        case couldNotOpenLockFile(path: String, errno: Int32)
        case couldNotCreateLockDirectory(path: String, errno: Int32)
    }

    private let lockFilePath: String
    private var fileDescriptor: Int32 = -1

    init(lockFilePath: String = "\(NSHomeDirectory())/.mihomo-cli/lock") {
        self.lockFilePath = lockFilePath
    }

    /// Attempts to acquire the lock immediately (non-blocking).
    /// Throws `.conflict` per the exit-code table if another mutating
    /// operation currently holds it; throws `LockError` for unrelated
    /// filesystem failures (permissions, missing home directory, etc.)
    /// which are not the caller's concern to distinguish from a plain
    /// "couldn't start" failure.
    func acquire() throws {
        let directory = (lockFilePath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw LockError.couldNotCreateLockDirectory(path: directory, errno: errno)
            }
        }

        let fd = open(lockFilePath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw LockError.couldNotOpenLockFile(path: lockFilePath, errno: errno)
        }

        // LOCK_EX | LOCK_NB: exclusive, non-blocking. We want an immediate
        // "someone else has it" answer, never a hang — per every command
        // spec, a concurrent mutating operation is a clean, fast exit-4
        // error ("operation already in progress"), not a wait.
        let result = flock(fd, LOCK_EX | LOCK_NB)
        if result != 0 {
            let capturedErrno = errno
            close(fd)
            if capturedErrno == EWOULDBLOCK {
                throw CLIError(
                    what: "operation already in progress",
                    cause: "another mihomo command is currently running a config-mutating operation",
                    fix: "wait for it to finish and retry",
                    exitCode: .conflict
                )
            }
            throw LockError.couldNotOpenLockFile(path: lockFilePath, errno: capturedErrno)
        }

        fileDescriptor = fd
    }

    /// Releases the lock and closes the file descriptor. Safe to call
    /// multiple times or without a prior successful `acquire()`.
    func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }

    /// Convenience wrapper: acquire, run the closure, always release —
    /// mirrors what every mutating command handler should do.
    func withLock<T>(_ body: () async throws -> T) async throws -> T {
        try acquire()
        defer { release() }
        return try await body()
    }

    deinit {
        release()
    }
}
