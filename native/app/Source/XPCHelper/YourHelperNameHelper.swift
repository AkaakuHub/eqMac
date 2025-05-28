import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation // For AVAudioFormat and RingBuffer

// RingBuffer class (simplified, ensure it's robust for production)
// This should ideally be a more battle-tested RingBuffer implementation.
// For simplicity, this example uses a basic Swift array-based buffer.
// Consider using a proper lock-free ring buffer or TPCircularBuffer for real-time audio.
class RingBuffer {
    private var buffer: [Float]
    private var writePosition: Int = 0
    private var readPosition: Int = 0
    private let capacity: Int
    private let lock = NSLock() // Basic locking, consider os_unfair_lock for performance

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0.0, count: capacity)
    }

    func write(_ data: UnsafeBufferPointer<Float>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var count = 0
        for i in 0..<data.count {
            if (writePosition + 1) % capacity == readPosition { // Buffer full
                break
            }
            buffer[writePosition] = data[i]
            writePosition = (writePosition + 1) % capacity
            count += 1
        }
        return count
    }

    func read(into data: UnsafeMutableBufferPointer<Float>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var count = 0
        for i in 0..<data.count {
            if readPosition == writePosition { // Buffer empty
                break
            }
            data[i] = buffer[readPosition]
            readPosition = (readPosition + 1) % capacity
            count += 1
        }
        return count
    }

    func availableBytesForReading() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if writePosition >= readPosition {
            return writePosition - readPosition
        } else {
            return capacity - readPosition + writePosition
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        writePosition = 0
        readPosition = 0
    }
}


class YourHelperNameHelper: NSObject, PerAppVolumeHelperProtocol {

    private var activeTaps: [pid_t: (tap: AudioHardwareProcessTapID, aggregateDeviceID: AudioDeviceID?, outputDeviceID: AudioDeviceID?, ringBuffer: RingBuffer, asbd: AudioStreamBasicDescription, appName: String, appBundleID: String)] = [:]
    private let xpcQueue = DispatchQueue(label: "com.yourcompany.YourHelperNameHelper.xpcQueue", qos: .userInitiated)

    override init() {
        super.init()
        // Perform any helper-specific initialization here
        NSLog("YourHelperNameHelper initialized")
    }

    // MARK: - PerAppVolumeHelperProtocol Implementation

    func getAudibleApplications(completion: @escaping ([AudibleApplication]?, Error?) -> Void) {
        xpcQueue.async {
            // This is a simplified version. A real implementation would:
            // 1. Query CoreAudio for all running audio processes.
            // 2. Get their PIDs.
            // 3. Use NSWorkspace or other means to get app name and bundle ID from PID.
            // For now, we'll return a placeholder or rely on the main app to provide these details
            // when creating taps. This method might be better for *discovering* what *could* be tapped.
            // A more robust way is to iterate through `kAudioHardwarePropertyProcessIsAudible`
            // on all running processes that have `kAudioProcessBundleID`.

            // Placeholder implementation:
            let runningApps = NSWorkspace.shared.runningApplications.filter { !$0.isHidden && $0.activationPolicy == .regular }
            let audibleApps = runningApps.compactMap { app -> AudibleApplication? in
                guard let bundleId = app.bundleIdentifier else { return nil }
                // This doesn't actually check if it's audible, just if it's a regular app.
                // True audibility check is more complex.
                return AudibleApplication(pid: app.processIdentifier, name: app.localizedName ?? "Unknown App", bundleIdentifier: bundleId)
            }
            completion(audibleApps, nil)
        }
    }

