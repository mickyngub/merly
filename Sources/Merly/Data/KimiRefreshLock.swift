import Darwin
import Foundation

final class KimiRefreshLock {
    private let path: String
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    private let queue = DispatchQueue(label: "sh.micky.merly.kimi-refresh-lock")
    private var timer: DispatchSourceTimer?
    private var healthy = true

    static func withLock<T>(at target: String, perform: (KimiRefreshLock) throws -> T) throws -> T {
        let lock = try KimiRefreshLock(at: target)
        defer { lock.release() }
        return try perform(lock)
    }

    private init(at target: String) throws {
        path = target + ".lock"
        guard mkdir(path, 0o700) == 0 else {
            throw ProviderAPIError.network("Kimi refresh lock is held or unavailable")
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw ProviderAPIError.network("cannot identify Kimi refresh lock")
        }
        device = info.st_dev
        inode = info.st_ino
        descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if Self.matches(path: path, device: device, inode: inode) { _ = rmdir(path) }
            throw ProviderAPIError.network("cannot open Kimi refresh lock")
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == device, opened.st_ino == inode else {
            close(descriptor)
            throw ProviderAPIError.network("Kimi refresh lock changed during acquisition")
        }
        let heartbeat = DispatchSource.makeTimerSource(queue: queue)
        heartbeat.schedule(deadline: .now() + 1, repeating: 1)
        heartbeat.setEventHandler { [weak self] in self?.heartbeat() }
        timer = heartbeat
        heartbeat.resume()
        do {
            try assertOwnership()
        } catch {
            release()
            throw error
        }
    }

    func assertOwnership() throws {
        let owned = queue.sync {
            heartbeat()
            return healthy
        }
        guard owned else { throw ProviderAPIError.network("Kimi refresh lock ownership was lost") }
    }

    private func heartbeat() {
        guard healthy else { return }
        guard Self.matches(path: path, device: device, inode: inode), futimes(descriptor, nil) == 0 else {
            healthy = false
            return
        }
    }

    private func release() {
        timer?.cancel()
        queue.sync {
            if Self.matches(path: path, device: device, inode: inode) { _ = rmdir(path) }
            close(descriptor)
        }
        timer = nil
    }

    private static func matches(path: String, device: dev_t, inode: ino_t) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            && info.st_dev == device && info.st_ino == inode
    }
}
