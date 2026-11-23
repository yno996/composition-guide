# AI 构图拍照 App — 整体设计方案（v1.0）

> 更新：2026-11-23 ｜ 状态：阶段 0 已完成
> 产品形态：iOS 自用 App，"建议式"软引导（可一键关闭），不强制自动调整

---

## 1. 产品定义

| 项 | 内容 |
|---|---|
| 一句话定位 | 拍照时实时告诉你"怎么构图更好"，你看建议、你按快门 |
| 用户 | 本人自用（后续满意再扩展 Android 版） |
| 核心体验 | 打开相机 → 取景画面上出现指导（九宫格/主体框/一句话建议）→ 调整到提示消失/得分变高 → 拍摄 |
| 产品原则 | ① 建议不强制，随时可关；② 端侧离线运行，不传图、无 API 费用；③ 每条建议必须"可执行"（告诉用户往哪移，而不只打分） |

## 2. 功能清单

**MVP（V1.0）**
1. 实时取景 + 九宫格/三分点 Overlay
2. 主体检测框 + 质心显示
3. 规则引擎实时评分 + 中文建议（三分法、地平线位置、倾斜、主体大小、顶部留白）
4. 建议开关（设置页一键关闭所有引导）
5. 拍照保存（系统相册）

**V1.1+（暂不做，仅记录方向）**
- 拍后智能二次裁剪；自动构图提示（虚拟取景框平移）；人像模式专项规则；美学评分模型融合；拍后生成式扩图

## 3. 总体架构

```
┌─────────────── 阶段0：算法试验田（Windows/Python，已完成 ✔）───────────────┐
│  analyze.py 规则引擎原型 → make_tests.py 测试图 → 真实照片批量验证        │
│  职责：把"规则和阈值"调对，产出《规则参数定版表》                          │
└──────────────────────────────┬────────────────────────────────────────┘
                               │ 移植同一套规则参数
┌──────────────────────────────▼──── 阶段1：iOS App（Mac/Xcode）──────────┐
│                                                                        │
│  [UI 层 SwiftUI]                                                       │
│    ViewfinderView    取景预览 + Overlay绘制 + 建议文字                  │
│    SettingsView      建议开关 / 规则开关                                │
│                                        ▲                               │
│  [引擎层（纯Swift，可单测）]             │ 每300ms一帧的结果              │
│    CompositionEngine 规则评分引擎       │                               │
│    SuggestionFormatter 规则→中文文案    │                               │
│                                        │                               │
│  [能力层（系统框架）]                    │                               │
│    CameraService  AVFoundation 取景流/抽帧/拍照                         │
│    VisionService  CoreML(YOLOv8n主体) + Vision(水平线/人脸)             │
└────────────────────────────────────────────────────────────────────────┘
```

**设计要点**
- **规则参数一处定义**：阈值表（三分容差、倾斜上限等）做成独立配置文件 `RulesConfig.json`，阶段 0 的 Python 和阶段 1 的 Swift 读同一份 → 两端行为一致，调优只改一处。
- **引擎层与 UI 解耦**：`CompositionEngine` 输入"帧特征"（主体框、地平线角度/位置），输出"得分+建议列表"，不依赖相机 → 可以拿照片批量回归测试。
- **抽帧降频**：预览 30fps，但分析每 300ms 取 1 帧（≈3fps），是省电不卡顿的关键。

## 4. 数据流（单帧处理管线）

```
摄像头帧 → 降采样(长边≤960) → 并行:
   ├─ YOLOv8n(CoreML) → 主体框+质心
   └─ VNDetectHorizonRequest → 地平线角度/位置
        ↓
   CompositionEngine 读 RulesConfig 逐规则评分 → Score + [建议]
        ↓
   Overlay 绘制(九宫格/绿框/橙线) + 建议文字（0.3s 内更新到 UI）
```

## 5. 模型与能力清单

