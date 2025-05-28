import Foundation

// TODO: Define the error type more specifically if needed
enum HelperError: Error {
    case connectionInvalid
    case creationFailed(String)
    case destructionFailed(String)
    case generalError(String)
    case unknownMethod
    case missingPID
    case tapNotFound
    case audioBufferError(String)
}

@objc protocol PerAppVolumeHelperProtocol {
    func getAudibleApplications(completion: @escaping ([AudibleApplication]?, Error?) -> Void)
    func createTap(forPID pid: pid_t, appName: String, appBundleID: String, completion: @escaping (Error?) -> Void)
    func destroyTap(forPID pid: pid_t, completion: @escaping (Error?) -> Void)
    func requestAudioBuffer(forPID pid: pid_t, completion: @escaping (Data?, AudioStreamBasicDescription?, Error?) -> Void)
    func setVolume(forPID pid: pid_t, volume: Float, completion: @escaping (Error?) -> Void)
    func setMute(forPID pid: pid_t, isMuted: Bool, completion: @escaping (Error?) -> Void)
}

// Define AudibleApplication struct to be passed over XPC
// Make sure it's compatible with XPC (e.g., by conforming to NSSecureCoding or being a simple property list type)
public struct AudibleApplication: Codable, Identifiable {
    public var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let bundleIdentifier: String
    // Add other relevant properties like icon if needed and feasible
}