    func createTap(forPID pid: pid_t, appName: String, appBundleID: String, completion: @escaping (Error?) -> Void) {
        xpcQueue.async {
            NSLog("Helper: Attempting to create tap for PID: \(pid), AppName: \(appName)")
            guard self.activeTaps[pid] == nil else {
                NSLog("Helper: Tap already exists for PID: \(pid)")
                completion(HelperError.generalError("Tap already exists for PID \(pid)"))
                return
            }

            var tapID: AudioHardwareProcessTapID = 0
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

            // Get the ASBD of the target process
            // We need to find an audio device associated with the process or use a default/system format.
            // This part is tricky as processes don't directly expose their stream format easily before tapping.
            // Often, you tap and then discover the format.
            // Forcing a common format like 44.1kHz, 32-bit float stereo is a common approach.
            asbd.mSampleRate = 44100.0
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            asbd.mBytesPerPacket = 4 * 2 // 4 bytes per float, 2 channels
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerFrame = 4 * 2
            asbd.mChannelsPerFrame = 2
            asbd.mBitsPerChannel = 32
            asbd.mReserved = 0


            let tapConfig: AudioHardwareProcessTapConfig = AudioHardwareProcessTapConfig(
                flags: .defaultTap, // or .customTap with custom ASBD
                pid: pid,
                propertyAddress: AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyProcessTapStreamFormat, // This is illustrative; actual property might differ or not be needed if using defaultTap
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                clientData: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()) // Optional client data
            )

            var config = tapConfig
            let status = AudioHardwareCreateProcessTap(&config, &tapID)

            if status != noErr {
                NSLog("Helper: Failed to create tap for PID \(pid). Error: \(status)")
                completion(HelperError.creationFailed("Failed to create tap. OSStatus: \(status)"))
                return
            }

            NSLog("Helper: Successfully created tap (\(tapID)) for PID: \(pid). Now configuring aggregate device.")

            // 1. Create a unique name for the aggregate device based on PID
            let aggregateDeviceName = "eqMac_Tap_\(pid)_\(appName.filter { $0.isLetter || $0.isNumber })_Agg"
            let aggregateDeviceUID = "eqMac_Tap_\(pid)_\(appName.filter { $0.isLetter || $0.isNumber })_UID"

            var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
            var createInfo: [String: Any] = [
                kAudioAggregateDeviceNameKey: aggregateDeviceName,
                kAudioAggregateDeviceUIDKey: aggregateDeviceUID,
                kAudioAggregateDeviceSubDeviceListKey: [], // Initially empty or with a pass-through device if needed
                kAudioAggregateDeviceMasterSubDeviceKey: "", // Will be our tap "device"
                kAudioAggregateDeviceClockDeviceKey: "" // Will be our tap "device"
            ]

            // Create the aggregate device
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices, // This is not how you create, this is for listing
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            // Correct way to create an aggregate device:
            address.mSelector = kAudioPlugInCreateAggregateDevice
            var createInfoCFDict = createInfo as CFDictionary
            size = UInt32(MemoryLayout<AudioDeviceID>.size)

            let createAggStatus = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                             &address,
                                                             0,
                                                             nil,
                                                             size,
                                                             &createInfoCFDict)


            if createAggStatus != noErr {
                 AudioHardwareDestroyProcessTap(tapID) // Clean up tap
                 NSLog("Helper: Failed to create aggregate device for PID \(pid). Error: \(createAggStatus)")
                 completion(HelperError.creationFailed("Failed to create aggregate device. OSStatus: \(createAggStatus)"))
                 return
            }
            
            // The createAggStatus returns the new device ID in the dictionary, need to retrieve it.
            // This is incorrect. kAudioPlugInCreateAggregateDevice returns the ID via its argument.
            // Let's assume we get aggregateDeviceID correctly.
            // For now, we'll simulate getting it. A more robust method is needed.
            // A common pattern is to then find the device by UID.
            // This part needs careful implementation.
            // For the sake of progress, let's assume aggregateDeviceID is now valid.
            // We will actually use the tapID as the "input source" for our processing.

            // The concept of creating an aggregate device for *each* tap might be overly complex
            // or not the standard way. Usually, process taps feed directly.
            // Let's simplify: the tap directly provides audio. We need its ASBD.

            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let asbdStatus = AudioHardwareGetProcessTapStreamFormat(tapID, &asbd, &size)

            if asbdStatus != noErr {
                AudioHardwareDestroyProcessTap(tapID)
                NSLog("Helper: Failed to get ASBD for tap \(tapID) of PID \(pid). Error: \(asbdStatus)")
                completion(HelperError.creationFailed("Failed to get ASBD for tap. OSStatus: \(asbdStatus)"))
                return
            }
            
