import SwiftUI
import UIKit
import Vision
import AVFoundation
import OSLog

enum VisualClueResult: Sendable, Equatable {
    case labels([String])
    case noUsefulLabels
    case unavailable
    case failed
    case cancelled
}

enum VisualClueProcessor {
    private static let logger = Logger(subsystem: "org.sayagain.communication", category: "VisualClue")

    static func classify(_ image: UIImage) async -> VisualClueResult {
        guard let cgImage = image.cgImage else { return .unavailable }
        let orientation: CGImagePropertyOrientation
        switch image.imageOrientation {
        case .up: orientation = .up
        case .down: orientation = .down
        case .left: orientation = .left
        case .right: orientation = .right
        case .upMirrored: orientation = .upMirrored
        case .downMirrored: orientation = .downMirrored
        case .leftMirrored: orientation = .leftMirrored
        case .rightMirrored: orientation = .rightMirrored
        @unknown default: orientation = .up
        }
        let task = Task.detached {
            let signposter = OSSignposter(subsystem: "org.sayagain.communication", category: "VisualClue")
            let interval = signposter.beginInterval("PhotoClassification")
            defer { signposter.endInterval("PhotoClassification", interval) }
            do {
                try Task.checkCancellation()
                let request = ClassifyImageRequest()
                let input = downscaled(cgImage, maximumDimension: 1024)
                let observations = try await request.perform(on: input, orientation: orientation)
                try Task.checkCancellation()
                var seen = Set<String>()
                let labels = observations.sorted { $0.confidence > $1.confidence }.compactMap { observation -> String? in
                    guard observation.confidence >= 0.25,
                          let label = visibleLabel(for: observation.identifier), seen.insert(label).inserted else { return nil }
                    return label
                }
                logger.info("visual_clue_classification_completed")
                return labels.isEmpty
                    ? VisualClueResult.noUsefulLabels
                    : VisualClueResult.labels(Array(labels.prefix(3)))
            } catch {
                if Task.isCancelled { return .cancelled }
                logger.notice("visual_clue_classification_failed")
                return .failed
            }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private static func visibleLabel(for identifier: String) -> String? {
        let normalized = identifier.lowercased().replacingOccurrences(of: "_", with: " ")
        let aliases: [String: String] = [
            "cup": "cup", "mug": "cup", "glass": "glass", "drinking glass": "glass",
            "water bottle": "water bottle", "bottle": "bottle", "coffee": "coffee",
            "fork": "fork", "spoon": "spoon", "plate": "plate", "phone": "phone",
            "telephone": "phone", "chair": "chair", "table": "table", "door": "door",
            "key": "key", "keys": "key", "pill": "pills", "pills": "pills",
            "bread": "bread", "apple": "apple", "banana": "banana", "plant": "plant",
            "potted plant": "plant", "decorative plant": "plant", "houseplant": "plant",
            "flower": "flower", "flowers": "flower", "flower arrangement": "flower",
            "tree": "tree", "flowerpot": "flower pot", "flower pot": "flower pot"
        ]
        return aliases[normalized]
    }

    private static func downscaled(_ image: CGImage, maximumDimension: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maximumDimension else { return image }
        let scale = CGFloat(maximumDimension) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

struct VisualClueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let onLabels: ([String]) -> Void
    let onTyped: (String) -> Void
    @State private var showCamera = false
    @State private var showFallback = false
    @State private var photo: UIImage?
    @State private var pendingPhoto: UIImage?
    @State private var labels: [String] = []
    @State private var processing = false
    @State private var resultMessage: String?
    @State private var permissionPending = false
    @State private var cameraMessage: String?
    @State private var processingTask: Task<Void, Never>?
    @State private var processingTimeoutTask: Task<Void, Never>?
    @State private var processingRequestID: UUID?
    @State private var permissionTask: Task<Void, Never>?
    @State private var closed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let photo {
                        Image(uiImage: photo).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 280)
                            .accessibilityLabel("Your photo clue. Not saved.")
                        if processing {
                            ProgressView("Looking for visible objects…")
                                .accessibilityIdentifier("visualClueProcessing")
                        } else if let resultMessage {
                            Text(resultMessage).foregroundStyle(.secondary)
                                .accessibilityIdentifier("visualClueResult")
                        } else {
                            Text(labels.isEmpty ? "No clear object found" : "Possible visual clues")
                                .font(.title2).accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("visualClueResult")
                            Text(labels.isEmpty
                                ? "This photo didn’t give us a useful word clue. Type what’s in the picture, or take another photo."
                                : labels.joined(separator: ", "))
                                .foregroundStyle(.secondary)
                        }
                        Text("This photo stays here while you review it. It isn’t saved to SayAgain or Photos.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "camera").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                        Text("Take a quick picture of what you’re trying to refer to.")
                            .font(.title2).accessibilityAddTraits(.isHeader)
                        Text("A glass, a key, or another object can help narrow the suggestions. You choose what it means.")
                            .foregroundStyle(.secondary)
                        Text("The camera opens full screen only after you tap Open Camera. The photo is processed on this device and isn’t saved.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let cameraMessage {
                        Text(cameraMessage).foregroundStyle(.secondary)
                        if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                            Button("Open Settings", systemImage: "gear") { openAppSettings() }
                        }
                    }
                }.frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity).padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if photo != nil && !labels.isEmpty && !processing {
                        Button { onLabels(labels); close() } label: {
                            Text("Use Visual Clue").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent)
                    }
                    if photo == nil {
                        openCameraButton.buttonStyle(.borderedProminent)
                    } else {
                        openCameraButton.buttonStyle(.bordered)
                    }
                    Button { showFallback = true } label: {
                        Label(photo == nil ? "Type a Clue" : "Type What’s in the Photo", systemImage: "keyboard")
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }.disabled(processing)
                }.frame(maxWidth: 600).frame(maxWidth: .infinity).padding().background(.background)
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
            .navigationTitle(photo == nil ? "Add a Visual Clue" : "Review Photo Clue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() }.accessibilityIdentifier("cancelVisualClue") } }
            .fullScreenCover(isPresented: $showCamera, onDismiss: {
                permissionPending = false
                if !closed, let image = pendingPhoto {
                    pendingPhoto = nil
                    photo = image
                    process(image)
                }
            }) {
                cameraCapture
            }
            .sheet(isPresented: $showFallback) {
                TypedClueSheet(initial: "") { onTyped($0); close() }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .background { close() } }
            .onDisappear {
                processingTask?.cancel(); processingTimeoutTask?.cancel(); permissionTask?.cancel()
                if !showCamera { photo = nil }
            }
        }.presentationDetents([.large])
    }

    private var openCameraButton: some View {
        Button { openCamera() } label: {
            Label(permissionPending ? "Opening Camera…" : (photo == nil ? "Open Camera" : "Take Another Photo"), systemImage: "camera")
                .frame(maxWidth: .infinity, minHeight: 44)
        }.disabled(permissionPending || processing)
    }

    @ViewBuilder private var cameraCapture: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-camera") {
            CameraCaptureFixture(onCapture: { pendingPhoto = $0; showCamera = false }, onCancel: { showCamera = false })
        } else {
            liveCamera
        }
        #else
        liveCamera
        #endif
    }

    private var liveCamera: some View {
                ImagePickerView(onUse: { image in
                    // Dismiss hardware capture before processing. Keep the
                    // still visible in this review step until the person acts.
                    showCamera = false
                    pendingPhoto = image
                }, onCancel: { showCamera = false })
                    .ignoresSafeArea()
                    .overlay(alignment: .top) {
                        Text("Camera open · Microphone off").font(.footnote)
                            .foregroundStyle(.white).padding(8).background(.black.opacity(0.7))
                            .allowsHitTesting(false).padding(.top, 8)
                    }
    }

    private func openCamera() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-camera") {
            showCamera = true
            return
        }
        #endif
        permissionTask?.cancel()
        permissionPending = true
        permissionTask = Task {
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                permissionPending = false
                cameraMessage = "A camera isn’t available here. You can type a clue instead."
                return
            }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            let allowed = status == .authorized ? true : (status == .notDetermined ? await AVCaptureDevice.requestAccess(for: .video) : false)
            guard !Task.isCancelled, !closed else { return }
            guard allowed else {
                permissionPending = false
                cameraMessage = "Camera access is off. Allow it in Settings, or use a typed clue."
                return
            }
            cameraMessage = nil
            showCamera = true
        }
    }

    private func process(_ image: UIImage) {
        processingTask?.cancel()
        processingTimeoutTask?.cancel()
        let requestID = UUID()
        processingRequestID = requestID
        processing = true
        labels = []
        resultMessage = nil
        processingTask = Task {
            let result = await VisualClueProcessor.classify(image)
            guard !Task.isCancelled, !closed, processingRequestID == requestID else { return }
            switch result {
            case .labels(let found): labels = found
            case .noUsefulLabels:
                labels = []
                resultMessage = "No clear object label was found. You can type what’s in the picture or take another photo."
            case .unavailable:
                labels = []
                resultMessage = "This photo can’t be processed here. You can type a clue instead."
            case .failed:
                labels = []
                resultMessage = "The photo clue couldn’t be processed. You can type a clue or try again."
            case .cancelled: return
            }
            processing = false
            processingTimeoutTask?.cancel()
            processingTimeoutTask = nil
            processingRequestID = nil
        }
        processingTimeoutTask = Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard processingRequestID == requestID else { return }
            processingTask?.cancel()
            processingTask = nil
            processing = false
            processingRequestID = nil
            resultMessage = "The photo clue is taking longer than expected. You can type a clue or try again."
        }
    }

    private func close() {
        closed = true
        processingTask?.cancel(); processingTimeoutTask?.cancel(); permissionTask?.cancel()
        processingRequestID = nil
        showCamera = false; photo = nil; pendingPhoto = nil
        dismiss()
    }
    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#if DEBUG
/// Clearly labeled interaction fixture, excluded from Release. The generated
/// blank image goes through the actual Vision processor; no labels are mocked.
private struct CameraCaptureFixture: View {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Text("Camera test fixture · Camera Off").font(.title2)
            Text("Blank test image. No camera is active.").foregroundStyle(.secondary)
            Spacer()
            Button("Capture Test Photo") {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).image { context in
                    UIColor.white.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
                }
                onCapture(image)
            }.buttonStyle(.borderedProminent)
            Button("Cancel") { onCancel() }.buttonStyle(.bordered).accessibilityIdentifier("cancelCameraFixture")
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
    }
}
#endif

private struct ImagePickerView: UIViewControllerRepresentable {
    let onUse: (UIImage) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onUse: onUse, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.modalPresentationStyle = .fullScreen
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onUse: (UIImage) -> Void
        let onCancel: () -> Void
        init(onUse: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onUse = onUse
            self.onCancel = onCancel
        }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { onCancel(); return }
            onUse(image)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
