import SwiftUI
import AVFoundation

/// 取景主界面：相机预览 + 构图 Overlay + 建议文字 + 快门
struct ViewfinderView: View {
    @StateObject private var model = ViewfinderModel()
    @AppStorage("guidanceEnabled") private var guidanceEnabled = true
    @State private var showSettings = false
    @State private var capturedImage: UIImage?

    var body: some View {
        ZStack {
            CameraPreview(session: model.cameraSession)
                .ignoresSafeArea()

            if guidanceEnabled {
                CompositionOverlay(subjectRect: model.subjectRect,
                                   faceRects: model.faceRects,
                                   detections: model.detections,
                                   horizon: model.horizon)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    // 当前建议（取最高优先级的第一条）
                    if let tip = model.currentSuggestion {
                        Text(tip)
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                            .padding(.bottom, 8)
                    }
                    // 得分胶囊（Design.md 需求：分数常驻）
                    if let score = model.score {
                        Text("构图 \(Int(score)) 分")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(scoreColor(score).opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.bottom, 16)
                    }
                }
            }

            // 顶部工具栏
            VStack {
                HStack {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                            .padding(10)
                            .background(.black.opacity(0.4), in: Circle())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                Spacer()
            }

            // 快门
            VStack {
                Spacer()
                Button {
                    model.capturePhoto { image in
                        capturedImage = image
                    }
                } label: {
                    Circle()
                        .strokeBorder(.white, lineWidth: 5)
                        .frame(width: 74, height: 74)
                        .background(Circle().fill(.white.opacity(0.3)).padding(5))
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(item: $capturedImage) { image in
            CapturePreviewView(image: image) { model.start() }
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        switch score {
        case 90...: return .green
        case 75..<90: return .yellow
        default: return .orange
        }
    }
}

extension UIImage: Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// 拍后预览：确认保存或重拍
struct CapturePreviewView: View {
    let image: UIImage
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .ignoresSafeArea(edges: .top)
            HStack(spacing: 40) {
                Button("重拍") { dismiss() }
                Button("保存到相册") {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .background(.black)
        .onDisappear { onDismiss() }
    }
}

/// AVCaptureVideoPreviewLayer 的 SwiftUI 包装
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = UIScreen.main.bounds
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let layer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = UIScreen.main.bounds
        }
    }
}
