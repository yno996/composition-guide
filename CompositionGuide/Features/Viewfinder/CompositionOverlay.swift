import SwiftUI
import AVFoundation

/// 取景界面的状态与调度：相机帧 → 视觉分析 → 规则引擎 → UI 状态
@MainActor
final class ViewfinderModel: ObservableObject {

    let cameraSession = AVCaptureSession()
    private var camera: CameraService?
    private var vision: VisionService?
    private let config = RulesConfig.load()

    @Published var score: Double?
    @Published var currentSuggestion: String?
    @Published var subjectRect: CGRect?        // 归一化，左上原点
    @Published var faceRects: [CGRect] = []
    @Published var detections: [VisionService.Detection] = []
    @Published var horizon: FrameFeatures.HorizonInfo?

    func start() {
        if camera == nil {
            let camera = CameraService()
            do {
                try camera.configure(frameSampleMs: config.analyze.frameSampleMs)
                camera.onFrame = { [weak self] pixelBuffer, orientation in
                    self?.processFrame(pixelBuffer: pixelBuffer, orientation: orientation)
                }
                vision = VisionService(config: config)
                self.camera = camera
            } catch {
                currentSuggestion = error.localizedDescription
            }
        }
        camera?.start()
    }

    func stop() { camera?.stop() }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        camera?.capturePhoto(completion: completion)
    }

    // MARK: - 帧处理（相机回调线程 → 主线程更新 UI）

    private nonisolated func processFrame(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard let vision = vision else { return }
        let output = vision.analyze(pixelBuffer: pixelBuffer, orientation: orientation)
        let result = CompositionEngine.analyze(output.features, config: config)
        Task { @MainActor in
            apply(output: output, result: result)
        }
    }

    private func apply(output: VisionService.Output, result: CompositionResult) {
        score = result.score
        // 建议可能同时有多条：优先展示"位置类"，其次倾斜/大小类；取第一条
        currentSuggestion = result.suggestions.first
        subjectRect = output.features.subjectRect
        faceRects = output.faceRects
        detections = output.detections
        horizon = output.features.horizon
    }
}

/// 构图 Overlay：九宫格 + 三分点 + 主体框 + 人脸框 + 次级检出框 + 地平线
struct CompositionOverlay: View {
    let subjectRect: CGRect?
    let faceRects: [CGRect]
    let detections: [VisionService.Detection]
    let horizon: FrameFeatures.HorizonInfo?

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height

            // 九宫格
            let gridColor = Color.white.opacity(0.4)
            for i in 1...2 {
                let x = w * CGFloat(i) / 3
                context.stroke(Path { $0.move(to: .init(x: x, y: 0)); $0.addLine(to: .init(x: x, y: h)) },
                               with: .color(gridColor), lineWidth: 0.8)
                let y = h * CGFloat(i) / 3
                context.stroke(Path { $0.move(to: .init(x: 0, y: y)); $0.addLine(to: .init(x: w, y: y)) },
                               with: .color(gridColor), lineWidth: 0.8)
            }
            // 三分点
            for px in [1.0, 2.0] {
                for py in [1.0, 2.0] {
                    let p = CGPoint(x: w * CGFloat(px) / 3, y: h * CGFloat(py) / 3)
                    context.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                                   with: .color(.yellow.opacity(0.9)), lineWidth: 1.2)
                }
            }

            // 次级检出框（暗黄细框）
            for d in detections where d.rect != subjectRect {
                context.stroke(Path(rect: flip(d.rect, w, h)), with: .color(.yellow.opacity(0.45)), lineWidth: 1)
            }

            // 人脸框（蓝色）
            for face in faceRects {
                context.stroke(Path(rect: flip(face, w, h)), with: .color(.cyan), lineWidth: 2)
            }

            // 主体框（绿色）
            if let rect = subjectRect {
                context.stroke(Path(rect: flip(rect, w, h)), with: .color(.green), lineWidth: 2.5)
            }

            // 地平线（橙色）：过 (0.5, yPos) 以 tan(angle) 为斜率的直线
            if let hor = horizon {
                let yMid = h * CGFloat(hor.yPosition)
                let slope = CGFloat(tan(hor.angleDeg * .pi / 180))
                let p1 = CGPoint(x: 0, y: yMid + slope * (-w / 2))
                let p2 = CGPoint(x: w, y: yMid + slope * (w / 2))
                var line = Path()
                line.move(to: p1)
                line.addLine(to: p2)
                context.stroke(line, with: .color(.orange), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    /// 归一化(左上原点) → 屏幕像素；同时做上下翻转（预览层与实际成像方向相反）
    private func flip(_ rect: CGRect, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: rect.minX * w, y: (1 - rect.maxY) * h, width: rect.width * w, height: rect.height * h)
    }
}
