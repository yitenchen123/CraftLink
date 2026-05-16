# CraftLink

Minecraft 跨平台联机 iOS 客户端，兼容 HMCL / PCL-CE / FCL / ZL2 陶瓦联机协议。

## 自动构建

推送 `v*` 标签（如 `v1.0.0`）后，GitHub Actions 会自动生成未签名 IPA。

## 安装

1. 从 Releases 下载 `CraftLink.ipa`
2. 使用 AltStore / SideStore / TrollStore 安装
3. 首次打开允许 VPN 配置

## 手动构建

```bash
brew install xcodegen
xcodegen generate
xcodebuild build -project CraftLink.xcodeproj -scheme CraftLink -sdk iphoneos CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO