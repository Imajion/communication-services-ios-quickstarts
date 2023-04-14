import Foundation
import CallKit
import AzureCommunicationCommon
import AzureCommunicationCalling
import AVFAudio

enum CallKitErrors: String, Error {
    case invalidParticipants = "Invalid participants provided"
    case unknownOutgoingCallType = "Unknown outgoing call type"
    case noIncomingCallFound = "No incoming call found to accept"
    case noActiveCallToEnd = "No active call found to end"
    case noCallAgent = "No CallAgent created"
}

struct ActiveCallInfo {
    var completionHandler: (Error?) -> Void
}

struct OutInCallInfo {
    var participants: [CommunicationIdentifier]?
    var meetingLocator: JoinMeetingLocator?
    var options: Any?
    var completionHandler: (Call?, Error?) -> Void
}

// We cannot create recreate CXProvider everytime
// For e.g. if one CXProvider reports incoming call and another
// CXProvider instance accepts the call, the operation fails.
// So we need to ensure we have Singleton CXProvider instance
final class CallKitObjectManager {
    private static var callKitHelper: CallKitHelper?
    private static var cxProvider: CXProvider?
    private static var cxProviderImpl: CxProviderDelegateImpl?

    static func createCXProvideConfiguration() -> CXProviderConfiguration {
        let providerConfig = CXProviderConfiguration()
        providerConfig.supportsVideo = true
        providerConfig.maximumCallsPerCallGroup = 1
        providerConfig.includesCallsInRecents = true
        providerConfig.supportedHandleTypes = [.phoneNumber, .generic]
        return providerConfig
    }

    static func getOrCreateCXProvider() -> CXProvider {
        if cxProvider == nil {
            cxProvider = CXProvider(configuration: createCXProvideConfiguration())
            cxProviderImpl = CxProviderDelegateImpl(with: getOrCreateCallKitHelper())
            cxProvider!.setDelegate(self.cxProviderImpl, queue: nil)
        }

        return cxProvider!
    }

    static func getCXProviderImpl() -> CxProviderDelegateImpl {
        return cxProviderImpl!
    }

    static func getOrCreateCallKitHelper() -> CallKitHelper {
        if callKitHelper == nil {
            callKitHelper = CallKitHelper()
        }
        return callKitHelper!
    }
}

final class CxProviderDelegateImpl : NSObject, CXProviderDelegate {
    private var callKitHelper: CallKitHelper
    private var callAgent: CallAgent?
    
    init(with callKitHelper: CallKitHelper) {
        self.callKitHelper = callKitHelper
    }

    func setCallAgent(callAgent: CallAgent) {
        self.callAgent = callAgent
    }

    private func configureAudioSession() -> Error? {
        let audioSession: AVAudioSession = AVAudioSession.sharedInstance()

        var configError: Error?
        do {
            try audioSession.setCategory(.playAndRecord)
        } catch {
            configError = error
        }

        return configError
    }

    private func stopAudio(call: Call) async throws {
        try await call.mute()
        try await call.speaker(mute: true)
    }
    
    private func startAudio(call: Call) async throws {
        try await call.unmute()
        try await call.speaker(mute: false)
    }

