import Foundation
import AVFoundation

// Represents the audio settings for a single application
struct AppAudioSettings: Codable {
    let pid: pid_t
    var volume: Float = 1.0 // 0.0 to 1.0
    var isMuted: Bool = false
    // Add last known name/bundleID for persistence/display if needed
    var appName: String?
    var appBundleID: String?
}

class PerApplicationVolumeManager {
    private let engine: AVAudioEngine
    private let xpcClient: XPCClient
    private var appAudioNodes: [pid_t: (sourceNode: AVAudioSourceNode, mixerNode: AVAudioMixerNode, settings: AppAudioSettings)] = [:]
    private let audioProcessingQueue = DispatchQueue(label: "com.eqmac.audioprocessing", qos: .userInitiated)
    private let settingsQueue = DispatchQueue(label: "com.eqmac.settingsaccess", qos: .utility)
    private var dataFetchTimer: Timer?

    // Main output mixer for all per-app streams (connect this to further processing or main output)
    let outputMixer = AVAudioMixerNode()

    init(engine: AVAudioEngine, xpcClient: XPCClient) {
        self.engine = engine
        self.xpcClient = xpcClient
        
        // Attach the main output mixer for per-app streams
        engine.attach(outputMixer)
        // Connect it to the engine's mainMixerNode or another destination
        // This connection point depends on eqMac's existing audio graph.
        // For example, if you want per-app volumes *before* global EQ:
        // engine.connect(outputMixer, to: engine.mainMixerNode, format: nil)
        // Or, if eqMac has a specific "effects chain input" node:
        // engine.connect(outputMixer, to: effectsChainInputNode, format: nil)
        // This needs to be adapted to the actual Engine.swift structure.
        // For now, let's assume a direct connection to mainMixerNode.
        // The format should match the engine's processing format.
        let audioFormat = engine.mainMixerNode.outputFormat(forBus: 0) // Or a standard format
        if audioFormat.sampleRate > 0 { // Ensure format is valid
             engine.connect(outputMixer, to: engine.mainMixerNode, format: audioFormat)
        } else {
            // Fallback or error if format is not available. This indicates an engine setup issue.
            let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
            engine.connect(outputMixer, to: engine.mainMixerNode, format: defaultFormat)
            NSLog("PerApplicationVolumeManager: Warning - mainMixerNode output format invalid, using default.")
        }


        loadSettings()
        startDataFetchTimer()
        NSLog("PerApplicationVolumeManager initialized. Output mixer attached and connected.")
    }