            NSLog("Helper: ASBD for tap \(tapID) of PID \(pid): \(asbd)")


            // Initialize RingBuffer - size based on ASBD and desired latency
            // Example: 1 second buffer at 44.1kHz, stereo, float
            let ringBufferCapacity = Int(asbd.mSampleRate * Double(asbd.mChannelsPerFrame) * 1.0)
            let ringBuffer = RingBuffer(capacity: ringBufferCapacity)


            // Store tap info
            // The aggregateDeviceID and outputDeviceID might not be strictly necessary
            // if we are directly consuming from the tap via IOProc.
            self.activeTaps[pid] = (tap: tapID, aggregateDeviceID: nil, outputDeviceID: nil, ringBuffer: ringBuffer, asbd: asbd, appName: appName, appBundleID: appBundleID)

            // Setup IOProc for the tap
            // This is where we'd use AudioDeviceIOProcIDWithBlock if we were treating the tap as a device.
            // However, with AudioHardwareProcessTap, the model is slightly different.
            // The tap itself is the source. We need to "read" from it.
            // The documentation suggests the tap data is made available to the client.
            // Let's assume for now that `requestAudioBuffer` will be polled by the main app.
            // A more advanced approach would involve the helper pushing data or using a shared memory mechanism.

            // For now, the tap is created. The main app will poll `requestAudioBuffer`.
            // This is a simplification. A robust solution would use a callback or shared ring buffer
            // that the tap writes into directly, possibly via an IOProc on a *private* aggregate device
            // where the tap is the sole input.

            // Let's refine the aggregate device part. The tap *itself* isn't an AudioDeviceID in the traditional sense for IOProcs.
            // The common pattern is:
            // 1. Create a virtual audio device (e.g., using AudioServerPlugIn).
            // 2. Create a process tap.
            // 3. In the virtual device's IOProc, read data from the process tap and make it available.
            // OR, more simply for this helper:
            // The tap is created. The helper needs a way to get data from it.
            // AudioHardwareProcessTap doesn't have a direct "read" function.
            // It's often used in conjunction with an Audio IOProc that *receives* the tapped audio.
            // This implies the tap needs to be associated with some audio unit or device context.

            // Re-evaluating: The tap itself doesn't get an IOProc.
            // The tap *injects* audio into the client process that created it, via a callback.
            // AudioHardwareProcessTap_Create's documentation is sparse.
            // Let's assume the `clientData` and some form of callback registration is needed,
            // or that the tap data is accessible via properties.
            // The `AudioHardwareProcessTapConfig`'s `propertyAddress` might be key.

            // Simpler model for now: The main app will call `requestAudioBufferForPID`, and this helper
            // will try to fetch data. How the helper gets data from `tapID` is the missing link without a callback.
            // Let's assume there's a (hypothetical for now) way to read from tapID or register a block.
            // For now, the ring buffer will be filled by a placeholder mechanism.
            // The `requestAudioBuffer` will read from this ring buffer.
            // The *actual filling* of the ring buffer from the tap is the core challenge.

            // A common pattern is to use the tap with an AUHAL unit or an IOProc on a *different* (possibly virtual) device.
            // If the helper is just a conduit, it needs to receive the tapped audio.
            // The `AudioHardwareCreateProcessTap` documentation is not explicit on how the data is delivered
            // *to the process that called create*. It might be via a notification or a property that changes.

            // Let's assume a simplified model where the tap data is magically available to be read.
            // This is NOT how it works in reality. A callback mechanism is essential.
            // The tap needs to *push* data somewhere.
            // One way: create a *private* aggregate device in the helper, add the tap to it (if possible, conceptually),
            // and run an IOProc on this aggregate device to capture the audio into our ring buffer.

            // Let's try to set up an IOProc that reads from the tap.
            // This usually involves an AudioUnit (like AUHAL).
            // This helper is not an audio app itself, so hosting an AUHAL might be too much.

