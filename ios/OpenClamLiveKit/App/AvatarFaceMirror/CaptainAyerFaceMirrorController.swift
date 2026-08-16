import ARKit
import AVFoundation
import Combine
import Foundation
import UIKit
import simd

enum CaptainAyerFaceMirrorPhase: Equatable, Sendable {
    case off
    case requestingPermission
    case running
}

struct CaptainAyerFaceMirrorIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case unsupported
        case permissionDenied
        case permissionRestricted
        case captureFailed
        case interrupted
    }

    let kind: Kind
    let title: String
    let message: String

    var id: Kind { kind }
}

/// An explicit, foreground-only TrueDepth session. It publishes numerical
/// blendshapes and pose only; captured camera pixels are neither retained nor
/// exposed to the rest of OpenClam.
@MainActor
final class CaptainAyerFaceMirrorController: ObservableObject {
    @Published private(set) var phase: CaptainAyerFaceMirrorPhase = .off
    @Published private(set) var expression = CaptainAyerFaceMirrorExpression.idle
    @Published private(set) var isTrackingFace = false
    @Published private(set) var issue: CaptainAyerFaceMirrorIssue?

    private let driver = CaptainAyerFaceMirrorSessionDriver()
    private var session: ARSession?
    private var permissionTask: Task<Void, Never>?
    private var lifecycleObserver: NSObjectProtocol?
    private var smoother = CaptainAyerFaceMirrorSmoother()
    private var generation = 0

    var isEnabled: Bool { phase != .off }
    var isCapturing: Bool { phase == .running }

    var statusText: String {
        switch phase {
        case .off:
            "Off"
        case .requestingPermission:
            "Waiting for camera permission"
        case .running:
            isTrackingFace ? "Following your face" : "Looking for your face"
        }
    }

    init() {
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopForBackground()
            }
        }
    }

    deinit {
        permissionTask?.cancel()
        session?.pause()
        if let lifecycleObserver {
            NotificationCenter.default.removeObserver(lifecycleObserver)
        }
    }

    func start() {
        guard phase == .off else { return }
        issue = nil

        guard ARFaceTrackingConfiguration.isSupported else {
            issue = CaptainAyerFaceMirrorIssue(
                kind: .unsupported,
                title: "Face mirroring isn’t available",
                message: "Captain Ayer face mirroring needs a device with a TrueDepth front camera."
            )
            return
        }

        generation += 1
        let requestGeneration = generation
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession(generation: requestGeneration)
        case .notDetermined:
            phase = .requestingPermission
            permissionTask?.cancel()
            permissionTask = Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard !Task.isCancelled,
                      let self,
                      self.generation == requestGeneration else { return }
                self.permissionTask = nil
                if granted {
                    self.startSession(generation: requestGeneration)
                } else {
                    self.failWithPermissionDenied()
                }
            }
        case .denied:
            failWithPermissionDenied()
        case .restricted:
            issue = CaptainAyerFaceMirrorIssue(
                kind: .permissionRestricted,
                title: "Camera access is restricted",
                message: "This device’s camera restrictions prevent local face mirroring."
            )
        @unknown default:
            failWithPermissionDenied()
        }
    }

    func stop() {
        stopCapture(clearsIssue: true)
    }

    func dismissIssue() {
        issue = nil
    }

    private func startSession(generation requestGeneration: Int) {
        guard generation == requestGeneration, phase != .running else { return }

        smoother.reset()
        expression = .idle
        isTrackingFace = false
        driver.reset()
        driver.onSample = { [weak self] sample in
            self?.receive(sample)
        }
        driver.onTrackingLost = { [weak self] in
            self?.loseTrackedFace()
        }
        driver.onFailure = { [weak self] message in
            self?.captureFailed(message)
        }
        driver.onInterruption = { [weak self] in
            self?.captureInterrupted()
        }

        let liveSession = ARSession()
        liveSession.delegate = driver
        liveSession.delegateQueue = .main
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        liveSession.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
        session = liveSession
        phase = .running
    }

    private func receive(_ sample: CaptainAyerFaceMirrorRawSample) {
        guard phase == .running else { return }
        expression = smoother.update(with: sample)
        if !isTrackingFace { isTrackingFace = true }
    }

    private func loseTrackedFace() {
        guard phase == .running, isTrackingFace else { return }
        smoother.reset()
        expression = .idle
        isTrackingFace = false
    }

    private func stopForBackground() {
        stopCapture(clearsIssue: true)
    }

    private func stopCapture(clearsIssue: Bool) {
        generation += 1
        permissionTask?.cancel()
        permissionTask = nil
        session?.pause()
        session?.delegate = nil
        session = nil
        driver.clearCallbacks()
        smoother.reset()
        expression = .idle
        isTrackingFace = false
        phase = .off
        if clearsIssue { issue = nil }
    }

    private func failWithPermissionDenied() {
        stopCapture(clearsIssue: false)
        issue = CaptainAyerFaceMirrorIssue(
            kind: .permissionDenied,
            title: "Camera permission is off",
            message: "Allow OpenClam camera access in Settings, then tap the face button again. Face data stays on this device."
        )
    }

    private func captureFailed(_ message: String) {
        guard phase == .running else { return }
        stopCapture(clearsIssue: false)
        issue = CaptainAyerFaceMirrorIssue(
            kind: .captureFailed,
            title: "Face mirroring stopped",
            message: message
        )
    }

    private func captureInterrupted() {
        guard phase == .running else { return }
        stopCapture(clearsIssue: false)
        issue = CaptainAyerFaceMirrorIssue(
            kind: .interrupted,
            title: "Face mirroring paused",
            message: "Another camera activity interrupted mirroring. Tap the face button when you’re ready to start again."
        )
    }
}

