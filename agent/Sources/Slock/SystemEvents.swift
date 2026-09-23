import AppKit
import Network
import CoreServices

/// Logs sleep/wake, lock/unlock, app launch/quit, volume mounts, network changes and new downloads.
final class SystemEvents {
    private let pathMonitor = NWPathMonitor()
    private var lastPathDesc: String?
    private var downloadsStream: FSEventStreamRef?
    private var seenDownloads = Set<String>()

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        let db = Database.shared
        let state = State.shared

        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            state.asleep = true
            db.event("sleep")
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            state.asleep = false
            db.event("wake")
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            db.event("display_sleep")
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            db.event("display_wake")
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            db.event("app_launch", Self.appInfo(n))
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            db.event("app_quit", Self.appInfo(n))
        }
        ws.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { n in
            db.event("volume_mount", Self.volumeInfo(n))
        }
        ws.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { n in
            db.event("volume_unmount", Self.volumeInfo(n))
        }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            if !state.screenLocked { state.screenLocked = true; db.event("screen_locked") }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            if state.screenLocked { state.screenLocked = false; db.event("screen_unlocked") }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let ifaces = path.availableInterfaces.map { "\($0.name):\(Self.typeName($0.type))" }
            let desc = "\(path.status)|\(ifaces.joined(separator: ","))"
            guard desc != self.lastPathDesc else { return }
            self.lastPathDesc = desc
            db.event("network_change", [
                "status": "\(path.status)",
                "interfaces": ifaces,
                "expensive": path.isExpensive,
            ])
        }
        pathMonitor.start(queue: DispatchQueue(label: "slock.network"))

        watchDownloads()
    }

    private static func appInfo(_ n: Notification) -> [String: Any] {
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return ["app": app?.localizedName ?? "?", "bundle_id": app?.bundleIdentifier ?? ""]
    }

    private static func volumeInfo(_ n: Notification) -> [String: Any] {
        let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
        let name = n.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String
        return ["path": url?.path ?? "", "name": name ?? ""]
    }

    private static func typeName(_ t: NWInterface.InterfaceType) -> String {
        switch t {
        case .wifi: return "wifi"
        case .wiredEthernet: return "ethernet"
        case .cellular: return "cellular"
        case .loopback: return "loopback"
        default: return "other"
        }
    }

    // MARK: - Downloads

    private func watchDownloads() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info = info else { return }
            let me = Unmanaged<SystemEvents>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            for i in 0..<count {
                me.handleDownload(path: paths[i], flags: flags[i])
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &ctx, [dir] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else {
            log("could not watch ~/Downloads")
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "slock.fsevents"))
        FSEventStreamStart(stream)
        downloadsStream = stream
    }

    private func handleDownload(path: String, flags: FSEventStreamEventFlags) {
        let created = flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
        let renamed = flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        let isFile = flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
        guard (created || renamed), isFile else { return }
        let name = (path as NSString).lastPathComponent
        let tempExts = ["crdownload", "download", "part", "tmp", "partial"]
        guard !name.hasPrefix("."), !tempExts.contains((name as NSString).pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: path), !seenDownloads.contains(path) else { return }
        seenDownloads.insert(path)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        Database.shared.event("download", ["path": path, "name": name, "bytes": size])
    }
}
