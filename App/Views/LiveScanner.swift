@preconcurrency import AVFoundation
import SwiftUI
import Vision

/// Camera tuned for reading small print up close: near focus range, continuous autofocus,
/// tap to focus, a torch, and a shutter that waits until focus has settled.
final class CameraEngine: NSObject, @unchecked Sendable, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct State: Sendable {
        var focusing = true
        var textLines = 0
        var torchOn = false
    }

    let session = AVCaptureSession()
    var onState: (@Sendable (State) -> Void)?

    private let queue = DispatchQueue(label: "camera.engine")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var focusObservation: NSKeyValueObservation?
    private var state = State()
    private var lastTextCheck = Date.distantPast
    private var continuation: CheckedContinuation<UIImage, Error>?

    static var isAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
            && AVCaptureDevice.authorizationStatus(for: .video) != .denied
            && AVCaptureDevice.authorizationStatus(for: .video) != .restricted
    }

    func start() async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
        return await withCheckedContinuation { cont in
            queue.async {
                let ok = self.configure()
                if ok { self.session.startRunning() }
                cont.resume(returning: ok)
            }
        }
    }

    func stop() {
        queue.async {
            if let d = self.device, d.torchMode != .off { try? d.lockForConfiguration(); d.torchMode = .off; d.unlockForConfiguration() }
            self.session.stopRunning()
        }
    }

    private func configure() -> Bool {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back)
        guard let device = discovery.devices.first, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        self.device = device

        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        // The output must allow whatever a photo request asks for, or AVFoundation raises an exception.
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = largest
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.frames"))
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()

        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            // Labels are read from a few centimetres to arm's length, so don't hunt at far range.
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
            device.unlockForConfiguration()
        } catch { return false }

        focusObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] d, _ in
            guard let self else { return }
            self.state.focusing = d.isAdjustingFocus
            self.onState?(self.state)
        }
        return true
    }

    func focus(atDevicePoint p: CGPoint) {
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = p }
            if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
            if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = p }
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            d.unlockForConfiguration()
            // Return to continuous focus once the tap focus has been applied.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                guard (try? d.lockForConfiguration()) != nil else { return }
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                d.unlockForConfiguration()
            }
        }
    }

    func setTorch(_ on: Bool) {
        queue.async {
            guard let d = self.device, d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
            if on { try? d.setTorchModeOn(level: 1.0) } else { d.torchMode = .off }
            d.unlockForConfiguration()
            self.state.torchOn = on
            self.onState?(self.state)
        }
    }

    func capture() async throws -> UIImage {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.continuation == nil else { cont.resume(throwing: CocoaError(.userCancelled)); return }
                self.continuation = cont
                let settings = AVCapturePhotoSettings()
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                settings.photoQualityPrioritization = .quality
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        queue.async {
            let cont = self.continuation
            self.continuation = nil
            if let error { cont?.resume(throwing: error); return }
            if let data = photo.fileDataRepresentation(), let image = UIImage(data: data) {
                cont?.resume(returning: image)
            } else {
                cont?.resume(throwing: CocoaError(.fileReadCorruptFile))
            }
        }
    }

    /// Cheap live read, a few times a second, to tell the user whether text is in view.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastTextCheck) > 0.4, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastTextCheck = Date()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right).perform([request])
        let lines = (request.results ?? []).filter { ($0.topCandidates(1).first?.confidence ?? 0) > 0.5 }.count
        if lines != state.textLines {
            state.textLines = lines
            onState?(state)
        }
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraPreview: UIViewRepresentable {
    let engine: CameraEngine

    func makeUIView(context: Context) -> UIView {
        let v = PreviewView()
        v.previewLayer.session = engine.session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        context.coordinator.view = v
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(engine) }

    final class Coordinator: NSObject {
        let engine: CameraEngine
        weak var view: PreviewView?
        init(_ e: CameraEngine) { engine = e }
        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            engine.focus(atDevicePoint: v.previewLayer.captureDevicePointConverted(fromLayerPoint: g.location(in: v)))
        }
    }
}

enum LiveCamera {
    static var isAvailable: Bool { CameraEngine.isAvailable }
}

struct LiveScannerView: View {
    /// Called with each photo. Returns a short status to show, such as "Clear" or "Unclear, retake".
    var onPhoto: (UIImage) async -> String
    var onDone: () -> Void
    var count: Int

    @State private var engine = CameraEngine()
    @State private var state = CameraEngine.State()
    @State private var started = false
    @State private var failed = false
    @State private var busy = false
    @State private var status: String?

    private var ready: Bool { !state.focusing && state.textLines >= 3 && !busy }

    var body: some View {
        ZStack {
            if started { CameraPreview(engine: engine).ignoresSafeArea() } else { Color.black.ignoresSafeArea() }
            VStack(spacing: 8) {
                Text(failed ? "The camera isn't available. Check Settings > React Check > Camera, or choose photos instead."
                            : "Hold the phone close to the ingredients. Tap the text to focus.")
                    .font(.callout).multilineTextAlignment(.center)
                    .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 8)
                Spacer()
                Label(hint, systemImage: ready ? "text.viewfinder" : "viewfinder")
                    .font(.headline).padding(10)
                    .background(ready ? AnyShapeStyle(Color.teal) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                    .foregroundStyle(ready ? .white : .primary)
                if let status {
                    Text(status).font(.subheadline).padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityAddTraits(.updatesFrequently)
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text(count == 0 ? " " : "\(count) taken")
                        Button { engine.setTorch(!state.torchOn) } label: {
                            Image(systemName: state.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        }
                        .accessibilityLabel("Torch")
                    }
                    .frame(width: 90, alignment: .leading)
                    Spacer()
                    Button { Task { await shoot() } } label: {
                        ZStack {
                            Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                            Circle().fill(.white).frame(width: 62, height: 62).opacity(busy ? 0.4 : 1)
                        }
                    }
                    .disabled(busy)
                    .accessibilityLabel("Take photo")
                    Spacer()
                    Button("Done") { engine.stop(); onDone() }.bold().frame(width: 90, alignment: .trailing)
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
                .foregroundStyle(.white)
            }
        }
        .task {
            engine.onState = { s in Task { @MainActor in state = s } }
            if await engine.start() { started = true } else { failed = true }
        }
        .onDisappear { engine.stop() }
    }

    private var hint: String {
        if busy { return "Reading…" }
        if state.focusing { return "Focusing. You can still take the photo." }
        if state.textLines < 3 { return "Text is hard to see. Move closer, or just try." }
        return "Looks sharp. Tap the button."
    }

    private func shoot() async {
        busy = true
        defer { busy = false }
        do {
            status = await onPhoto(try await engine.capture())
        } catch {
            status = "Couldn't take the photo. Try again."
        }
    }
}
