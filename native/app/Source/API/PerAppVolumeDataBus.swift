import Foundation

class PerAppVolumeDataBus: DataBus {
    // Assuming DataBus is a class or protocol you've defined elsewhere for API communication.
    // If not, this needs to be adapted to your existing API mechanism (e.g., HTTP server, WebSockets).

    private weak var volumeManager: PerApplicationVolumeManager?
    private weak var tapCoordinator: AudioTapCoordinator?

    init(volumeManager: PerApplicationVolumeManager, tapCoordinator: AudioTapCoordinator) {
        self.volumeManager = volumeManager
        self.tapCoordinator = tapCoordinator
        super.init(bridge: nil) // Assuming a base class constructor
        self.setupRoutes()
        NSLog("PerAppVolumeDataBus initialized.")
    }

    private func setupRoutes() {
        // GET /api/per-app/apps - List all known audible applications and their settings
        self.on(.GET, "/per-app/apps") { [weak self] _, response in
            guard let self = self, let vm = self.volumeManager, let tc = self.tapCoordinator else {
                response.error("Internal server error: managers not available")
                return
            }

            let knownApps = tc.getKnownAudibleApps()
            let appSettingsList = knownApps.map { app -> [String: Any] in
                let settings = vm.getSettings(forPID: app.pid) ?? AppAudioSettings(pid: app.pid, appName: app.name, appBundleID: app.bundleIdentifier)
                return [
                    "pid": app.pid,
                    "name": app.name,
                    "bundleIdentifier": app.bundleIdentifier,
                    "volume": settings.volume,
                    "isMuted": settings.isMuted
                ]
            }
            response.json(appSettingsList)
        }

        // POST /api/per-app/tap/:pid - Enable tapping for a specific application
        self.on(.POST, "/per-app/tap/:pid") { [weak self] params, response in
            guard let self = self, let tc = self.tapCoordinator,
                  let pidString = params[":pid"], let pid = pid_t(pidString) else {
                response.error("Invalid PID or coordinator not available", code: 400)
                return
            }
            
            // We need app name and bundle ID to create a tap.
            // The client should provide this, or we look it up from known apps.
            if let app = tc.getKnownAudibleApps().first(where: { $0.pid == pid }) {
                tc.createTap(for: app)
                response.json(["status": "Tap creation initiated for \(app.name)"])
            } else {
                response.error("Application with PID \(pid) not found or not audible.", code: 404)
            }
        }
        
        // DELETE /api/per-app/tap/:pid - Disable tapping for a specific application
        self.on(.DELETE, "/per-app/tap/:pid") { [weak self] params, response in
            guard let self = self, let tc = self.tapCoordinator,
                  let pidString = params[":pid"], let pid = pid_t(pidString) else {
                response.error("Invalid PID or coordinator not available", code: 400)
                return
            }

            if let app = tc.getKnownAudibleApps().first(where: { $0.pid == pid }) {
                tc.destroyTap(forPID: pid, appName: app.name, appBundleID: app.bundleIdentifier)
                response.json(["status": "Tap destruction initiated for \(app.name)"])
            } else {
                // If not in known audible apps, maybe it was tapped and then became inaudible.
                // Attempt to destroy anyway with placeholder info if needed, or just log.
                // For now, require it to be known.
                response.error("Application with PID \(pid) not found in current audible list.", code: 404)
            }
        }


        // PUT /api/per-app/volume/:pid - Set volume for a specific application
        self.on(.PUT, "/per-app/volume/:pid") { [weak self] params, response, body in
            guard let self = self, let vm = self.volumeManager,
                  let pidString = params[":pid"], let pid = pid_t(pidString),
                  let jsonBody = body as? [String: Any],
                  let volume = jsonBody["volume"] as? Double else {
                response.error("Invalid request: PID or volume missing/invalid.", code: 400)
                return
            }
            
            vm.setVolume(forPID: pid, volume: Float(volume))
            response.json(["status": "Volume updated for PID \(pid)"])
        }

        // PUT /api/per-app/mute/:pid - Set mute state for a specific application
        self.on(.PUT, "/per-app/mute/:pid") { [weak self] params, response, body in
            guard let self = self, let vm = self.volumeManager,
                  let pidString = params[":pid"], let pid = pid_t(pidString),
                  let jsonBody = body as? [String: Any],
                  let isMuted = jsonBody["isMuted"] as? Bool else {
                response.error("Invalid request: PID or isMuted missing/invalid.", code: 400)
                return
            }

            vm.setMute(forPID: pid, isMuted: isMuted)
            response.json(["status": "Mute state updated for PID \(pid)"])
        }
        
        NSLog("PerAppVolumeDataBus routes configured.")
    }
    
    // Dummy Response and Params types to match the structure of your DataBus
    // These should be replaced with your actual DataBus types.
    class DummyResponse {
        func json(_ data: Any) { NSLog("DataBus Response (JSON): \(data)") }
        func error(_ message: String, code: Int = 500) { NSLog("DataBus Response (Error \(code)): \(message)")}
    }
    typealias RequestParams = [String: String] // Example: ["pid": "123"]
    typealias RequestBody = Any?

    // Dummy DataBus base class for compilation
    // Replace with your actual DataBus definition
    class DataBus {
        enum HTTPMethod { case GET, POST, PUT, DELETE }
        typealias Handler = (RequestParams, DummyResponse) -> Void
        typealias HandlerWithBody = (RequestParams, DummyResponse, RequestBody) -> Void

        init(bridge: Any?) {} // Placeholder
        func on(_ method: HTTPMethod, _ path: String, handler: @escaping Handler) {}
        func on(_ method: HTTPMethod, _ path: String, handler: @escaping HandlerWithBody) {}
    }
}

// Note: This PerAppVolumeDataBus assumes a structure for your existing `DataBus` class.
// You'll need to adapt the `on`, `params`, `response`, `body` handling,
// and the base class `DataBus` to match your actual implementation in `eqMac`.
// The `DummyResponse`, `RequestParams`, `RequestBody`, and `DataBus` base class are placeholders.
