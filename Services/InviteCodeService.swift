import Foundation

/// 邀请码服务（兼容层，转发到 `ScaffoldingInviteCode`）。
///
/// 历史上 CraftLink 用自定义的 `U/XXXX-XXXX-XXXX-XXXX` 格式（4 段 × 4 字符，含 I/O），
/// 与 HMCL/FCL/ZL2 的 Scaffolding-MC 标准 `U/NNNN-NNNN-SSSS-SSSS` 格式**不兼容**。
/// 现已切换到 Scaffolding-MC 标准格式以实现跨启动器互通。
///
/// 本结构保留旧方法签名（`generate` / `isValid` / `networkName`），
/// 内部全部委托给 `ScaffoldingInviteCode`，确保现有调用方无需改动。
struct InviteCodeService {

    /// 生成新的 Scaffolding-MC 邀请码字符串。
    static func generate() -> String {
        return ScaffoldingInviteCode.generate().code
    }

    /// 校验邀请码字符串是否合法（格式 + 被 7 整除校验）。
    static func isValid(_ code: String) -> Bool {
        return ScaffoldingInviteCode.isValid(code)
    }

    /// 从邀请码提取 EasyTier `network_name`（保留向后兼容）。
    /// - Note: 新代码应直接用 `ScaffoldingInviteCode.parse(code)?.networkName`。
    static func networkName(from code: String) -> String {
        return ScaffoldingInviteCode.parse(code)?.networkName ?? ""
    }

    /// 从邀请码提取 EasyTier `network_secret`。
    static func networkSecret(from code: String) -> String {
        return ScaffoldingInviteCode.parse(code)?.networkSecret ?? ""
    }

    /// 解析邀请码为结构化对象。
    static func parse(_ code: String) -> ScaffoldingInviteCode? {
        return ScaffoldingInviteCode.parse(code)
    }
}