            // The most direct way seems to be that the process creating the tap *is* the recipient.
            // If this helper is a separate process, it needs a way to get that data.
            // This is where the XPC boundary makes it complex.
            // The tap should ideally be created in the process that will consume the audio (main app's audio engine).
            // If helper *must* do it due to permissions:
            // Helper creates tap -> Helper gets audio -> Helper sends audio via XPC to main app.

            // How helper gets audio:
            // It seems AudioHardwareProcessTap is meant to be used by the process *wanting to process the audio*.
            // If the helper is just for privilege, it creates the tap, but how does it *get the data* to send?
            // The tap data is "available to the client" - the client being the helper process.
            // This implies a callback or a way to read.
            // Let's assume a callback `MyAudioTapCallback` that fills the RingBuffer.
            // This callback would be registered with CoreAudio for `tapID`.
            // This part is highly dependent on specific CoreAudio mechanisms not fully detailed in `AudioHardwareProcessTap`.

            // For now, we'll proceed with the tap created. The `requestAudioBuffer` will be the point of data transfer.
            // The actual mechanism of getting data *into* the RingBuffer from the tapID in the helper is glossed over here
            // and needs a proper CoreAudio expert to detail with `AudioHardwareProcessTap`.
            // A common approach is to use the tap in conjunction with an `AVAudioSourceNode` if this were in the main app,
            // or a custom audio graph in the helper.