| 能力 | 方案 | 部署 | 状态 |
|---|---|---|---|
| 主体检测 | YOLOv8n → CoreML（INT8 量化） | 端侧 | 阶段0 后期接入验证 |
| 水平线检测 | Vision `VNDetectHorizonRequest`（系统自带） | 端侧 | 直接可用 |
| 人像分割(可选) | Vision `VNGeneratePersonSegmentationRequest` | 端侧 | V1.1 |
| 场景分类(可选) | MobileNet 或 Vision 分类器 | 端侧 | V1.1 |

## 6. 里程碑

| 里程碑 | 内容 | 依赖 | 状态 |
|---|---|---|---|
| M0 | 规则引擎原型 + 合成图验证 | Windows | ✔ 完成 |
| M1 | 真实照片批量验证 + 接入 YOLO 替代显著性 + 规则参数定版 | Windows | ✔ 完成（2026-11-23） |
| M2 | iOS 骨架：相机预览 + 九宫格 Overlay + 拍照 | **需要 Mac** | 待 Mac |
| M3 | CoreML 模型接入 + 规则引擎 Swift 移植 + 实时建议 | Mac | — |
| M4 | 设置页、性能调优、真机自用 | Mac | — |

## 7. 验收标准（M3 完成时）

1. 30 张真实样片：App 建议与人工判断一致率 ≥ 80%
2. 单帧分析端到端延迟 ≤ 300ms（iPhone 上）
3. 连续取景 10 分钟，机身不过热、无明显掉电加速
4. 关闭建议开关后，App 行为等同普通相机

## 7.1 硬性交付要求：最终可打包

**项目全部完成时（M4 结束），必须交付可打包的成品：**

- iOS 工程为标准 Xcode 工程（Swift Package 结构，无第三方编译依赖陷阱），在 Mac 上 `Product → Archive` 一键产出 `.ipa` 安装包
- 自用安装两条路（届时按需选择）：
  - 免费 Apple ID：Xcode 直接真机运行安装，**证书 7 天过期需重新安装**
  - 付费开发者账号（¥688/年）：Ad Hoc/TestFlight 长期安装
- 打包前置检查项（M4 验收时逐条过）：签名配置正确 / 模型文件已嵌入 App Bundle / 相机权限描述文案齐全 / 断网状态下全功能可用
- 阶段 0 的 Python 工程同步保持"requirements.txt + 从零可复现"的打包状态（已达成）

## 8. 风险与对策

| 风险 | 对策 |
|---|---|
| 无 Mac 阻塞 M2/M3 | M1 全部做完后再解决；期间 Swift 代码可先写好（语法可离线检查），有 Mac 即编译 |
| 显著性/检测误报 | M1 用 YOLO 真实检测替代；建议文案避免绝对化（"建议…"而非"必须"） |
| YOLOv8n→CoreML 转换兼容 | ultralytics 官方支持 `format="coreml"`；备选 NCNN/CoreML Tools |
| 预览画面与成片不一致 | M4 加拍后二次分析兜底（V1.1 的智能裁剪） |
| 端侧发热/耗电 | 3fps 抽帧 + INT8 量化 + 只在画面变化时刷新建议 |

## 9. 目录结构规划

```
ai-composition/               ← 阶段0（当前，Windows）
  analyze.py                    规则引擎原型（评分逻辑的"标准答案"）
  make_tests.py                 测试图生成
  rules_config.json             规则参数表（两端共享，M1 产出）
  tests/ … output/              测试图与标注结果

CompositionGuide/             ← 阶段1 iOS 工程（M2 创建，Mac 上）
  App/                          入口
  Features/Viewfinder/          取景 UI + Overlay
  Features/Settings/            设置页
  Core/Camera/CameraService     AVFoundation
  Core/Vision/VisionService     CoreML + Vision
  Core/Composition/             规则引擎(Swift版) + RulesConfig.json
  Resources/Models/yolov8n.mlmodel
```