private final class CaptainAyerFaceMirrorSessionDriver: NSObject, ARSessionDelegate {
    @MainActor var onSample: ((CaptainAyerFaceMirrorRawSample) -> Void)?
    @MainActor var onTrackingLost: (() -> Void)?
    @MainActor var onFailure: ((String) -> Void)?
    @MainActor var onInterruption: (() -> Void)?

    private var lastPush = -TimeInterval.infinity

    func reset() {
        lastPush = -TimeInterval.infinity
    }

    @MainActor
    func clearCallbacks() {
        onSample = nil
        onTrackingLost = nil
        onFailure = nil
        onInterruption = nil
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).last,
              face.isTracked else {
            MainActor.assumeIsolated { onTrackingLost?() }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPush >= 1.0 / 30.0 else { return }
        lastPush = now
        let sample = Self.sample(from: face)
        MainActor.assumeIsolated { onSample?(sample) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription.isEmpty
            ? "The front camera could not continue face tracking."
            : error.localizedDescription
        MainActor.assumeIsolated { onFailure?(message) }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { onInterruption?() }
    }

    private static func sample(
        from face: ARFaceAnchor
    ) -> CaptainAyerFaceMirrorRawSample {
        let shapes = face.blendShapes
        func read(_ key: ARFaceAnchor.BlendShapeLocation) -> Double {
            Double(truncating: shapes[key] ?? 0)
        }

        let lookAt = face.lookAtPoint
        let depth = max(0.12, abs(Double(lookAt.z)))
        let gaze = CGPoint(
            x: Double(lookAt.x) / depth * 4.0,
            y: -Double(lookAt.y) / depth * 4.0
        )
        let rotation = Self.eulerAngles(from: face.transform)

        return CaptainAyerFaceMirrorRawSample(
            jawOpen: read(.jawOpen),
            mouthPucker: read(.mouthPucker),
            mouthFunnel: read(.mouthFunnel),
            smileLeft: read(.mouthSmileLeft),
            smileRight: read(.mouthSmileRight),
            blinkLeft: read(.eyeBlinkLeft),
            blinkRight: read(.eyeBlinkRight),
            browInnerUp: read(.browInnerUp),
            browOuterUpLeft: read(.browOuterUpLeft),
            browOuterUpRight: read(.browOuterUpRight),
            eyeGaze: gaze,
            headYaw: rotation.yaw,
            headPitch: rotation.pitch,
            headRoll: rotation.roll
        )
    }

    private static func eulerAngles(
        from transform: simd_float4x4
    ) -> (yaw: Double, pitch: Double, roll: Double) {
        let quaternion = simd_quatf(transform)
        let x = Double(quaternion.imag.x)
        let y = Double(quaternion.imag.y)
        let z = Double(quaternion.imag.z)
        let w = Double(quaternion.real)

        let pitch = atan2(
            2 * (w * x + y * z),
            1 - 2 * (x * x + y * y)
        )
        let yawValue = 2 * (w * y - z * x)
        let yaw = asin(min(1, max(-1, yawValue)))
        let roll = atan2(
            2 * (w * z + x * y),
            1 - 2 * (y * y + z * z)
        )
        return (yaw, pitch, roll)
    }
}
