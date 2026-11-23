# -*- coding: utf-8 -*-
"""
阶段0 构图分析原型（规则引擎版）
功能：读取图片 -> 找主体(显著性) -> 找地平线(霍夫变换) ->
      按摄影构图规则打分并输出中文建议 -> 保存标注图
用法：
  python analyze.py 图片路径
  python analyze.py 文件夹路径        # 批量分析整个文件夹
  python analyze.py 文件夹路径 -o 输出目录
"""
import argparse
import math
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps

try:  # 支持 iPhone 的 HEIC 格式；没装也不影响 JPG/PNG
    import pillow_heif
    pillow_heif.register_heif_opener()
except ImportError:
    pass

# ---------------- 规则参数：从 rules_config.json 加载（缺省值兜底） ----------------
# 这份配置将来由 iOS 端共享使用：Python 调好的参数，Swift 原样照搬
import json

CONFIG_PATH = Path(__file__).parent / "rules_config.json"

_DEFAULTS = {
    "analyze": {"long_edge": 960, "frame_sample_ms": 300},
    "subject": {
        "noise_area_ratio": 0.01, "min_area_ratio": 0.02, "max_area_ratio": 0.6,
        "top_margin": 0.08, "yolo_conf": 0.35, "yolo_min_area_ratio": 0.06,
        "face_score": 0.6, "body_extend_ratio": 2.2, "body_width_extend": 0.4,
    },
    "thirds": {
        "point_tolerance": 0.09, "center_tolerance": 0.1,
        "penalty_center": 20, "penalty_off_point": 8,
    },
    "horizon": {
        "max_candidate_angle_deg": 10.0, "edge_margin": 0.12,
        "tilt_warn_deg": 1.5, "position_tolerance": 0.1,
        "penalty_tilt": 15, "penalty_position": 12,
    },
    "penalty": {"too_small": 10, "too_large": 5, "top_crowded": 8},
}

def load_config():
    cfg = {k: dict(v) for k, v in _DEFAULTS.items()}
    if CONFIG_PATH.exists():
        data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        for k, v in data.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    return cfg

CFG = load_config()

