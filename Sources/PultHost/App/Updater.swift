import AppKit
import Observation

/// Checks an appcast for a newer build and installs it. The appcast is a
/// small JSON file on the update server; a release uploads a new notarized
/// zip and bumps the appcast. Nothing is downloaded until the user clicks.
@Observable
final class Updater {
    struct Release: Decodable {
        let version: String        // CFBundleShortVersionString, e.g. "1.2"
        let build: Int             // CFBundleVersion
        let url: URL               // notarized, stapled .zip of Pult.app
        let notes: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case readyToInstall(URL)
        case failed(String)
    }

    /// Overridable so a fork can point at its own server.
    static let feedURL = URL(string: "https://pult.209-74-79-242.sslip.io/appcast.json")!

    private(set) var state: State = .idle
    private var latest: Release?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    private var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0 }

    /// Checks now and every 6 hours.
    func startChecking() {
        Task { await check() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { await self?.check() }
        }
    }

    @MainActor func check() async {
        if case .downloading = state { return }
        state = .checking
        do {
            var request = URLRequest(url: Self.feedURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(Release.self, from: data)
            latest = release
            state = release.build > currentBuild ? .available(version: release.version) : .upToDate
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Downloads the new build and unpacks it next to the running app, ready
    /// to install. Gatekeeper still verifies the notarized zip on launch.
    @MainActor func download() async {
        guard let release = latest else { return }
        state = .downloading
        do {
            let (tempZip, _) = try await URLSession.shared.download(from: release.url)
            let unpacked = try unpack(tempZip)
            state = .readyToInstall(unpacked)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Swaps the new app in and relaunches it. The old app quits.
    func install(_ newApp: URL) {
        let current = Bundle.main.bundleURL
        // A small shell step does the swap after this process exits, then
        // reopens the app. ditto preserves the notarization/signature.
        let script = """
        sleep 1
        /usr/bin/ditto "\(newApp.path)" "\(current.path).new"
        /bin/rm -rf "\(current.path)"
        /bin/mv "\(current.path).new" "\(current.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(current.path)" 2>/dev/null
        /usr/bin/open "\(current.path)"
        """
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", script]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func unpack(_ zip: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pult-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let task = Process()
        task.launchPath = "/usr/bin/ditto"
        task.arguments = ["-x", "-k", zip.path, dir.path]   // ditto reads the zip format `zip -r` / release makes
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                  .first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "Pult", code: 2, userInfo: [NSLocalizedDescriptionKey: "Downloaded update was not readable"])
        }
        return app
    }
}