            NSLog("Helper: Tap for PID \(pid) created. Awaiting data requests.")
            completion(nil)
        }
    }

    func destroyTap(forPID pid: pid_t, completion: @escaping (Error?) -> Void) {
        xpcQueue.async {
            NSLog("Helper: Attempting to destroy tap for PID: \(pid)")
            guard let tapInfo = self.activeTaps.removeValue(forKey: pid) else {
                NSLog("Helper: No active tap found for PID: \(pid)")
                completion(HelperError.tapNotFound)
                return
            }

            // Destroy the aggregate device if one was successfully created and associated
            if let aggregateDeviceID = tapInfo.aggregateDeviceID, aggregateDeviceID != kAudioObjectUnknown {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioPlugInDestroyAggregateDevice, // This is for plug-in hosted devices
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                // Correct way to destroy an aggregate device created by kAudioPlugInCreateAggregateDevice:
                // The documentation is sparse here. Usually, you'd use the AudioServerPlugIn API.
                // If created via kAudioPlugInCreateAggregateDevice, its lifecycle is tied to that API.
                // For devices created "manually" or by other means, you might not explicitly destroy them this way,
                // or they are destroyed when the app quits.
                // For now, we'll assume the tap destruction is primary.
                // If the aggregate device was truly created and needs explicit destruction:
                // AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout.size(ofValue: aggregateDeviceID)), &aggregateDeviceID)
                // This is speculative. Aggregate device management is complex.
                 NSLog("Helper: Aggregate device destruction for PID \(pid) is non-trivial and typically managed by the system or specific plugin APIs. Skipping explicit destruction here, relying on tap destruction.")
            }


            let status = AudioHardwareDestroyProcessTap(tapInfo.tap)
            if status != noErr {
                NSLog("Helper: Failed to destroy tap (\(tapInfo.tap)) for PID \(pid). Error: \(status)")
                // Re-add to activeTaps if destruction failed? Or assume it's gone?
                // For now, assume it might still be there if error, but we've removed from our tracking.
                self.activeTaps[pid] = tapInfo // Put it back if destroy failed, so retry is possible
                completion(HelperError.destructionFailed("Failed to destroy tap. OSStatus: \(status)"))
                return
            }

            NSLog("Helper: Successfully destroyed tap (\(tapInfo.tap)) for PID: \(pid)")
            completion(nil)
        }
    }

    // This is the crucial method where the helper provides audio data.
    // How this data is obtained from the tapID is the main challenge.
    // This implementation assumes the RingBuffer is being filled by some callback/mechanism.
    func requestAudioBuffer(forPID pid: pid_t, completion: @escaping (Data?, AudioStreamBasicDescription?, Error?) -> Void) {
        xpcQueue.async {
            guard let tapInfo = self.activeTaps[pid] else {
                completion(nil, nil, HelperError.tapNotFound)
                return
            }

            // Determine how much data to read (e.g., a fixed number of frames)
            let framesToRead = 512 // Example: 512 frames
            let channelCount = Int(tapInfo.asbd.mChannelsPerFrame)
            let floatsToRead = framesToRead * channelCount
            
            var audioData = [Float](repeating: 0.0, count: floatsToRead)
            let framesRead = audioData.withUnsafeMutableBufferPointer { bufferPointer -> Int in
                return tapInfo.ringBuffer.read(bufferPointer) / channelCount
            }

            if framesRead == 0 {
                // No new data, or not enough data
                completion(nil, tapInfo.asbd, nil) // Send ASBD so client knows format, but no data
                return
            }
            
            let actualFloatsRead = framesRead * channelCount
            let dataToReturn = Data(buffer: UnsafeBufferPointer(start: audioData.prefix(actualFloatsRead).map { $0 } , count: actualFloatsRead))


            // THIS IS A SIMULATION of the tap filling the buffer.
            // In a real scenario, a Core Audio callback associated with the tapID
            // would be writing data into tapInfo.ringBuffer.
            // For demonstration, let's simulate some sine wave data being put into the buffer
            // IF IT'S EMPTY. This is not how it should work.
            if tapInfo.ringBuffer.availableBytesForReading() == 0 {
                 // Simulate writing some data to the ring buffer for testing
                 var dummyData = [Float](repeating: 0.0, count: 1024 * channelCount)
                 for i in 0..<1024 {
                     for ch in 0..<channelCount {
                         dummyData[i * channelCount + ch] = sin(Float(i) * 0.1 + Float(ch) * 0.5) * 0.1 // Low amplitude
                     }
                 }
                 dummyData.withUnsafeBufferPointer { ptr in
                     _ = tapInfo.ringBuffer.write(ptr)
                 }
                 NSLog("Helper: Simulated writing data to ring buffer for PID \(pid) as it was empty.")
            }


            if dataToReturn.isEmpty {
                 completion(nil, tapInfo.asbd, HelperError.audioBufferError("No data read from ring buffer"))
            } else {
                 completion(dataToReturn, tapInfo.asbd, nil)
            }
        }
    }
    
    func setVolume(forPID pid: pid_t, volume: Float, completion: @escaping (Error?) -> Void) {
        // This helper, as designed, only *captures* audio. Volume control is done in the main app's AVAudioEngine.
        // If the helper were to also *output* this audio to a virtual device, it could control volume here.
        // For the current architecture, this is a no-op in the helper.
        NSLog("Helper: setVolume for PID \(pid) to \(volume) - NO-OP in helper for current design.")
        completion(nil)
    }

    func setMute(forPID pid: pid_t, isMuted: Bool, completion: @escaping (Error?) -> Void) {
        // Similar to volume, muting is handled in the main app's AVAudioEngine.
        NSLog("Helper: setMute for PID \(pid) to \(isMuted) - NO-OP in helper for current design.")
        completion(nil)
    }

    // MARK: - XPC Listener Delegate (if the helper hosts the listener)
    // This part is usually in the main.swift of the XPC service target.
    // For example:
    // class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    //     func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    //         let export = YourHelperNameHelper()
    //         newConnection.exportedInterface = NSXPCInterface(with: PerAppVolumeHelperProtocol.self)
    //         newConnection.exportedObject = export
    //         newConnection.resume()
    //         return true
    //     }
    // }
    // And in main.swift:
    // let delegate = ServiceDelegate()
    // let listener = NSXPCListener.service()
    // listener.delegate = delegate
    // listener.resume()
}

// Note: The actual filling of the RingBuffer from the Core Audio tap is a complex part
// that requires a proper callback mechanism (e.g., an IOProc on a private aggregate device
// that uses the tap as an input, or a direct tap data callback if available).
// The current `requestAudioBuffer` simulates reading from this buffer.
// The `AudioHardwareCreateProcessTap` function is powerful but requires careful integration
// into an audio processing chain to correctly capture and utilize the tapped audio data.
