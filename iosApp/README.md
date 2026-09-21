# 原生 iOS 迁移预览

此目录是从 Android 客户端迁移出的 SwiftUI 原生 iOS 版本，不再使用 WKWebView。登录、学校选择、门户分组和结构化页面请求使用原生 SwiftUI + URLSession 实现。

## 编译

在 GitHub Actions 中手动运行 **Build native iOS migration**，或将代码推送到 `ios-native-rewrite` 分支后自动触发。工作流使用 macOS、XcodeGen 和 Xcode 生成未签名的 iPhoneOS IPA。推送 `v0.3.6` 标签会在编译成功后自动创建预发布 Release。

生成的 IPA 仍需要 Apple 开发者证书签名或侧载工具重签名才能安装。

## 测试声明

此迁移版本目前只完成源代码和 GitHub macOS 编译验证，**没有经过实体 iPhone 或 iPad 实机测试**。在真实设备上安装前，请重点验证校园网/VPN 访问、登录 Cookie、学校切换、页面解析、横竖屏和后台行为。
