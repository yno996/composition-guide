import XCTest
@testable import CompositionGuide

/// 规则引擎单元测试 —— 用例与 Python 版合成测试图(make_tests.py)的行为一一对应
/// 无需摄像头与模型，拿到 Mac 后可直接 Cmd+U 运行
final class CompositionEngineTests: XCTestCase {

    let config = RulesConfig()

    /// 对应 01_center_bad.png：主体居中 → 80 分 + "正中"建议
    func testCenteredSubjectPenalized() {
        let f = FrameFeatures(
            subjectRect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            subjectCentroid: CGPoint(x: 0.5, y: 0.5),
            horizon: nil)
        let r = CompositionEngine.analyze(f, config: config)
        XCTAssertEqual(r.score, 80, accuracy: 0.001)
        XCTAssertTrue(r.suggestions.contains { $0.contains("正中") })
    }

    /// 对应 02_thirds_good.png：主体在三分点 → 100 分
    func testThirdsSubjectPerfect() {
        let f = FrameFeatures(
            subjectRect: CGRect(x: 2.0/3.0 - 0.1, y: 1.0/3.0 - 0.1, width: 0.2, height: 0.2),
            subjectCentroid: CGPoint(x: 2.0/3.0, y: 1.0/3.0),
            horizon: nil)
        let r = CompositionEngine.analyze(f, config: config)
        XCTAssertEqual(r.score, 100, accuracy: 0.001)
        XCTAssertTrue(r.suggestions.contains { $0.contains("符合三分法") })
    }

    /// 对应 03_horizon_mid_bad.png：无主体 + 地平线居中 → 88 分 + "正中"位置建议
    func testHorizonCenterPenalty() {
        let f = FrameFeatures(subjectRect: nil, subjectCentroid: nil,
                              horizon: .init(angleDeg: 0.5, yPosition: 0.5))
        let r = CompositionEngine.analyze(f, config: config)
        XCTAssertEqual(r.score, 88, accuracy: 0.001)
        XCTAssertTrue(r.suggestions.contains { $0.contains("被等分") })
    }

    /// 对应 05_tilt_bad.png（特征版）：倾斜 8.9° 且位置居中 → 扣 15+12 = 73
    func testTiltPenalty() {
        let f = FrameFeatures(subjectRect: nil, subjectCentroid: nil,
                              horizon: .init(angleDeg: 8.9, yPosition: 0.5))
        let r = CompositionEngine.analyze(f, config: config)
        XCTAssertEqual(r.score, 73, accuracy: 0.001)
        XCTAssertTrue(r.suggestions.contains { $0.contains("倾斜") })
    }

    /// 人脸优先帧：即使有地平线也不应触发地平线规则
    func testFaceBasedSuppressesHorizon() {
        let f = FrameFeatures(
            subjectRect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.3),
            subjectCentroid: CGPoint(x: 2.0/3.0, y: 1.0/3.0),
            isFaceBased: true,
            horizon: .init(angleDeg: 8.0, yPosition: 0.5))
        let r = CompositionEngine.analyze(f, config: config)
        XCTAssertEqual(r.score, 100, accuracy: 0.001)
        XCTAssertFalse(r.suggestions.contains { $0.contains("地平线") })
    }

    /// YOLO 选主体：有人选人（即使人框更小）
    func testSelectSubjectPrefersPerson() {
        let detections = [
            (rect: CGRect(x: 0, y: 0.8, width: 0.15, height: 0.1), label: "potted plant", confidence: 0.9),
            (rect: CGRect(x: 0.3, y: 0.2, width: 0.2, height: 0.5), label: "person", confidence: 0.8),
        ]
        let main = CompositionEngine.selectSubject(from: detections, config: config)
        XCTAssertEqual(main?.label, "person")
    }

    /// YOLO 选主体：小面积非人物检出被拒绝（对应"盆栽误报"案例）
    func testSelectSubjectRejectsTinyObject() {
        let detections = [
            (rect: CGRect(x: 0.1, y: 0.7, width: 0.1, height: 0.08), label: "potted plant", confidence: 0.6),
        ]
        XCTAssertNil(CompositionEngine.selectSubject(from: detections, config: config))
    }
}
