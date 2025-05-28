import Foundation
import AppKit // For NSWorkspace

// Notification name for when app list changes
extension Notification.Name {
    static let audibleApplicationsChanged = Notification.Name("audibleApplicationsChanged")
}

class AudioTapCoordinator {
    private let xpcClient: XPCClient
    private let volumeManager: PerApplicationVolumeManager
    private var knownAudibleApps: [AudibleApplication] = []
    private var activeTaps: Set<pid_t> = [] // PIDs of apps we are currently tapping

    private var pollTimer: Timer?

    init(xpcClient: XPCClient, volumeManager: PerApplicationVolumeManager) {
        self.xpcClient = xpcClient
        self.volumeManager = volumeManager
        setupObservers()
        startPolling() // Initial poll and start timer
        NSLog("AudioTapCoordinator initialized.")
    }

    private func setupObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                         selector: #selector(handleAppLaunch(_:)),
                                                         name: NSWorkspace.didLaunchApplicationNotification,
                                                         object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                         selector: #selector(handleAppTerminate(_:)),
                                                         name: NSWorkspace.didTerminateApplicationNotification,
                                                         object: nil)
        // Potentially observe audio output changes if possible, though this is harder.
        // kAudioHardwarePropertyProcessIsAudible might be an option but requires more complex CoreAudio listening.
    }

    @objc private func handleAppLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier,
              let appName = app.localizedName else { return }
        
        NSLog("App launched: \(appName) (\(app.processIdentifier))")
        // Don't create tap immediately. Wait for poll or explicit user action.
        // Refresh list to include it if it becomes audible.
        pollForAudibleApplications()
    }

    @objc private func handleAppTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        NSLog("App terminated: \(app.localizedName ?? "Unknown") (\(pid))")
        
        if activeTaps.contains(pid) {
            destroyTap(forPID: pid, appName: app.localizedName ?? "Unknown", appBundleID: app.bundleIdentifier ?? "")
        }
        // Refresh list
        knownAudibleApps.removeAll { $0.pid == pid }
        NotificationCenter.default.post(name: .audibleApplicationsChanged, object: knownAudibleApps)
    }

    private func startPolling() {
        pollForAudibleApplications() // Initial poll
        pollTimer?.invalidate() // Invalidate existing timer if any
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.pollForAudibleApplications()
        }
    }

    func pollForAudibleApplications() {
        NSLog("Polling for audible applications...")
        xpcClient.getAudibleApplications { [weak self] apps, error in
            guard let self = self else { return }
            if let error = error {
                NSLog("Error polling for audible apps: \(error.localizedDescription)")
                // Handle error, maybe retry or notify user
                return
            }

            guard let newApps = apps else {
                NSLog("No apps returned from helper.")
                // If list is empty, ensure we clean up any stale taps
                if !self.knownAudibleApps.isEmpty {
                     self.knownAudibleApps.forEach { oldApp in
                        if self.activeTaps.contains(oldApp.pid) {
                            self.destroyTap(forPID: oldApp.pid, appName: oldApp.name, appBundleID: oldApp.bundleIdentifier)
                        }
                    }
                    self.knownAudibleApps = []
                    NotificationCenter.default.post(name: .audibleApplicationsChanged, object: self.knownAudibleApps)
                }
                return
            }
            
            NSLog("Helper returned \(newApps.count) audible apps.")

            // Naive update: just replace and notify.
            // A more sophisticated diff would be better to avoid unnecessary UI reloads
            // and to manage tap creation/destruction more precisely.
            if self.knownAudibleApps != newApps { // Basic check for change
                self.knownAudibleApps = newApps
                NSLog("Audible applications list updated. Posting notification.")
                NotificationCenter.default.post(name: .audibleApplicationsChanged, object: newApps)
                
                // Manage taps based on the new list (example: auto-tap all audible apps)
                // This logic might be too aggressive. Consider user preferences.
                // self.updateTapsBasedOnAudibleApps(newApps)
            }
        }
    }
    
    // Example: function to automatically manage taps based on discovered audible apps
    // This might be too aggressive. User should ideally control which apps are tapped.
    /*
    private func updateTapsBasedOnAudibleApps(_ currentAudibleApps: [AudibleApplication]) {
        let currentPIDs = Set(currentAudibleApps.map { $0.pid })
        
        // Destroy taps for apps no longer audible (or running)
        for pidToDestroy in activeTaps.subtracting(currentPIDs) {
            if let app = knownAudibleApps.first(where: { $0.pid == pidToDestroy }) { // Or find from a master list
                 destroyTap(forPID: pidToDestroy, appName: app.name, appBundleID: app.bundleIdentifier)
            } else {
                // If app info not found, use placeholder names or log
                destroyTap(forPID: pidToDestroy, appName: "Unknown App", appBundleID: "unknown.bundle.id")
            }
        }
        
        // Create taps for new audible apps
        for appToTap in currentAudibleApps where !activeTaps.contains(appToTap.pid) {
            createTap(for: appToTap)
        }
    }
    */

    func createTap(for app: AudibleApplication) {
        guard !activeTaps.contains(app.pid) else {
            NSLog("Tap already active for \(app.name) (\(app.pid))")
            return
        }

        NSLog("Requesting XPC to create tap for \(app.name) (\(app.pid))")
        xpcClient.createTap(forPID: app.pid, appName: app.name, appBundleID: app.bundleIdentifier) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                NSLog("Failed to create tap for \(app.name) (\(app.pid)): \(error.localizedDescription)")
                // Notify UI or handle error
            } else {
                NSLog("Successfully requested tap creation for \(app.name) (\(app.pid)).")
                self.activeTaps.insert(app.pid)
                // Now that tap is created (or request sent), tell VolumeManager to prepare for it
                self.volumeManager.prepareForApplication(app)
                NSLog("Informed VolumeManager to prepare for \(app.name)")
            }
        }
    }

    func destroyTap(forPID pid: pid_t, appName: String, appBundleID: String) {
        guard activeTaps.contains(pid) else {
            NSLog("No active tap to destroy for PID \(pid)")
            return
        }
        
        NSLog("Requesting XPC to destroy tap for \(appName) (\(pid))")
        xpcClient.destroyTap(forPID: pid) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                NSLog("Failed to destroy tap for \(appName) (\(pid)): \(error.localizedDescription)")
                // Notify UI or handle error
            } else {
                NSLog("Successfully requested tap destruction for \(appName) (\(pid)).")
                self.activeTaps.remove(pid)
                self.volumeManager.removeApplication(pid: pid) // Clean up in VolumeManager
                NSLog("Informed VolumeManager to remove \(appName)")
            }
        }
    }
    
    func getKnownAudibleApps() -> [AudibleApplication] {
        return knownAudibleApps
    }

    deinit {
        pollTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Destroy all active taps on deinit?
        activeTaps.forEach { pid in
            // Need appName and bundleID here, might need to store the full AudibleApplication object
            if let app = knownAudibleApps.first(where: { $0.pid == pid }) {
                destroyTap(forPID: pid, appName: app.name, appBundleID: app.bundleIdentifier)
            } else {
                 NSLog("Could not find app info for PID \(pid) during deinit cleanup.")
                 // Attempt to destroy with placeholder info if necessary, or log.
                 // This scenario should be rare if knownAudibleApps is kept consistent.
            }
        }
        NSLog("AudioTapCoordinator deinitialized.")
    }
}

// Implement != for AudibleApplication if not already done by Codable and structure.
// For basic comparison, if all properties are Equatable, it should work.
// If not, provide an explicit Equatable conformance.
extension AudibleApplication: Equatable {
    public static func == (lhs: AudibleApplication, rhs: AudibleApplication) -> Bool {
        return lhs.pid == rhs.pid &&
               lhs.name == rhs.name &&
               lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}