    private func startDataFetchTimer() {
        dataFetchTimer?.invalidate()
        dataFetchTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in // ~50 FPS
            self?.fetchAllAppAudioBuffers()
        }
    }

    private func fetchAllAppAudioBuffers() {
        audioProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            for (pid, nodeInfo) in self.appAudioNodes {
                // Only fetch if sourceNode is active and app not muted (though sourceNode handles mute)
                // if nodeInfo.settings.isMuted { continue }
                
                self.xpcClient.requestAudioBuffer(forPID: pid) { data, asbd, error in
                    if let error = error {
                        NSLog("Error fetching audio buffer for PID \(pid): \(error.localizedDescription)")
                        // Consider stopping node or handling error
                        return
                    }
                    
                    guard let audioData = data, let streamDescription = asbd else {
                        // No data or ASBD, maybe app is silent
                        return
                    }
                    
                    // Ensure the source node can handle this format.
                    // This is where format conversion might be needed if ASBDs vary.
                    // For simplicity, assuming helper provides a consistent format or sourceNode can adapt.
                    // The sourceNode's render block receives PCM buffer.
                    
                    // The AVAudioSourceNode's render block will be called by the engine.
                    // We need to provide data *to* that render block.
                    // This polling mechanism needs to feed a buffer that the render block reads from.
                    
                    // This current approach of directly trying to "push" data via a timer
                    // into a source node is not the standard way. The source node *pulls*
                    // data via its render block. We need to make `audioData` available to that block.
                    
                    // Let's store this data in a temporary buffer accessible by the render block.
                    // This needs careful synchronization.
                    // For now, this is a placeholder for a more robust buffering strategy.
                    // The render block itself should be designed to pull from such a buffer.
                    
                    // This `fetchAndBufferData` is illustrative. The actual data provision
                    // happens in the sourceNode's render block. This timer should *trigger*
                    // the render block or ensure data is ready for it.
                    // The sourceNode itself will call its render block when it needs data.
                    // Our job is to ensure the XPC data is available for that block.
                    
                    // This part is complex. The source node's render block needs access to this fetched data.
                    // We'll need a per-app ring buffer here too, filled by this XPC callback,
                    // and read by the respective sourceNode's render block.
                    
                    // For now, let's assume the render block (defined in prepareForApplication)
                    // has a way to access this. This is a conceptual gap to be filled.
                    // The `renderBlock` in `prepareForApplication` needs to be implemented
                    // to consume data fetched here.
                }
            }
        }
    }


    func prepareForApplication(_ app: AudibleApplication) {
        audioProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            
            if self.appAudioNodes[app.pid] != nil {
                NSLog("Already prepared for application \(app.name) (\(app.pid))")
                return
            }

            NSLog("Preparing audio nodes for \(app.name) (\(app.pid))")

            // Retrieve or create settings for this app
            var settings = self.settingsQueue.sync {
                self.appAudioNodes[app.pid]?.settings ?? AppAudioSettings(pid: app.pid, appName: app.name, appBundleID: app.bundleIdentifier)
            }
            settings.appName = app.name // Update name in case it changed
            settings.appBundleID = app.bundleIdentifier


            // The format for the source node should ideally come from the XPC helper (ASBD).
            // For now, let's assume a common format or that the helper will provide it.
            // This format MUST match what the XPC helper's `requestAudioBuffer` provides.
            // We should get this from the first successful `requestAudioBuffer` call.
            // Placeholder format:
            guard let appAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else {
                 NSLog("Failed to create AVAudioFormat for \(app.name). Cannot prepare source node.")
                 return
            }


            // Create a source node that will be fed by the XPC audio data
            let sourceNode = AVAudioSourceNode(format: appAudioFormat) { [weak self] (isSilence, timestamp, frameCount, audioBufferList) -> OSStatus in
                guard let self = self, let strongSelf = self else { return noErr } // Or some error code
                
                // This block is called by the audio engine when it needs data for this source.
                // We need to get data from our XPC client for app.pid and fill audioBufferList.
                // This requires a buffering mechanism between the XPC data arrival and this render block.
                
                // For now, let's fill with silence. This needs to be replaced with actual data.
                // TODO: Implement proper buffering and data retrieval from XPC here.
                
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in abl {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                // Mark as silence if no data
                // isSilence.pointee = true 
                
                // If you have data in a ring buffer for this PID:
                // strongSelf.pidSpecificRingBuffers[app.pid]?.read(into: abl, count: frameCount)
                // And set isSilence.pointee accordingly.

                return noErr
            }

            let mixerNode = AVAudioMixerNode()
            mixerNode.volume = settings.isMuted ? 0.0 : settings.volume
            mixerNode.outputVolume = settings.isMuted ? 0.0 : settings.volume // Redundant? volume is enough.

            self.engine.attach(sourceNode)
            self.engine.attach(mixerNode)

            // Connect source -> app's mixer -> main per-app output mixer
            self.engine.connect(sourceNode, to: mixerNode, format: appAudioFormat)
            self.engine.connect(mixerNode, to: self.outputMixer, format: appAudioFormat) // Ensure format matches outputMixer's input

            self.settingsQueue.sync {
                 self.appAudioNodes[app.pid] = (sourceNode: sourceNode, mixerNode: mixerNode, settings: settings)
            }
           
            NSLog("Attached and connected audio nodes for \(app.name) (\(app.pid)). Volume: \(settings.volume), Muted: \(settings.isMuted)")
            self.saveSettings()
        }
    }

    func removeApplication(pid: pid_t) {
        audioProcessingQueue.async { [weak self] in
            guard let self = self, let nodeInfo = self.appAudioNodes.removeValue(forKey: pid) else { return }

            NSLog("Removing audio nodes for PID \(pid)")
            self.engine.disconnectNodeOutput(nodeInfo.sourceNode)
            self.engine.disconnectNodeOutput(nodeInfo.mixerNode)
            self.engine.detach(nodeInfo.sourceNode)
            self.engine.detach(nodeInfo.mixerNode)
            
            self.settingsQueue.sync {
                // Settings are already removed by appAudioNodes.removeValue(forKey: pid)
                // If you persist settings separately, remove them here too.
            }
            NSLog("Detached and disconnected audio nodes for PID \(pid)")
            self.saveSettings() // Save settings after removal if necessary (e.g. to remove from persisted list)
        }
    }

    func setVolume(forPID pid: pid_t, volume: Float) {
        let clampedVolume = max(0.0, min(1.0, volume))
        audioProcessingQueue.async { [weak self] in
            guard let self = self, let nodeInfo = self.appAudioNodes[pid] else { return }
            if !nodeInfo.settings.isMuted { // Only apply if not muted
                nodeInfo.mixerNode.outputVolume = clampedVolume
            }
            self.settingsQueue.sync {
                self.appAudioNodes[pid]?.settings.volume = clampedVolume
            }
            NSLog("Set volume for PID \(pid) to \(clampedVolume)")
            self.saveSettings()
        }
    }

    func setMute(forPID pid: pid_t, isMuted: Bool) {
        audioProcessingQueue.async { [weak self] in
            guard let self = self, let nodeInfo = self.appAudioNodes[pid] else { return }
            nodeInfo.mixerNode.outputVolume = isMuted ? 0.0 : nodeInfo.settings.volume
            self.settingsQueue.sync {
                self.appAudioNodes[pid]?.settings.isMuted = isMuted
            }
            NSLog("Set mute for PID \(pid) to \(isMuted)")
            self.saveSettings()
        }
    }
    
    func getSettings(forPID pid: pid_t) -> AppAudioSettings? {
        return settingsQueue.sync {
            self.appAudioNodes[pid]?.settings
        }
    }

    func getAllAppSettings() -> [AppAudioSettings] {
        return settingsQueue.sync {
            Array(self.appAudioNodes.values.map { $0.settings })
        }
    }

    // MARK: - Persistence
    private var settingsFileURL: URL {
        // Get app's support directory
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.eqmac" // Fallback bundle ID
        let dirPath = appSupportDir.appendingPathComponent(bundleID)
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true, attributes: nil)
        
        return dirPath.appendingPathComponent("perAppAudioSettings.json")
    }

    private func saveSettings() {
        settingsQueue.async { [weak self] in // Perform file I/O off main/audio threads
            guard let self = self else { return }
            let allSettings = Array(self.appAudioNodes.values.map { $0.settings })
            do {
                let data = try JSONEncoder().encode(allSettings)
                try data.write(to: self.settingsFileURL)
                NSLog("Saved per-app audio settings to \(self.settingsFileURL)")
            } catch {
                NSLog("Failed to save per-app audio settings: \(error)")
            }
        }
    }

    private func loadSettings() {
        settingsQueue.async { [weak self] in // Perform file I/O off main/audio threads
            guard let self = self else { return }
            do {
                let data = try Data(contentsOf: self.settingsFileURL)
                let loadedAppSettings = try JSONDecoder().decode([AppAudioSettings].self, from: data)
                
                // Apply loaded settings. This might involve creating nodes if apps are already running,
                // or just storing them until `prepareForApplication` is called.
                // For simplicity, we'll just store them. `prepareForApplication` will use them.
                self.audioProcessingQueue.async { // Switch to audio queue to update nodes
                    for settings in loadedAppSettings {
                        // If nodes for this PID already exist (e.g., app was running and detected before settings loaded), update them.
                        if var existingNodeInfo = self.appAudioNodes[settings.pid] {
                            existingNodeInfo.settings = settings
                            if !settings.isMuted {
                                existingNodeInfo.mixerNode.outputVolume = settings.volume
                            } else {
                                existingNodeInfo.mixerNode.outputVolume = 0.0
                            }
                            self.appAudioNodes[settings.pid] = existingNodeInfo
                             NSLog("Applied loaded settings for running PID \(settings.pid)")
                        } else {
                            // Store for later use when/if prepareForApplication is called for this PID
                            // This requires appAudioNodes to temporarily store settings for non-active PIDs
                            // Or, more simply, `prepareForApplication` should always check loaded settings.
                            // The current structure of appAudioNodes only holds active PIDs.
                            // So, we need a separate store for loaded settings not yet active,
                            // or `prepareForApplication` must consult this loaded list.

                            // Let's adjust: `appAudioNodes` settings will be the source of truth.
                            // When `prepareForApplication` is called, it will look up persisted settings.
                            // So, we just need to populate a temporary dictionary here or ensure
                            // `prepareForApplication` can access these loaded settings.

                            // Simplest: when prepareForApplication is called, it checks a dictionary of loaded settings.
                            // For now, let's assume `prepareForApplication` will handle merging with persisted data.
                            // The current `prepareForApplication` creates default settings if not found.
                            // We need it to use these loaded ones.
                            // So, let's update `appAudioNodes` directly if we can create placeholder entries.
                            // This is tricky because nodes aren't created yet.

                            // Alternative: `prepareForApplication` calls a method `getPersistedSettings(forPID:)`.
                            // For now, this load just pre-populates the `settings` part of `appAudioNodes`
                            // if the PID is already known (e.g. from a quick initial scan).
                            // This part needs refinement for robust settings application at startup.
                            NSLog("Loaded settings for PID \(settings.pid): Vol \(settings.volume), Mute \(settings.isMuted). Will be applied if app becomes active.")
                            // We can store these settings in a temporary dictionary that `prepareForApplication` consults.
                            // For now, this load is more of a "warm cache" for when `prepareForApplication` runs.
                        }
                    }
                    NSLog("Loaded \(loadedAppSettings.count) per-app audio settings from \(self.settingsFileURL)")
                }
            } catch {
                NSLog("Failed to load per-app audio settings (or file doesn't exist): \(error)")
            }
        }
    }
    
    deinit {
        dataFetchTimer?.invalidate()
        // Consider cleanup of nodes, though engine deinit should handle some of this.
        NSLog("PerApplicationVolumeManager deinitialized.")
    }
}

// Ensure AVAudioEngine is prepared before making connections or attaching nodes.
// Call `engine.prepare()` if not already done.
// Start engine `try engine.start()` after graph is set up.
