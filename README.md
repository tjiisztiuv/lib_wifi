# 图书馆 Wi-Fi 自动登录 (macOS)

一个原生 macOS 桌面窗口应用，用于在连接图书馆/校园网开放 Wi-Fi 后自动探测网页认证（Captive Portal）并填入账号密码提交登录。

## 功能特点

- **自动触发**：支持在打开 App 时、或检测到 Wi-Fi 切换/重新上线时自动检测并提交认证。
- **动态捕获真实认证页**：通过探测 `http://captive.apple.com/hotspot-detect.html` 捕获网关重定向（HTTP 302、HTML Meta 跳转或 JS 跳转），无需预先写死认证页参数。
- **内置网页自动填表引擎**：使用 `WKWebView` 自动识别账号输入框、密码输入框和登录按钮（支持常规表单及 React/Vue 等现代前端页面），并安全处理内网自签名 HTTPS 证书。
- **macOS 钥匙串存储**：账号密码安全保存于系统 Keychain。
- **一键连接目标 Wi-Fi**：可填写目标 Wi-Fi 名称（SSID），支持直接切换到对应 Wi-Fi 并执行认证。
- **可展开调试预览**：支持在窗口内展开内置网页视图，查看当前实际捕获到的认证页 URL，也可自定义 CSS 选择器适配特殊页面。

## 编译与打包

```zsh
./scripts/build_app.sh
```

打包产物位于：

```text
build/LibWiFiAutoLogin.app
build/LibWiFiAutoLogin-macOS-Universal.zip
```

脚本会编译 `arm64 + x86_64` Universal 通用架构（兼容 Apple Silicon 与 Intel Mac），并生成可直接分发的 `.zip` 压缩包。可直接双击 `.app` 运行，或拖入 `/Applications` 使用。
