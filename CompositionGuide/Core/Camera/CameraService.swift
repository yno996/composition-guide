import AVFoundation
import UIKit

/// 相机服务：AVCaptureSession 生命周期管理
/// 职责：开启预览视频流（按 frameSampleMs 抽帧回调）+ 拍照输出
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    enum CameraError: LocalizedError {
        case cameraUnavailable
        case configurationFailed
        var errorDescription: String? {
            switch self {
            case .cameraUnavailable: return "无法访问相机（权限或硬件问题）"
            case .configurationFailed: return "相机配置失败"
            }
        }
    }

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let frameQueue = DispatchQueue(label: "compositionguide.frames", qos: .userInitiated)
    private var sampleInterval: TimeInterval = 0.3
    private var lastAnalysisTimestamp: TimeInterval = -1

    /// 抽帧回调：仅当距上次回调超过 sampleInterval 才触发（约3fps，省电关键）
    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?

    /// 配置相机。必须在有相机权限后调用（Info.plist 需含 NSCameraUsageDescription）
    func configure(frameSampleMs: Int) throws {
        sampleInterval = TimeInterval(frameSampleMs) / 1000.0

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            throw CameraError.cameraUnavailable
        }
        session.addInput(input)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true     // 丢帧优于卡顿
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraError.configurationFailed }
        session.addOutput(videoOutput)

        guard session.canAddOutput(photoOutput) else { throw CameraError.configurationFailed }
        session.addOutput(photoOutput)
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// 拍照。相机预览保持运行；结果通过回调返回（主线程）
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        let delegate = PhotoCaptureDelegate(completion: completion)
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard ts - lastAnalysisTimestamp >= sampleInterval else { return }
        lastAnalysisTimestamp = ts
        // TODO(M4): 根据 UIDevice.current.orientation 传入真实方向，先按竖屏处理
        onFrame?(pixelBuffer, .portrait)
    }
}

/// 拍照回调转发（AVFoundation 的 delegate 是单次对象）
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?) -> Void
    init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = error == nil ? UIImage(data: photo.fileDataRepresentation() ?? Data()) : nil
        DispatchQueue.main.async { [completion] in completion(image) }
    }
}
