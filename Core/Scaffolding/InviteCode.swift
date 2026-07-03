import Foundation
import Security

/// Scaffolding-MC 协议邀请码（与 HMCL 3.7.0.300+ / FCL / ZL2 完全互通）。
///
/// 邀请码格式：`U/NNNN-NNNN-SSSS-SSSS`
/// - `U/` 是固定前缀
/// - `NNNN-NNNN` 是 8 个字符的网络名种子
/// - `SSSS-SSSS` 是 8 个字符的网络密钥
/// - 字符集：`0-9 A-H J-N P-Z`（共 34 个字符，去掉 I 和 O 防止与 1/0 混淆）
/// - 校验：N 段和 S 段各自按"小端序"映射成整数后必须能被 7 整除
///
/// 映射到 EasyTier：
/// - `network_name` = `scaffolding-mc-NNNN-NNNN`
/// - `network_secret` = `SSSS-SSSS`
/// - 房主 `hostname` = `scaffolding-mc-server-{port}`（port 为 MC 服务器端口）
public struct ScaffoldingInviteCode: Equatable, Hashable, CustomStringConvertible {

    /// 邀请码字符表：`0-9 A-H J-N P-Z`（34 个字符，去掉 I 和 O）。
    /// 索引即字符的数值：'0'→0, '9'→9, 'A'→10, 'H'→17, 'J'→18, 'N'→22, 'P'→23, 'Z'→33
    public static let alphabet = Array("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    /// 固定前缀 `U/`，标识 Scaffolding-MC 房间码。
    public static let prefix = "U/"

    /// 段间分隔符 `-`。
    public static let groupSeparator: Character = "-"

    /// 共 4 段（2 段网络名 + 2 段密钥）。
    public static let groupCount = 4

    /// 每段 4 字符。
    public static let groupLength = 4

    /// 网络名种子段数（前 2 段）。
    public static let networkSeedGroupCount = 2

    /// 密钥段数（后 2 段）。
    public static let secretGroupCount = 2

    /// 网络名种子，形如 `NNNN-NNNN`（含中间连字符）。
    public let networkSeed: String

    /// 网络密钥，形如 `SSSS-SSSS`（含中间连字符）。
    public let secret: String

    public init(networkSeed: String, secret: String) {
        self.networkSeed = networkSeed
        self.secret = secret
    }

    /// 完整邀请码字符串，与 HMCL/FCL 生成的格式完全一致。
    public var description: String {
        return "\(ScaffoldingInviteCode.prefix)\(networkSeed)\(ScaffoldingInviteCode.groupSeparator)\(secret)"
    }

    /// 完整邀请码字符串（`description` 的别名）。
    public var code: String { description }

    /// 映射到 EasyTier `--network-name`：`scaffolding-mc-NNNN-NNNN`。
    public var networkName: String {
        return "scaffolding-mc-\(networkSeed)"
    }

    /// 映射到 EasyTier `--network-secret`：`SSSS-SSSS`。
    public var networkSecret: String {
        return secret
    }

    /// 房主在 EasyTier 网络中的 hostname：`scaffolding-mc-server-{port}`。
    /// - Note: 调用方需保证 `1024 < port <= 65535`。
    public static func serverHostname(mcPort: UInt16) -> String {
        return "scaffolding-mc-server-\(mcPort)"
    }

    /// 用密码学安全的随机源生成新的合法邀请码。
    public static func generate() -> ScaffoldingInviteCode {
        let networkSeedFull = randomValidSegment()
        let secretFull = randomValidSegment()
        let networkSeed = insertSeparator(networkSeedFull)
        let secret = insertSeparator(secretFull)
        return ScaffoldingInviteCode(networkSeed: networkSeed, secret: secret)
    }

    /// 解析邀请码字符串。严格要求 `U/NNNN-NNNN-SSSS-SSSS` 格式 + 被7整除校验。
    /// - Parameter code: 用户输入的邀请码（自动大写、忽略首尾空白）。
    public static func parse(_ code: String) -> ScaffoldingInviteCode? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.hasPrefix(prefix) else { return nil }
        let body = String(trimmed.dropFirst(prefix.count))
        let parts = body.split(separator: groupSeparator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == groupCount else { return nil }
        for p in parts {
            guard p.count == groupLength else { return nil }
            for ch in p where !alphabet.contains(ch) { return nil }
        }
        let networkSeedFull = parts[0] + parts[1]
        let secretFull = parts[2] + parts[3]
        guard isSegmentDivisibleBy7(networkSeedFull),
              isSegmentDivisibleBy7(secretFull) else { return nil }
        let networkSeed = parts[0] + String(groupSeparator) + parts[1]
        let secret = parts[2] + String(groupSeparator) + parts[3]
        return ScaffoldingInviteCode(networkSeed: networkSeed, secret: secret)
    }

    /// 快速判断字符串是否是合法的 Scaffolding-MC 邀请码。
    public static func isValid(_ code: String) -> Bool {
        return parse(code) != nil
    }

    // MARK: - Private helpers

    /// 生成 8 字符随机段，循环重试直到整段被 7 整除。
    private static func randomValidSegment() -> String {
        while true {
            var chars: [Character] = []
            for _ in 0..<(groupLength * 2) {
                chars.append(randomChar())
            }
            let segment = String(chars)
            if isSegmentDivisibleBy7(segment) {
                return segment
            }
        }
    }

    /// 用 `SecRandomCopyBytes` 取 1 字节随机数映射到字母表，失败时回退到 `SystemRandomNumberGenerator`。
    private static func randomChar() -> Character {
        var byte: UInt8 = 0
        let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
        if status != errSecSuccess {
            byte = UInt8.random(in: 0...UInt8.max)
        }
        return alphabet[Int(byte) % alphabet.count]
    }

    /// 在 8 字符段中间插入分隔符：`ABCDEFGH` → `ABCD-EFGH`。
    private static func insertSeparator(_ segment: String) -> String {
        let mid = segment.index(segment.startIndex, offsetBy: groupLength)
        return String(segment[..<mid]) + String(groupSeparator) + String(segment[mid...])
    }

    /// 把 8 字符段按"小端序"映射成 Int64：第 0 字符是最低位。
    /// value = sum(alphabet.indexOf(ch) * 34^i, i=0..7)
    private static func segmentToLittleEndianValue(_ segment: String) -> Int64? {
        guard segment.count == groupLength * 2 else { return nil }
        var value: Int64 = 0
        var multiplier: Int64 = 1
        let base = Int64(alphabet.count)
        for ch in segment {
            guard let digit = alphabet.firstIndex(of: ch) else { return nil }
            value += Int64(digit) * multiplier
            multiplier *= base
        }
        return value
    }

    private static func isSegmentDivisibleBy7(_ segment: String) -> Bool {
        guard let v = segmentToLittleEndianValue(segment) else { return false }
        return v % 7 == 0
    }
}
