import Foundation

class XPCClient: NSObject {
    private var connection: NSXPCConnection?
    private let serviceName = "com.yourcompany.YourHelperName.Helper" // IMPORTANT: Match this with XPC service's Info.plist
    private var currentHelperVersion: String? // Store the installed helper's version

    private var onConnectionInterrupted: (() -> Void)?
    private var onConnectionInvalidated: (() -> Void)?

    override init() {
        super.init()
    }

    private func setupConnection() {
        if connection != nil {
            return
        }
        
        connection = NSXPCConnection(serviceName: serviceName)
        connection?.remoteObjectInterface = NSXPCInterface(with: PerAppVolumeHelperProtocol.self)
        
        // Register custom classes used in the protocol
        let classes = [NSArray.self, AudibleApplication.self, NSData.self, NSDictionary.self, NSString.self, NSValue.self] as Set<AnyHashable>
        connection?.remoteObjectInterface?.setClasses(classes, for: #selector(PerAppVolumeHelperProtocol.getAudibleApplications(completion:)), argumentIndex: 0, ofReply: true)
        connection?.remoteObjectInterface?.setClasses(classes, for: #selector(PerAppVolumeHelperProtocol.requestAudioBuffer(forPID:completion:)), argumentIndex: 0, ofReply: true) // For Data
        connection?.remoteObjectInterface?.setClasses(classes, for: #selector(PerAppVolumeHelperProtocol.requestAudioBuffer(forPID:completion:)), argumentIndex: 1, ofReply: true) // For ASBD (might be passed as Data or Dictionary)


        connection?.interruptionHandler = { [weak self] in
            NSLog("XPC connection interrupted.")
            self?.connection = nil // Or attempt to reconnect
            self?.onConnectionInterrupted?()
        }
        
        connection?.invalidationHandler = { [weak self] in
            NSLog("XPC connection invalidated.")
            self?.connection = nil // Or attempt to reconnect
            self?.onConnectionInvalidated?()
        }
        
        connection?.resume()
        NSLog("XPC connection initiated to \(serviceName).")
    }

    private func getRemoteObjectProxy(errorHandler: @escaping (Error) -> Void) -> PerAppVolumeHelperProtocol? {
        setupConnection() // Ensure connection is active
        
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
            NSLog("XPC remote object error: \(error.localizedDescription)")
            errorHandler(error)
        }) as? PerAppVolumeHelperProtocol else {
            NSLog("Failed to get XPC remote object proxy.")
            errorHandler(HelperError.connectionInvalid) // Define this error type
            return nil
        }
        return proxy
    }

    // MARK: - Public API to interact with Helper

    func getAudibleApplications(completion: @escaping ([AudibleApplication]?, Error?) -> Void) {
        guard let proxy = getRemoteObjectProxy(errorHandler: completion) else {
            completion(nil, HelperError.connectionInvalid)
            return
        }
        proxy.getAudibleApplications(completion: completion)
    }

    func createTap(forPID pid: pid_t, appName: String, appBundleID: String, completion: @escaping (Error?) -> Void) {
        guard let proxy = getRemoteObjectProxy(errorHandler: completion) else {
            completion(HelperError.connectionInvalid)
            return
        }
        proxy.createTap(forPID: pid, appName: appName, appBundleID: appBundleID, completion: completion)
    }

    func destroyTap(forPID pid: pid_t, completion: @escaping (Error?) -> Void) {
        guard let proxy = getRemoteObjectProxy(errorHandler: completion) else {
            completion(HelperError.connectionInvalid)
            return
        }
        proxy.destroyTap(forPID: pid, completion: completion)
    }
    
    func requestAudioBuffer(forPID pid: pid_t, completion: @escaping (Data?, AudioStreamBasicDescription?, Error?) -> Void) {
        guard let proxy = getRemoteObjectProxy(errorHandler: { error in completion(nil, nil, error) }) else {
            completion(nil, nil, HelperError.connectionInvalid)
            return
        }
        proxy.requestAudioBuffer(forPID: pid, completion: completion)
    }

    func setVolume(forPID pid: pid_t, volume: Float, completion: @escaping (Error?) -> Void) {
        guard let proxy = getRemoteObjectProxy(errorHandler: completion) else {
            completion(HelperError.connectionInvalid)
            return
        }
        proxy.setVolume(forPID: pid, volume: volume, completion: completion)
    }

    func setMute(forPID pid: pid_t, isMuted: Bool, completion: @escaping (Error?) -> Void) {
        guard let proxy = getRemoteObjectProxy(errorHandler: completion) else {
            completion(HelperError.connectionInvalid)
            return
        }
        proxy.setMute(forPID: pid, isMuted: isMuted, completion: completion)
    }
    
    // MARK: - Helper Installation & Management (Simplified)
    // A full implementation requires SMJobBless.
    func installHelperIfNeeded(completion: @escaping (Bool, Error?) -> Void) {
        // 1. Check if helper is already installed and its version.
        //    This involves checking the version of the executable at the privileged location.
        // 2. If not installed or outdated, use SMJobBless to install/update.
        // This is a complex process and typically involves an AuthorizationExecuteWithPrivileges call
        // (deprecated) or SMJobBless. For SMJobBless, the helper must be signed, and
        // Info.plists for both app and helper must be configured correctly.

        NSLog("Helper installation check (SMJobBless) is a complex step not fully implemented here.")
        NSLog("Ensure the helper \(serviceName) is properly installed and signed.")
        // For now, assume helper is installed.
        completion(true, nil)
    }

    func setConnectionHandlers(interrupted: (() -> Void)?, invalidated: (() -> Void)?) {
        self.onConnectionInterrupted = interrupted
        self.onConnectionInvalidated = invalidated
    }
    
    deinit {
        connection?.invalidate()
    }
}
