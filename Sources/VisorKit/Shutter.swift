import Foundation

/// The glasses' camera, worked from the Mac as their capture button would. Port of Visor's `Shutter.kt`.
///
/// svc28 SNIntent (type 2300) {1 action, 2 extras}. A video starts on AGENTIC_START_RECORDING, the broadcast the
/// glasses' own assistant sends, and stops on CLOSE_APP_CAPTURE, their "stop recording". A photo goes through
/// action.robusta.capture with a launch type. Each answer is the camera state (DeviceState field 3) pushed on svc28.

/// What the glasses film when asked: the capture types their assistant's start_recording takes.
public enum VideoKind: String, Codable, CaseIterable {
    case video
    case hyperlapse
}

public struct ShutterError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

public enum Shutter {
    public static let snIntent = 2300
    /// How long to wait for the camera state, as `Shutter.kt` (5 s).
    public static let answerTimeout: TimeInterval = 5

    public static let photoStarted = "CAPTURE_PHOTO_STARTED"
    public static let videoStarted = "CAPTURE_VIDEO_STARTED"

    static let robustaCapture = "action.robusta.capture"
    static let agenticStartRecording = "com.meta.smartglass.app.intent.action.AGENTIC_START_RECORDING"
    static let closeAppCapture = "com.meta.smartglass.app.intent.action.CLOSE_APP_CAPTURE"
    static let launchType = "com.meta.smartglass.intent.action.LAUNCH_TYPE"
    static let referrer = "android.intent.extra.REFERRER_NAME"
    static let isModal = "IS_MODAL"
    static let captureType = "capture_type"

    /// SNIntent: field 1 the action, one field 2 per extra.
    public static func intent(_ action: String, _ extras: [[UInt8]] = []) -> [UInt8] {
        extras.reduce(Wire.fieldString(1, action)) { $0 + Wire.fieldBytes(2, $1) }
    }

    /// One SNIntentData with a string value: the key, then the value in field 5 (bytes).
    public static func text(_ key: String, _ value: String) -> [UInt8] {
        Wire.fieldString(1, key) + Wire.fieldString(5, value)
    }

    /// One SNIntentData with a boolean value: the key, then the value in field 2. False is written, as in Kotlin.
    public static func flag(_ key: String, _ value: Bool) -> [UInt8] {
        Wire.fieldString(1, key) + Wire.fieldVarint(2, value ? 1 : 0)
    }

    public static func photoIntent() -> [UInt8] {
        intent(robustaCapture, [
            text(launchType, "CAPTURE_EXTRA_LAUNCH_TYPE_PHOTO"),
            text(referrer, "SHORT_BUTTON"),
            flag(isModal, true),
        ])
    }

    public static func startVideoIntent(_ kind: VideoKind = .video) -> [UInt8] {
        intent(agenticStartRecording, [text(captureType, kind.rawValue)])
    }

    public static func stopVideoIntent() -> [UInt8] {
        intent(closeAppCapture)
    }
}

extension GlassesSession {
    /// Whether the last camera state seen on svc28 is a running video. Nil before any camera state arrived.
    public var isRecording: Bool? { statusHub.status.recording }

    /// Take a photo. Returns once svc28 pushes CAPTURE_PHOTO_STARTED; throws on no answer.
    public func takePhoto(timeout: TimeInterval = Shutter.answerTimeout) async throws {
        try await shutter("photo", Shutter.photoIntent(), timeout: timeout) { $0 == Shutter.photoStarted }
    }

    /// Start filming. Returns once svc28 pushes CAPTURE_VIDEO_STARTED; throws on no answer.
    public func startVideo(_ kind: VideoKind = .video, timeout: TimeInterval = Shutter.answerTimeout) async throws {
        try await shutter(kind.rawValue, Shutter.startVideoIntent(kind), timeout: timeout) { $0 == Shutter.videoStarted }
    }

    /// Stop the video. Returns at once when the known camera state is not a running video; otherwise once svc28
    /// pushes any other camera state. When no camera state is known yet, the stop is sent anyway.
    public func stopVideo(timeout: TimeInterval = Shutter.answerTimeout) async throws {
        await prepareShutter(timeout: timeout)
        if statusHub.status.recording == false { return }
        try await shutter("stop", Shutter.stopVideoIntent(), timeout: timeout) { $0 != Shutter.videoStarted }
    }

    /// Stop a running video, or start one. Returns whether a video is running afterwards.
    @discardableResult
    public func toggleVideo(_ kind: VideoKind = .video, timeout: TimeInterval = Shutter.answerTimeout) async throws -> Bool {
        await prepareShutter(timeout: timeout)
        if statusHub.status.recording == true {
            try await stopVideo(timeout: timeout)
            return false
        }
        try await startVideo(kind, timeout: timeout)
        return true
    }

    /// The camera answers come as svc28 pushes, which need the svc28 responder and a subscribe. The first time, read
    /// a snapshot so the camera state is known. A failure here is not fatal: the intent still goes out.
    private func prepareShutter(timeout: TimeInterval) async {
        let hub = installStatusResponder()
        if !hub.subscribed { _ = try? await readStatus(timeout: timeout, includeBuildInfo: false) }
    }

    /// Send one SNIntent and wait for a svc28 message whose camera field satisfies `done`. Registered before the send,
    /// so a quick answer is not missed.
    private func shutter(_ what: String, _ intent: [UInt8], timeout: TimeInterval, done: @escaping (String) -> Bool) async throws {
        await prepareShutter(timeout: timeout)
        let hub = installStatusResponder()
        let w = hub.expect { _, fields, _ in
            fields.has(3) && done(StatusEnums.name(StatusEnums.camera, fields.varint(3)))
        }
        do { try await send(service: ServiceIds.status, type: Shutter.snIntent, payload: intent) } catch { hub.cancel(w); throw error }
        guard try await hub.collect(w, timeout: timeout) != nil else {
            throw ShutterError("\(what): no answer from the glasses in \(Int(timeout)) s")
        }
    }
}