# ---------------- 主体检测：显著性 + 最大连通块 ----------------
def detect_subject(img):
    """返回 (x, y, w, h, 质心cx, cy)；找不到主体返回 None"""
    sal = cv2.saliency.StaticSaliencySpectralResidual_create()
    ok, salmap = sal.computeSaliency(img)
    if not ok:
        return None
    salmap = (salmap * 255).astype(np.uint8)
    _, bw = cv2.threshold(salmap, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    bw = cv2.morphologyEx(bw, cv2.MORPH_CLOSE, np.ones((17, 17), np.uint8))
    contours, _ = cv2.findContours(bw, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None
    c = max(contours, key=cv2.contourArea)
    area_ratio = cv2.contourArea(c) / (img.shape[0] * img.shape[1])
    if area_ratio < CFG["subject"]["noise_area_ratio"]:   # 噪点太小，不算主体
        return None
    x, y, w, h = cv2.boundingRect(c)
    M = cv2.moments(c)
    cx = M["m10"] / M["m00"] if M["m00"] else x + w / 2
    cy = M["m01"] / M["m00"] if M["m00"] else y + h / 2
    return x, y, w, h, cx, cy

# ---------------- 地平线检测：边缘 + 概率霍夫 ----------------
def detect_horizon(img):
    """返回 (角度deg, y位置, 线段端点) 或 None。只取最长的近水平长直线"""
    h, w = img.shape[:2]
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 50, 150)
    lines = cv2.HoughLinesP(edges, 1, np.pi / 180, threshold=120,
                            minLineLength=w // 3, maxLineGap=25)
    if lines is None:
        return None
    best = None
    for x1, y1, x2, y2 in np.asarray(lines).reshape(-1, 4):
        dx, dy = abs(x2 - x1), abs(y2 - y1)
        if dx < dy:                       # 竖线，跳过
            continue
        ang = math.degrees(math.atan2(y2 - y1, x2 - x1))
        if abs(ang) > CFG["horizon"]["max_candidate_angle_deg"]:  # 斜率过大：更像物体斜边，不是拍歪的地平线
            continue
        length = math.hypot(dx, dy)
        if best is None or length > best[0]:
            best = (length, ang, (x1, y1, x2, y2))
    if best is None:
        return None
    _, ang, (x1, y1, x2, y2) = best
    y_pos = (y1 + y2) / 2 / h             # 归一化到 0~1
    m = CFG["horizon"]["edge_margin"]
    if y_pos < m or y_pos > 1 - m:        # 贴着画框上/下边缘的线是边框，不是地平线
        return None
    return ang, y_pos, (x1, y1, x2, y2)

# ---------------- 人脸检测：YuNet（人像照片的主体应以人脸为准） ----------------
FACE_MODEL = Path(__file__).parent / "models" / "face_detection_yunet_2023mar.onnx"

def detect_faces(img):
    """返回 [(x, y, w, h, 置信度), ...]；模型文件缺失时返回空"""
    if not FACE_MODEL.exists():
        return []
    h, w = img.shape[:2]
    det = cv2.FaceDetectorYN_create(str(FACE_MODEL), "", (w, h),
                                    score_threshold=CFG["subject"]["face_score"])
    _, faces = det.detect(img)
    if faces is None:
        return []
    return [(int(f[0]), int(f[1]), int(f[2]), int(f[3]), float(f[-1])) for f in faces]

# ---------------- YOLO 通用主体检测（无人脸时使用） ----------------
YOLO_MODEL = Path(__file__).parent / "models" / "yolov8n.pt"
_yolo = None                # 模型只加载一次

def get_yolo():
    global _yolo
    if _yolo is None and YOLO_MODEL.exists():
        from ultralytics import YOLO
        _yolo = YOLO(str(YOLO_MODEL))
    return _yolo

def detect_objects(img):
    """返回 [(x, y, w, h, 置信度, 类名), ...]"""
    model = get_yolo()
    if model is None:
        return []
    res = model.predict(img, conf=CFG["subject"]["yolo_conf"], verbose=False)[0]
    out = []
    for b in res.boxes:
        x1, y1, x2, y2 = [int(v) for v in b.xyxy[0].tolist()]
        out.append((x1, y1, x2 - x1, y2 - y1, float(b.conf[0]), res.names[int(b.cls[0])]))
    return out# ---------------- 规则评分 ----------------
def analyze(img):
    """返回 (得分0-100, 建议列表, 检测结果字典)"""
    h, w = img.shape[:2]
    suggestions, detected = [], {}

    subj = detect_subject(img)
    hor = detect_horizon(img)
    faces = detect_faces(img)

    # 人脸优先策略：检测到人脸时，主体改用"人脸+身体"框，质心取人脸中心，
    # 并抑制地平线规则（人像照片里 Hough 极易把衣纹/背景直线误当地平线）
    if faces:
        detected["faces"] = faces
        fx1 = min(f[0] for f in faces); fy1 = min(f[1] for f in faces)
        fx2 = max(f[0] + f[2] for f in faces); fy2 = max(f[1] + f[3] for f in faces)
        fw = fx2 - fx1
        bw_ext = CFG["subject"]["body_width_extend"]
        bx1 = max(0, fx1 - int(fw * bw_ext))
        bx2 = min(w, fx2 + int(fw * bw_ext))
        by2 = min(h, fy2 + int((fy2 - fy1) * CFG["subject"]["body_extend_ratio"]))   # 向下扩展约2个头高作为身体
        subj = (bx1, fy1, bx2 - bx1, by2 - fy1,
                (fx1 + fx2) / 2, (fy1 + fy2) / 2)     # 质心=人脸中心
        hor = None

    # 无人脸时：YOLO 检测结果优先于显著性（人物/物体检测远比显著性稳定）
    # 但要求主体框足够大（≥6%画面）：COCO 类别不含雕塑/建筑等，
    # 小检出物（如角落的盆栽）不代表画面主体，此时回退显著性
    if not faces:
        objs = detect_objects(img)
        main = None
        if objs:
            cand = next((o for o in objs if o[5] == "person"),
                        max(objs, key=lambda o: o[2] * o[3]))  # 有人选人，否则选最大框
            if cand[5] == "person" or (cand[2] * cand[3]) / (w * h) >= CFG["subject"]["yolo_min_area_ratio"]:
                main = cand
        if main:
            detected["yolo"] = objs
            detected["main"] = main
            subj = (main[0], main[1], main[2], main[3],
                    main[0] + main[2] / 2, main[1] + main[3] / 2)
    score = 100.0

    # 三分点坐标（4个交叉点）
    pts = [(w / 3, h / 3), (2 * w / 3, h / 3), (w / 3, 2 * h / 3), (2 * w / 3, 2 * h / 3)]

    if subj:
        x, y, bw_, bh_, cx, cy = subj
        detected["subject"] = (x, y, bw_, bh_, cx, cy)
        area_ratio = (bw_ * bh_) / (w * h)

        # 规则1：三分法 —— 质心离最近三分点的距离
        dist = min(math.hypot(cx - px, cy - py) for px, py in pts)
        dist_norm = dist / (w * 0.667)        # 归一化
        if dist_norm > CFG["thirds"]["point_tolerance"]:
            near_center = (abs(cx - w / 2) < w * CFG["thirds"]["center_tolerance"] and
                           abs(cy - h / 2) < h * CFG["thirds"]["center_tolerance"])
            if near_center:
                score -= CFG["thirds"]["penalty_center"]
                suggestions.append("主体位于画面正中，画面容易呆板。建议将主体移向某个三分交叉点（取景框中的4个交点）。")
            else:
                score -= CFG["thirds"]["penalty_off_point"]
                suggestions.append("主体未落在三分点上，可以微调取景位置，让主体更靠近三分交叉点。")
        else:
            suggestions.append("主体位置符合三分法，构图不错。")

        # 规则2：主体大小
        if area_ratio < CFG["subject"]["min_area_ratio"]:
            score -= CFG["penalty"]["too_small"]
            suggestions.append("主体占画面比例过小，建议走近一些或用变焦放大主体。")
        elif area_ratio > CFG["subject"]["max_area_ratio"]:
            score -= CFG["penalty"]["too_large"]
            suggestions.append("主体几乎占满画面，若想保留环境氛围可适当拉远。")

        # 规则3：顶部留白（主体偏上且贴顶）
        if y < h * CFG["subject"]["top_margin"]:
            score -= CFG["penalty"]["top_crowded"]
            suggestions.append("主体太贴近画面顶部，建议下移留出上方空间。")

    else:
        suggestions.append("未检测到明显主体，可检查主体是否太小或对比度不足。")

    if hor:
        ang, y_pos, seg = hor
        detected["horizon"] = (ang, y_pos, seg)

        # 规则4：地平线倾斜
        if abs(ang) > CFG["horizon"]["tilt_warn_deg"]:
            score -= CFG["horizon"]["penalty_tilt"]
            suggestions.append(f"地平线倾斜约 {abs(ang):.1f} 度，建议开启水平仪校正，保持水平线平直。")

        # 规则5：地平线位置 —— 应接近上/下三分线，避免正中
        d_top, d_bot = abs(y_pos - 1 / 3), abs(y_pos - 2 / 3)
        if min(d_top, d_bot) > CFG["horizon"]["position_tolerance"]:
            score -= CFG["horizon"]["penalty_position"]
            if abs(y_pos - 0.5) < CFG["horizon"]["position_tolerance"]:
                suggestions.append("地平线在画面正中，上下被等分显得平淡。建议按三分法放在上1/3或下1/3处。")
            else:
                suggestions.append("地平线位置偏离三分线较多，建议调整取景高度。")

    return max(0.0, score), suggestions, detected

# ---------------- 标注图绘制 ----------------
def annotate(img, detected, score):
    vis = img.copy()
    h, w = vis.shape[:2]
    # 九宫格
    for i in (1, 2):
        cv2.line(vis, (w * i // 3, 0), (w * i // 3, h), (200, 200, 200), 1)
        cv2.line(vis, (0, h * i // 3), (w, h * i // 3), (200, 200, 200), 1)
    for px, py in [(w // 3, h // 3), (2 * w // 3, h // 3), (w // 3, 2 * h // 3), (2 * w // 3, 2 * h // 3)]:
        cv2.circle(vis, (px, py), 5, (255, 200, 0), 1)

    if "yolo" in detected:
        for (ox, oy, ow, oh, oc, nm) in detected["yolo"]:
            if "main" in detected and nm == detected["main"][5] and (ox, oy, ow, oh) == detected["main"][:4]:
                cv2.putText(vis, f"{nm} {oc:.2f}", (ox + 4, max(16, oy + 4)),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 2)
            else:
                cv2.rectangle(vis, (ox, oy), (ox + ow, oy + oh), (150, 150, 110), 1)  # 其他检出物：暗黄细框

    if "faces" in detected:
        for i, (fx, fy, fw2, fh2, _conf) in enumerate(detected["faces"]):
            cv2.rectangle(vis, (fx, fy), (fx + fw2, fy + fh2), (255, 140, 0), 2)  # 蓝框=人脸
    if "subject" in detected:
        x, y, bw_, bh_, cx, cy = detected["subject"]
        cv2.rectangle(vis, (x, y), (x + bw_, y + bh_), (0, 255, 0), 2)   # 绿框=主体
        cv2.circle(vis, (int(cx), int(cy)), 4, (0, 0, 255), -1)          # 红点=质心
    if "horizon" in detected:
        ang, y_pos, (x1, y1, x2, y2) = detected["horizon"]
        cv2.line(vis, (x1, y1), (x2, y2), (0, 180, 255), 2)              # 橙线=地平线
    cv2.putText(vis, f"score: {score:.0f}", (12, 28),
                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)
    return vis

# ---------------- 主流程 ----------------
def imread_any(path: Path):
    """统一读图入口：支持 HEIC/JPG/PNG，并按 EXIF 自动转正方向"""
    try:
        pil = Image.open(path)
        pil = ImageOps.exif_transpose(pil)      # iPhone 照片按 EXIF 标记转正
        arr = np.asarray(pil.convert("RGB"))
        return cv2.cvtColor(arr, cv2.COLOR_RGB2BGR)
    except Exception:
        return cv2.imread(str(path))            # 退回 OpenCV 直接读

def process(path: Path, out_dir: Path):
    img = imread_any(path)
    if img is None:
        print(f"[跳过] 无法读取: {path}")
        return
    scale = CFG["analyze"]["long_edge"] / max(img.shape[:2])
    if scale < 1:
        img = cv2.resize(img, None, fx=scale, fy=scale)

    score, suggestions, detected = analyze(img)
    vis = annotate(img, detected, score)

    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{path.stem}_annotated.png"   # 统一存 PNG（HEIC 无法直接写回）
    cv2.imwrite(str(out_path), vis)

    print(f"\n=== {path.name} | 构图得分: {score:.0f}/100 ===")
    for i, s in enumerate(suggestions, 1):
        print(f"  {i}. {s}")
    print(f"  标注图已保存: {out_path}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target", help="图片或文件夹路径")
    ap.add_argument("-o", "--out", default=None, help="标注图输出目录(默认 output)")
    args = ap.parse_args()
    target = Path(args.target)
    out_dir = Path(args.out) if args.out else Path(__file__).parent / "output"
    files = sorted([p for p in target.glob("*") if p.suffix.lower() in
                    {".png", ".jpg", ".jpeg", ".bmp", ".webp", ".heic", ".heif"}]) if target.is_dir() else [target]
    if not files:
        print("没有找到图片文件")
        return
    for f in files:
        process(f, out_dir)

if __name__ == "__main__":
    main()
