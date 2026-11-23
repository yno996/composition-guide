import Foundation

/// 规则参数配置 —— 与 ai-composition/rules_config.json 一一对应
/// 读取 Bundle 内 rules_config.json；读取失败时使用与 Python 版相同的默认值
public struct RulesConfig: Codable {
    public struct Analyze: Codable {
        public var longEdge: Int = 960          // 分析前长边缩放目标
        public var frameSampleMs: Int = 300     // 抽帧间隔（约3fps）
    }
    public struct Subject: Codable {
        public var noiseAreaRatio: Double = 0.01    // 显著性噪声门槛
        public var minAreaRatio: Double = 0.02      // 主体最小占比
        public var maxAreaRatio: Double = 0.60      // 主体最大占比
        public var topMargin: Double = 0.08         // 顶部贴边判定
        public var yoloConf: Double = 0.35          // YOLO 置信度阈值
        public var yoloMinAreaRatio: Double = 0.06  // YOLO 主体最小占比
        public var faceScore: Double = 0.6          // 人脸置信度阈值
        public var bodyExtendRatio: Double = 2.2    // 人脸框向下扩展(身体)
        public var bodyWidthExtend: Double = 0.4    // 人脸框横向扩展
    }
    public struct Thirds: Codable {
        public var pointTolerance: Double = 0.09    // 三分点容差
        public var centerTolerance: Double = 0.10   // "居中"判定容差
        public var penaltyCenter: Double = 20       // 居中扣分
        public var penaltyOffPoint: Double = 8      // 偏离三分点扣分
    }
    public struct Horizon: Codable {
        public var maxCandidateAngleDeg: Double = 10    // 超过此角度视为物体斜边
        public var edgeMargin: Double = 0.12            // 距画框边缘此距离内不算地平线
        public var tiltWarnDeg: Double = 1.5            // 倾斜警告阈值
        public var positionTolerance: Double = 0.10     // 距三分线容差
        public var penaltyTilt: Double = 15
        public var penaltyPosition: Double = 12
    }
    public struct Penalty: Codable {
        public var tooSmall: Double = 10
        public var tooLarge: Double = 5
        public var topCrowded: Double = 8
    }

    public var analyze = Analyze()
    public var subject = Subject()
    public var thirds = Thirds()
    public var horizon = Horizon()
    public var penalty = Penalty()

    /// 从 App Bundle 加载 rules_config.json；找不到或解析失败时用默认值
    public static func load(bundle: Bundle = .main) -> RulesConfig {
        guard let url = bundle.url(forResource: "rules_config", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return RulesConfig()
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(RulesConfig.self, from: data)) ?? RulesConfig()
    }
}
