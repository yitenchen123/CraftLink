import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SilentAudioPlayer
//
// iOS 上 Terracotta 的 EasyTier 是普通用户态进程，App 退到后台会被系统冻结，虚拟
// 网络随即断开。解决办法是利用 `AVAudioSessionCategoryPlayback` + `UIBackgroundModes:
// audio`：循环播放一段几乎无声的音频，让系统认为 App 在播音乐，从而允许它继续在
// 后台运行（与 POJAV Launcher / 等游戏保活策略一致）。
//
// 关键点：
//   1. Info.plist 必须声明 `UIBackgroundModes: [audio]`。
//   2. AVAudioSession category 必须是 `.playback`，且 `setActive(true)` 成功。
//   3. 音频文件需为真实 PCM（不能是 0 字节）。我们用 200ms 的近静音 WAV，循环播放。
//   4. App 进入后台时启动播放；回到前台不停止（继续放也无副作用）。

final class SilentAudioPlayer: NSObject {

    static let shared = SilentAudioPlayer()

    private var player: AVAudioPlayer?
    /// 是否已成功配置 AVAudioSession（避免每次启动都重新 setCategory）。
    private var sessionConfigured = false
    /// 当前是否处于「保活中」状态。
    private(set) var isKeepingAlive = false

    private override init() {
        super.init()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        #endif
    }

    /// 启动后台保活。Idempotent。
    /// - Returns: true 表示音频会话已激活、循环播放开始；false 表示权限/配置失败。
    @discardableResult
    func startKeepingAlive() -> Bool {
        guard !isKeepingAlive else { return true }

        if !sessionConfigured {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: [.mixWithOthers, .duckOthers]
                )
                try session.setActive(true, options: [])
                sessionConfigured = true
            } catch {
                NSLog("[SilentAudioPlayer] AVAudioSession 配置失败: \(error)")
                return false
            }
        }

        guard let url = Self.silentAudioURL else {
            NSLog("[SilentAudioPlayer] 静音音频文件不存在")
            return false
        }

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1  // 无限循环
            p.volume = 0.01       // 几乎无声，但 > 0 才能让系统认为「在播」
            if !p.prepareToPlay() {
                NSLog("[SilentAudioPlayer] prepareToPlay 失败")
                return false
            }
            if !p.play() {
                NSLog("[SilentAudioPlayer] play 失败")
                return false
            }
            player = p
            isKeepingAlive = true
            NSLog("[SilentAudioPlayer] 后台保活已启动")
            return true
        } catch {
            NSLog("[SilentAudioPlayer] 创建播放器失败: \(error)")
            return false
        }
    }

    /// 停止后台保活（房间关闭时调用）。Idempotent。
    func stopKeepingAlive() {
        guard isKeepingAlive else { return }
        player?.stop()
        player = nil
        // 不主动 setActive(false)，避免打断其他 App 的音频。
        isKeepingAlive = false
        NSLog("[SilentAudioPlayer] 后台保活已停止")
    }

    // MARK: - 中断处理

    /// 系统来电 / 闹钟等中断后，尝试恢复播放。
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            // 系统打断（如电话），播放器会被自动暂停
            NSLog("[SilentAudioPlayer] 音频被打断")
        case .ended:
            // 打断结束，尝试恢复
            if isKeepingAlive {
                NSLog("[SilentAudioPlayer] 打断结束，尝试恢复保活")
                _ = startKeepingAlive()
            }
        @unknown default:
            break
        }
    }

    // MARK: - 静音音频资源
    //
    // 用代码生成一段 200ms、单声道、16-bit、44100Hz 的近静音 WAV 写到 tmp 目录，
    // 避免在 App bundle 里塞二进制文件。每次启动检查文件是否存在，存在就复用。

    private static let silentAudioURL: URL? = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("craftlink_silent.wav")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return generateSilentWAV(at: url) ? url : nil
    }()

    /// 生成 200ms 的近静音 WAV（含最小可听的低幅值正弦波，避免某些 iOS 版本把「全零」视为静音并暂停后台播放）。
    private static func generateSilentWAV(at url: URL) -> Bool {
        let sampleRate: UInt32 = 44100
        let durationMs: UInt32 = 200
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let numSamples = sampleRate * durationMs / 1000
        let dataSize = numSamples * UInt32(channels) * UInt32(bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = UInt16(channels) * (bitsPerSample / 8)

        var data = Data()
        // RIFF header
        data.append("RIFF".data(using: .ascii)!)
        appendUInt32(&data, 36 + dataSize)  // ChunkSize
        data.append("WAVE".data(using: .ascii)!)
        // fmt subchunk
        data.append("fmt ".data(using: .ascii)!)
        appendUInt32(&data, 16)              // Subchunk1Size
        appendUInt16(&data, 1)               // AudioFormat = PCM
        appendUInt16(&data, channels)
        appendUInt32(&data, sampleRate)
        appendUInt32(&data, byteRate)
        appendUInt16(&data, blockAlign)
        appendUInt16(&data, bitsPerSample)
        // data subchunk
        data.append("data".data(using: .ascii)!)
        appendUInt32(&data, dataSize)

        // 写入近静音正弦波（频率 50Hz，幅度 100/32767 ≈ -50dB）
        let frequency: Double = 50.0
        let amplitude: Double = 100.0
        for i in 0..<numSamples {
            let t = Double(i) / Double(sampleRate)
            let sample = Int16(amplitude * sin(2.0 * .pi * frequency * t))
            appendUInt16(&data, UInt16(bitPattern: sample))
        }

        do {
            try data.write(to: url)
            return true
        } catch {
            NSLog("[SilentAudioPlayer] 写入静音 WAV 失败: \(error)")
            return false
        }
    }

    private static func appendUInt16(_ data: inout Data, _ v: UInt16) {
        data.append(UInt8(v & 0xff))
        data.append(UInt8((v >> 8) & 0xff))
    }

    private static func appendUInt32(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8(v & 0xff))
        data.append(UInt8((v >> 8) & 0xff))
        data.append(UInt8((v >> 16) & 0xff))
        data.append(UInt8((v >> 24) & 0xff))
    }
}
