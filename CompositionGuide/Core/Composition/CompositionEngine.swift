import Foundation
import CoreGraphics

/// 一帧画面的特征输入（由 VisionService 从摄像头帧提取）
/// 所有坐标均为归一化 0~1，原点在左上角（与 iOS UIKit 坐标习惯一致）
public struct FrameFeatures {
    public struct HorizonInfo {
        public var angleDeg: Double     // 相对水平的角度（正=右端向下）
        public var yPosition: Double    // 地平线在画面中的垂直位置 0~1
        public init(angleDeg: Double, yPosition: Double) {
            self.angleDeg = angleDeg
            self.yPosition = yPosition
        }
    }

    public var subjectRect: CGRect?         // 主体框（归一化）
    public var subjectCentroid: CGPoint?    // 主体质心（人像=人脸中心）
    public var isFaceBased: Bool            // 主体是否由人脸得出（人脸优先时抑制地平线规则）
    public var horizon: HorizonInfo?        // 地平线（nil=未检出）

    public init(subjectRect: CGRect?, subjectCentroid: CGPoint?,
                isFaceBased: Bool = false, horizon: HorizonInfo?) {
        self.subjectRect = subjectRect
        self.subjectCentroid = subjectCentroid
        self.isFaceBased = isFaceBased
        self.horizon = horizon
    }
}

/// 一帧画面的构图分析结果
public struct CompositionResult {
    public var score: Double            // 0~100
    public var suggestions: [String]    // 中文建议（每条都可执行）
}

/// 构图规则引擎（Swift 版）—— 与 ai-composition/analyze.py 的 analyze() 逐规则对应
/// 纯函数、无任何系统依赖，可单元测试、可在真机外验证
public enum CompositionEngine {

    public static func analyze(_ f: FrameFeatures, config: RulesConfig) -> CompositionResult {
        var score = 100.0
        var suggestions: [String] = []

        // 画面宽高按 1.0 归一化处理；三分点坐标（左上原点）
        let thirdsPoints: [CGPoint] = [
            CGPoint(x: 1.0 / 3.0, y: 1.0 / 3.0),
            CGPoint(x: 2.0 / 3.0, y: 1.0 / 3.0),
            CGPoint(x: 1.0 / 3.0, y: 2.0 / 3.0),
            CGPoint(x: 2.0 / 3.0, y: 2.0 / 3.0),
        ]

        // ---------- 主体规则 ----------
        if let rect = f.subjectRect, let centroid = f.subjectCentroid {
            let areaRatio = Double(rect.width * rect.height)

            // 规则1：三分法 —— 质心离最近三分点的距离
            let minDist = thirdsPoints.map { hypot(centroid.x - $0.x, centroid.y - $0.y) }.min() ?? 0
            let distNorm = minDist / 0.667      // 与 Python 版相同的归一化系数
            if distNorm > config.thirds.pointTolerance {
                let nearCenter = abs(Double(centroid.x) - 0.5) < config.thirds.centerTolerance
                    && abs(Double(centroid.y) - 0.5) < config.thirds.centerTolerance
                if nearCenter {
                    score -= config.thirds.penaltyCenter
                    suggestions.append("主体位于画面正中，画面容易呆板。建议将主体移向某个三分交叉点（取景框中的4个交点）。")
                } else {
                    score -= config.thirds.penaltyOffPoint
                    suggestions.append("主体未落在三分点上，可以微调取景位置，让主体更靠近三分交叉点。")
                }
            } else {
                suggestions.append("主体位置符合三分法，构图不错。")
            }

            // 规则2：主体大小
            if areaRatio < config.subject.minAreaRatio {
                score -= config.penalty.tooSmall
                suggestions.append("主体占画面比例过小，建议走近一些或用变焦放大主体。")
            } else if areaRatio > config.subject.maxAreaRatio {
                score -= config.penalty.tooLarge
                suggestions.append("主体几乎占满画面，若想保留环境氛围可适当拉远。")
            }

            // 规则3：顶部留白（主体贴顶）
            if Double(rect.minY) < config.subject.topMargin {
                score -= config.penalty.topCrowded
                suggestions.append("主体太贴近画面顶部，建议下移留出上方空间。")
            }
        } else {
            suggestions.append("未检测到明显主体，可检查主体是否太小或对比度不足。")
        }

        // ---------- 地平线规则（人脸优先帧抑制，与 Python 版一致） ----------
        if let hor = f.horizon, !f.isFaceBased {
            // 规则4：地平线倾斜
            if abs(hor.angleDeg) > config.horizon.tiltWarnDeg {
                score -= config.horizon.penaltyTilt
                suggestions.append(String(format: "地平线倾斜约 %.1f 度，建议开启水平仪校正，保持水平线平直。", abs(hor.angleDeg)))
            }
            // 规则5：地平线位置 —— 接近上/下三分线，避免正中
            let dTop = abs(hor.yPosition - 1.0 / 3.0)
            let dBottom = abs(hor.yPosition - 2.0 / 3.0)
            if min(dTop, dBottom) > config.horizon.positionTolerance {
                score -= config.horizon.penaltyPosition
                if abs(hor.yPosition - 0.5) < config.horizon.positionTolerance {
                    suggestions.append("地平线在画面正中，上下被等分显得平淡。建议按三分法放在上1/3或下1/3处。")
                } else {
                    suggestions.append("地平线位置偏离三分线较多，建议调整取景高度。")
                }
            }
        }

        return CompositionResult(score: max(0, score), suggestions: suggestions)
    }

    /// YOLO 检出框中选主体：有人选人，否则选最大框；且非人物框面积须 ≥ yoloMinAreaRatio
    /// （与 Python 版 detect_objects 选主体逻辑一致；入参为归一化 CGRect）
    public static func selectSubject(from detections: [(rect: CGRect, label: String, confidence: Double)],
                                     config: RulesConfig) -> (rect: CGRect, label: String, confidence: Double)? {
        guard !detections.isEmpty else { return nil }
        let candidate = detections.first(where: { $0.label == "person" })
            ?? detections.max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height })!
        if candidate.label == "person" || candidate.rect.width * candidate.rect.height >= config.subject.yoloMinAreaRatio {
            return candidate
        }
        return nil
    }
}
