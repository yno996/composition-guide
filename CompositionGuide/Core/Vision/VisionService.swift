import Vision
import CoreML
import AVFoundation

/// 视觉服务：把一帧 CVPixelBuffer 转成 FrameFeatures
/// 检测优先级与 Python 版一致：人脸(Vision) > YOLO(CoreML) > 显著性(占位,暂未接入)
/// 注意：Vision 的归一化框原点在左下角，本服务统一转为左上角后再输出
final class VisionService {

    struct Detection {
        let rect: CGRect            // 归一化，左上原点
        let label: String
        let confidence: Double
    }

    struct Output {
        let features: FrameFeatures
        let faceRects: [CGRect]     // 用于 UI 绘制（归一化，左上原点）
        let detections: [Detection] // YOLO 全部检出（用于 UI 绘制次级框）
    }

    private let config: RulesConfig
    private var yoloRequest: VNCoreMLRequest?

    init(config: RulesConfig) {
        self.config = config
        loadYoloModel()
    }

    // MARK: - 模型加载

    /// 加载 yolov8n.mlmodel（M3 阶段放入 App Bundle；缺失时静默降级为无 YOLO）
    private func loadYoloModel() {
        guard let url = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc"),
              let mlModel = try? MLModel(contentsOf: url),
              let vnModel = try? VNCoreMLModel(for: mlModel) else {
            return
        }
        yoloRequest = VNCoreMLRequest(model: vnModel) { _, _ in }
        yoloRequest?.imageCropAndScaleOption = .scaleFill
    }

    // MARK: - 主入口

    func analyze(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> Output {
        let faces = detectFaces(pixelBuffer: pixelBuffer, orientation: orientation)
        let horizon = detectHorizon(pixelBuffer: pixelBuffer, orientation: orientation)
        var detections: [Detection] = []
        if yoloRequest != nil {
            detections = detectObjects(pixelBuffer: pixelBuffer, orientation: orientation)
        }

        // ---------- 主体选择（与 Python 版三级策略一致） ----------
        var subjectRect: CGRect?
        var centroid: CGPoint?
        var isFaceBased = false

        if let faceBox = largestFace(faces) {
            // 人脸优先：人脸+扩展身体框，质心=人脸中心，抑制地平线规则
            let ext = config.subject.bodyWidthExtend
            let bodyW = faceBox.width
            let bodyH = faceBox.height * config.subject.bodyExtendRatio
            let bx = max(0, faceBox.minX - bodyW * ext)
            let by = faceBox.minY
            let bw = min(1, faceBox.width + bodyW * ext * 2)
            let bh = min(1 - by, bodyH + faceBox.height)
            subjectRect = CGRect(x: bx, y: by, width: bw, height: bh)
            centroid = CGPoint(x: faceBox.midX, y: faceBox.midY)
            isFaceBased = true
        } else if let main = CompositionEngine.selectSubject(from: detections.map({ ($0.rect, $0.label, $0.confidence) }),
                                                             config: config) {
            // YOLO 主体
            subjectRect = main.rect
            centroid = CGPoint(x: main.rect.midX, y: main.rect.midY)
        }

        // 人脸优先时抑制地平线（与 Python 版一致）
        let horizonInfo = isFaceBased ? nil : horizon
        let features = FrameFeatures(subjectRect: subjectRect,
                                     subjectCentroid: centroid,
                                     isFaceBased: isFaceBased,
                                     horizon: horizonInfo)
        return Output(features: features,
                      faceRects: faces.map(\.rect),
                      detections: detections)
    }

    // MARK: - 人脸检测

    private func detectFaces(pixelBuffer: CVPixelBuffer,
                             orientation: CGImagePropertyOrientation) -> [(rect: CGRect, confidence: Double)] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        try? handler.perform([request])
        guard let observations = request.results else { return [] }
        return observations.compactMap { obs in
            guard obs.confidence >= Float(config.subject.faceScore) else { return nil }
            return (toTopLeftOrigin(obs.boundingBox), Double(obs.confidence))
        }
    }

    private func largestFace(_ faces: [(rect: CGRect, confidence: Double)]) -> CGRect? {
        faces.max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height })?.rect
    }

    // MARK: - 水平线检测

    private func detectHorizon(pixelBuffer: CVPixelBuffer,
                               orientation: CGImagePropertyOrientation) -> FrameFeatures.HorizonInfo? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        try? handler.perform([request])
        guard let obs = request.results?.first else { return nil }
        let angleDeg = Double(obs.angle) * 180.0 / .pi
        // TODO(M3 真机校准)：由 transform 推导 y 位置；先按中点近似，真机验证后修正
        let yPosition = 0.5 - Double(obs.transform.ty)
        let m = config.horizon.edgeMargin
        let clamped = min(max(yPosition, m), 1 - m)
        if abs(angleDeg) > config.horizon.maxCandidateAngleDeg { return nil }
        return FrameFeatures.HorizonInfo(angleDeg: angleDeg, yPosition: clamped)
    }

    // MARK: - YOLO 目标检测

    private func detectObjects(pixelBuffer: CVPixelBuffer,
                               orientation: CGImagePropertyOrientation) -> [Detection] {
        guard let request = yoloRequest else { return [] }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        try? handler.perform([request])
        guard let results = request.results as? [VNRecognizedObjectObservation] else { return [] }
        return results.compactMap { obs in
            guard let label = obs.labels.first, label.confidence >= Float(config.subject.yoloConf) else { return nil }
            return Detection(rect: toTopLeftOrigin(obs.boundingBox),
                             label: label.identifier,
                             confidence: Double(label.confidence))
        }
    }

    // MARK: - 坐标转换

    /// Vision 归一化框（原点左下）→ 左上原点
    private func toTopLeftOrigin(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}