    func providerDidReset(_ provider: CXProvider) {
        // No-op
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Task {
            guard let activeCall = await self.callKitHelper.getActiveCall(callId: action.callUUID.uuidString) else {
                action.fail()
                return
            }
            
            do {
                if action.isOnHold {
                    try await stopAudio(call: activeCall)
                    try await activeCall.hold()
                } else {
                    // Dont resume the audio here, have to to wait for `didActivateAudioSession`
                    try await activeCall.resume()
                }
                action.fulfill()
            } catch {
                action.fail()
            }
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task {
            guard let activeCall = await self.callKitHelper.getActiveCall(callId: action.callUUID.uuidString) else {
                action.fail()
                return
            }

            do {
                if action.isMuted {
                    try await activeCall.mute()
                } else {
                    try await activeCall.unmute()
                }
                action.fulfill()
            } catch {
                action.fail()
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task {
            // this can be nil and its ok because this can also directly come from CallKit
            let outInCallInfo = await callKitHelper.getOutInCallInfo(transactionId: action.uuid)

            let completionBlock : ((Call?, Error?) -> Void) = { (call, error) in

                if error == nil {
                    action.fulfill()
                    Task {
                        await self.callKitHelper.addActiveCall(callId: action.callUUID.uuidString,
                                                               call: call!)
                    }
                } else {
                    action.fail()
                }

                outInCallInfo?.completionHandler(call, error)
                Task {
                    await self.callKitHelper.removeOutInCallInfo(transactionId: action.uuid)
                    await self.callKitHelper.removeIncomingCall(callId: action.callUUID.uuidString)
                }
            }

            if let error = configureAudioSession() {
                completionBlock(nil, error)
                return
            }

            let acceptCallOptions = outInCallInfo?.options as? AcceptCallOptions

            if let incomingCall = await callKitHelper.getIncomingCall(callId: action.callUUID) {
                incomingCall.accept(options: acceptCallOptions ?? AcceptCallOptions(), completionHandler: completionBlock)
                return
            }
            
            let dispatchSemaphore = await self.callKitHelper.setAndGetSemaphore()
            DispatchQueue.global().async {
                _ = dispatchSemaphore.wait(timeout: DispatchTime(uptimeNanoseconds: 10 * NSEC_PER_SEC))
                Task {
                    if let incomingCall = await self.callKitHelper.getIncomingCall(callId: action.callUUID) {
                        incomingCall.accept(options: acceptCallOptions ?? AcceptCallOptions(), completionHandler: completionBlock)
                    } else {
                        completionBlock(nil, CallKitErrors.noIncomingCallFound)
                    }
                }
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task {
            guard let activeCall = await self.callKitHelper.getActiveCall(callId: action.callUUID.uuidString) else {
                action.fail()
                return
            }

            let activeCallInfo = await self.callKitHelper.getActiveCallInfo(transactionId: action.uuid.uuidString)
            activeCall.hangUp(options: nil) { error in
                // Its ok if hangup fails because we maybe hanging up already hanged up call
                action.fulfill()
                activeCallInfo?.completionHandler(error)
                Task {
                    await self.callKitHelper.removeActiveCall(callId: activeCall.id)
                    await self.callKitHelper.removeActiveCallInfo(transactionId: action.uuid.uuidString)
                }
            }
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task {
            guard let activeCall = await self.callKitHelper.getActiveCall() else {
                print("No active calls found !!")
                return
            }

            try await startAudio(call: activeCall)
        }
    }
    var currentcall: Call?

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task {
            // This will be raised by CallKit always after raising a transaction
            // Which means an API call will have to happen to reach here
            guard let outInCallInfo = await callKitHelper.getOutInCallInfo(transactionId: action.uuid) else {
                return
            }
            
            let completionBlock : ((Call?, Error?) -> Void) = { (call, error) in
                self.currentcall = call
                if error == nil {
                    action.fulfill()
                    Task {
                        await self.callKitHelper.addActiveCall(callId: action.callUUID.uuidString,
                                                               call: call!)
                        self.toggleSendingRawOutgoingVideo()

                    }
                } else {
                    action.fail()
                }
                outInCallInfo.completionHandler(call, error)
                Task {
                    await self.callKitHelper.removeOutInCallInfo(transactionId: action.uuid)
                }
            }

            guard let callAgent = self.callAgent else {
                completionBlock(nil, CallKitErrors.noCallAgent)
                return
            }

            if let error = configureAudioSession() {
                completionBlock(nil, error)
                return
            }

            // Start by muting both speaker and mic audio and unmute when
            // didActivateAudioSession callback is recieved.
            let mutedAudioOptions = AudioOptions()
            mutedAudioOptions.speakerMuted = true
            mutedAudioOptions.muted = true
            
            let copyJoinCallOptions = JoinCallOptions()
            copyJoinCallOptions.videoOptions = VideoOptions(outgoingVideoStreams: [])
            
            
            copyJoinCallOptions.audioOptions = mutedAudioOptions
            guard let uuid = UUID(uuidString: "89c04b6f-9fcd-4e6d-bc23-c8f8d8be7b6e") else {
                fatalError("Invalid UUID")
            }
            await UIDevice.current.beginGeneratingDeviceOrientationNotifications();

            callAgent.join(with: GroupCallLocator(groupId: uuid),
                           joinCallOptions: copyJoinCallOptions,
                           completionHandler: completionBlock)
                        
        }
    }
    var outgoingVideoSender:  RawOutgoingVideoSender?
    var sendingRawVideo: Bool = false

    func toggleSendingRawOutgoingVideo() {
        guard let call = currentcall else {
            return
        }
        if sendingRawVideo {
            outgoingVideoSender?.stopSending()
            outgoingVideoSender = nil
        } else {
            let producer = GrayLinesFrameProducer()
            outgoingVideoSender = RawOutgoingVideoSender(frameProducer: producer)
            outgoingVideoSender?.startSending(to: call)
        }
        sendingRawVideo.toggle()
    }
}

class CallKitIncomingCallReporter {
    
    private func createCallUpdate(isVideoEnabled: Bool, localizedCallerName: String, handle: CXHandle) -> CXCallUpdate {
        let callUpdate = CXCallUpdate()
        callUpdate.hasVideo = isVideoEnabled
        callUpdate.supportsHolding = true
        callUpdate.supportsDTMF = true
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.localizedCallerName = localizedCallerName
        callUpdate.remoteHandle = handle
        return callUpdate
    }

    func reportIncomingCall(callId: String,
                            callerInfo: CallerInfo,
                            videoEnabled: Bool,
                            completionHandler: @escaping (Error?) -> Void)
    {
        reportIncomingCall(callId: callId,
                           caller: callerInfo.identifier,
                           callerDisplayName: callerInfo.displayName,
                           videoEnabled: videoEnabled, completionHandler: completionHandler)
    }

    func reportIncomingCall(callId: String,
                            caller:CommunicationIdentifier,
                            callerDisplayName: String,
                            videoEnabled: Bool,
                            completionHandler: @escaping (Error?) -> Void) {
        let handleType: CXHandle.HandleType = caller is PhoneNumberIdentifier ? .phoneNumber : .generic
        let handle = CXHandle(type: handleType, value: caller.rawId)
        let callUpdate = createCallUpdate(isVideoEnabled: videoEnabled, localizedCallerName: callerDisplayName, handle: handle)
        CallKitObjectManager.getOrCreateCXProvider().reportNewIncomingCall(with: UUID(uuidString: callId.uppercased())!, update: callUpdate) { error in
            completionHandler(error)
        }
    }
}

actor CallKitHelper {
    private var callController = CXCallController()
    private var outInCallInfoMap: [String: OutInCallInfo] = [:]
    private var incomingCallMap: [String: IncomingCall] = [:]
    private var incomingCallSemaphore: DispatchSemaphore?
    private var activeCalls: [String : Call] = [:]
    private var updatedCallIdMap: [String:String] = [:]
    private var activeCallInfos: [String: ActiveCallInfo] = [:]

    func getActiveCallInfo(transactionId: String) -> ActiveCallInfo? {
        return activeCallInfos[transactionId.uppercased()]
    }

    func removeActiveCallInfo(transactionId: String) {
        activeCallInfos.removeValue(forKey: transactionId.uppercased())
    }

    private func onIdChanged(newId: String, oldId: String) {
        // For outgoing call we need to report an initial callId to CallKit
        // But that callId wont match with what is set in SDK.
        // So we need to maintain this map between which callId was reported to CallKit
        // and what is new callId in the SDK.
        // For incoming call this wont happen because in the push notification
        // we already get the id of the call.
        if newId != oldId {
            updatedCallIdMap[newId.uppercased()] = oldId.uppercased()
        }
    }

    func setAndGetSemaphore() -> DispatchSemaphore {
        self.incomingCallSemaphore = DispatchSemaphore(value: 0)
        return self.incomingCallSemaphore!
    }
    
    func setIncomingCallSemaphore(semaphore: DispatchSemaphore) {
        self.incomingCallSemaphore = semaphore
    }

    func addIncomingCall(incomingCall: IncomingCall) {
        incomingCallMap[incomingCall.id.uppercased()] = incomingCall
        self.incomingCallSemaphore?.signal()
    }
    
    func removeIncomingCall(callId: String) {
        incomingCallMap.removeValue(forKey: callId.uppercased())
        self.incomingCallSemaphore?.signal()
    }
    
    func getIncomingCall(callId: UUID) -> IncomingCall? {
        return incomingCallMap[callId.uuidString.uppercased()]
    }

    func addActiveCall(callId: String, call: Call) {
        onIdChanged(newId: call.id, oldId: callId)
        activeCalls[callId.uppercased()] = call
    }

    func removeActiveCall(callId: String) {
        let finalCallId = getReportedCallIdToCallKit(callId: callId)
        activeCalls.removeValue(forKey: finalCallId)
    }

    func getActiveCall(callId: String) -> Call? {
        let finalCallId = getReportedCallIdToCallKit(callId: callId)
        return activeCalls[finalCallId]
    }

    func getActiveCall() -> Call? {
        // We only allow one active call at a time
        return activeCalls.first?.value
    }

    func removeOutInCallInfo(transactionId: UUID) {
        outInCallInfoMap.removeValue(forKey: transactionId.uuidString.uppercased())
    }

    func getOutInCallInfo(transactionId: UUID) -> OutInCallInfo? {
        return outInCallInfoMap[transactionId.uuidString.uppercased()]
    }

    private func isVideoOn(options: Any?) -> Bool
    {
        guard let optionsUnwrapped = options else {
            return false
        }
        
        var videoOptions: VideoOptions?
        if let joinOptions = optionsUnwrapped as? JoinCallOptions {
            videoOptions = joinOptions.videoOptions
        } else if let acceptOptions = optionsUnwrapped as? AcceptCallOptions {
            videoOptions = acceptOptions.videoOptions
        } else if let startOptions = optionsUnwrapped as? StartCallOptions {
            videoOptions = startOptions.videoOptions
        }
        
        guard let videoOptionsUnwrapped = videoOptions else {
            return false
        }
        
        return videoOptionsUnwrapped.localVideoStreams.count > 0
    }

    private func transactOutInCallWithCallKit(action: CXAction, outInCallInfo: OutInCallInfo) {
        callController.requestTransaction(with: action) { [self] error in
            if error != nil {
                outInCallInfo.completionHandler(nil, error)
            } else {
                outInCallInfoMap[action.uuid.uuidString.uppercased()] = outInCallInfo
            }
        }
    }
    
    private func transactWithCallKit(action: CXAction, activeCallInfo: ActiveCallInfo) {
        callController.requestTransaction(with: action) { error in
            if error != nil {
                activeCallInfo.completionHandler(error)
            } else {
                self.activeCallInfos[action.uuid.uuidString.uppercased()] = activeCallInfo
            }
        }
    }

    private func getReportedCallIdToCallKit(callId: String) -> String {
        var finalCallId : String
        if let newCallId = self.updatedCallIdMap[callId.uppercased()] {
            finalCallId = newCallId
        } else {
            finalCallId = callId.uppercased()
        }
        
        return finalCallId
    }

    func acceptCall(callId: String,
                    options: AcceptCallOptions?,
                    completionHandler: @escaping (Call?, Error?) -> Void) {
        let callId = UUID(uuidString: callId.uppercased())!
        let answerCallAction = CXAnswerCallAction(call: callId)
        let outInCallInfo = OutInCallInfo(participants: nil,
                                          options: options,
                                          completionHandler: completionHandler)
        transactOutInCallWithCallKit(action: answerCallAction, outInCallInfo: outInCallInfo)
    }

    func reportOutgoingCall(call: Call) {
        if call.direction != .outgoing {
            return
        }

        let finalCallId = getReportedCallIdToCallKit(callId: call.id)
        print("Report outgoing call for: \(finalCallId)")
        if call.state == .connected {
            CallKitObjectManager.getOrCreateCXProvider().reportOutgoingCall(with: UUID(uuidString: finalCallId)! , connectedAt: nil)
        } else if call.state != .connecting {
            CallKitObjectManager.getOrCreateCXProvider().reportOutgoingCall(with: UUID(uuidString: finalCallId)! , startedConnectingAt: nil)
        }
    }

    func endCall(callId: String, completionHandler: @escaping (Error?) -> Void) {
        let finalCallId = getReportedCallIdToCallKit(callId: callId)
        let endCallAction = CXEndCallAction(call: UUID(uuidString: finalCallId)!)
        transactWithCallKit(action: endCallAction, activeCallInfo: ActiveCallInfo(completionHandler: completionHandler))
    }

    func placeCall(participants: [CommunicationIdentifier]?,
                   callerDisplayName: String,
                   meetingLocator: JoinMeetingLocator?,
                   options: Any?,
                   completionHandler: @escaping (Call?, Error?) -> Void)
    {
        let callId = UUID()
        
        var compressedParticipant: String = ""
        var handleType: CXHandle.HandleType = .generic

        if let participants = participants {
            if participants.count == 1 {
                if participants.first is PhoneNumberIdentifier {
                    handleType = .phoneNumber
                }
                compressedParticipant = participants.first!.rawId
            } else {
                for participant in participants {
                    handleType = participant is PhoneNumberIdentifier ? .phoneNumber : .generic
                    compressedParticipant.append(participant.rawId + ";")
                }
            }
        } else if let meetingLoc = meetingLocator as? GroupCallLocator {
            compressedParticipant = meetingLoc.groupId.uuidString
        }

        #if BETA
        if let meetingLoc = meetingLocator as? TeamsMeetingLinkLocator {
            compressedParticipant = meetingLoc.meetingLink
        } else if let meetingLoc = meetingLocator as? TeamsMeetingCoordinatesLocator {
            compressedParticipant = meetingLoc.threadId
        }
        #endif
        
        guard !compressedParticipant.isEmpty else {
            completionHandler(nil, CallKitErrors.invalidParticipants)
            return
        }

        let handle = CXHandle(type: handleType, value: compressedParticipant)
        let startCallAction = CXStartCallAction(call: callId, handle: handle)
        startCallAction.isVideo = isVideoOn(options: options)
        startCallAction.contactIdentifier = callerDisplayName
        
        transactOutInCallWithCallKit(action: startCallAction,
                                     outInCallInfo: OutInCallInfo(participants: participants,
                                                                  meetingLocator: meetingLocator,
                                                                  options: options, completionHandler: completionHandler))
    }
    
}





//************** Raw media capabilities ************************//
protocol FrameProducerProtocol {
    func nextFrame(for format: VideoFormat) -> CVImageBuffer
}

// Produces random gray stripes.
final class GrayLinesFrameProducer: FrameProducerProtocol {
    var buffer: CVPixelBuffer? = nil
    private var currentFormat: VideoFormat?

    func nextFrame(for format: VideoFormat) -> CVImageBuffer {
        let bandsCount = Int.random(in: 10..<25)
        let bandThickness = Int(format.height * format.width) / bandsCount

        let currentFormat = self.currentFormat ?? format
        let bufferSizeChanged = currentFormat.width != format.width ||
                             currentFormat.height != format.height ||
                             currentFormat.stride1 != format.stride1

        let newBuffer = buffer == nil || bufferSizeChanged
        if newBuffer {
            // Make ARC release previous reusable buffer
            self.buffer = nil
            let attrs = [
                kCVPixelBufferBytesPerRowAlignmentKey: Int(format.stride1)
            ] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, Int(format.width), Int(format.height),
                                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &buffer) == kCVReturnSuccess else {
                fatalError()
            }
        }

        self.currentFormat = format
        guard let frameBuffer = buffer else {
            fatalError()
        }

        CVPixelBufferLockBaseAddress(frameBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(frameBuffer, .readOnly)
        }

        // Fill NV12 Y plane with different luminance for each band.
        var begin = 0
        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(frameBuffer, 0) else {
            fatalError()
        }
        for _ in 0..<bandsCount {
            let luminance = Int32.random(in: 100..<255)
            memset(yPlane + begin, luminance, bandThickness)
            begin += bandThickness
        }

        if newBuffer {
            guard let uvPlane = CVPixelBufferGetBaseAddressOfPlane(frameBuffer, 1) else {
                fatalError()
            }
            memset(uvPlane, 128, Int((format.height * format.width) / 2))
        }

        return frameBuffer
    }
}

final class RawOutgoingVideoSender: NSObject {
    var frameSender: VideoFrameSender?
    let frameProducer: FrameProducerProtocol
    var rawOutgoingStream: RawOutgoingVideoStream!

    private var lock: NSRecursiveLock = NSRecursiveLock()

    private var timer: Timer?
    private var syncSema: DispatchSemaphore?
    private(set) weak var call: Call?
    private var running: Bool = false
    private let frameQueue: DispatchQueue = DispatchQueue(label: "org.microsoft.frame-sender")

    private var options: RawOutgoingVideoStreamOptions!
    private var outgoingVideoStreamState: OutgoingVideoStreamState = .none
    let videoFormats: [VideoFormat] = []

    



    init(frameProducer: FrameProducerProtocol) {
        let videoFormat = VideoFormat()
        videoFormat.width = 1280;
        videoFormat.height = 720;
        videoFormat.pixelFormat = .nv12;
        videoFormat.videoFrameKind = .videoSoftware;
        videoFormat.framesPerSecond = 30;
        videoFormat.stride1 = 1280;
        videoFormat.stride2 = 1280;
        
        self.frameProducer = frameProducer
        super.init()
        options = RawOutgoingVideoStreamOptions()
        options.delegate = self
        options.videoFormats = [videoFormat] // Video format we specified on step 1.
        self.rawOutgoingStream = VirtualRawOutgoingVideoStream(videoStreamOptions: options)
        
        
        

        let virtualRawOutgoingVideoStream = VirtualRawOutgoingVideoStream(videoStreamOptions: options)
        
    }

    

    func startSending(to call: Call) {
        self.call = call
        self.startRunning()
        self.call?.startVideo(stream: rawOutgoingStream) { error in
            // Stream sending started.
        }
    }

    func stopSending() {
        self.stopRunning()
        call?.stopVideo(stream: rawOutgoingStream) { error in
            // Stream sending stopped.
        }
    }

    private func startRunning() {
        lock.lock(); defer { lock.unlock() }

        self.running = true
        if frameSender != nil {
            self.startFrameGenerator()
        }
    }

    private func startFrameGenerator() {
        guard let sender = self.frameSender else {
            return
        }

        // How many times per second, based on sender format FPS.
        let interval = TimeInterval((1 as Float) / sender.videoFormat.framesPerSecond)
        frameQueue.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self = self, let sender = self.frameSender else {
                    return
                }

                let planeData = self.frameProducer.nextFrame(for: sender.videoFormat)
                self.sendSync(with: sender, frame: planeData)
            }
            RunLoop.current.run()
            self?.timer?.fire()
        }
    }

    private func sendSync(with sender: VideoFrameSender, frame: CVImageBuffer) {
        guard let softwareSender = sender as? SoftwareBasedVideoFrameSender else {
           return
        }
        // Ensure that a frame will not be sent before another finishes.
        syncSema = DispatchSemaphore(value: 0)
        softwareSender.send(frame: frame, timestampInTicks: sender.timestampInTicks) { [weak self] confirmation, error in
            self?.syncSema?.signal()
            guard let self = self else { return }
            if let confirmation = confirmation {
                // Can check if confirmation was successful using `confirmation.status`
            } else if let error = error {
                // Can check details about error in case of failure.
            }
        }
        syncSema?.wait()
    }

    private func stopRunning() {
        lock.lock(); defer { lock.unlock() }

        running = false
        stopFrameGeneration()
    }

    private func stopFrameGeneration() {
        lock.lock(); defer { lock.unlock() }
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
        timer = nil
    }
}

extension RawOutgoingVideoSender: RawOutgoingVideoStreamOptionsDelegate {
    func rawOutgoingVideoStreamOptions(_ rawOutgoingVideoStreamOptions: RawOutgoingVideoStreamOptions,
                                       didChangeOutgoingVideoStreamState args: OutgoingVideoStreamStateChangedEventArgs) {
        outgoingVideoStreamState = args.outgoingVideoStreamState
    }

    func rawOutgoingVideoStreamOptions(_ rawOutgoingVideoStreamOptions: RawOutgoingVideoStreamOptions,
                                       didChangeVideoFrameSender args: VideoFrameSenderChangedEventArgs) {
        // Sender can change to start sending a more efficient format (given network conditions) of the ones specified
        // in the list on the initial step. In that case, you should restart the sender.
        if running {
            stopRunning()
            self.frameSender = args.videoFrameSender
            startRunning()
        } else {
            self.frameSender = args.videoFrameSender
        }
    }
}
