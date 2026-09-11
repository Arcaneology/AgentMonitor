# Agent Monitor 发布说明

项目要求 macOS 14+，使用 Hardened Runtime，关闭 App Sandbox，不安装特权 helper。开发构建可以不签名；对外分发必须使用 Apple Developer ID 签名并完成公证。

## 本机开发构建

```bash
xcodebuild \
  -project AgentMonitor.xcodeproj \
  -scheme AgentMonitor \
  -configuration Debug \
  -derivedDataPath /tmp/AgentMonitorDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

产物位于 `/tmp/AgentMonitorDerivedData/Build/Products/Debug/AgentMonitor.app`。`Release` 构建成功后会自动覆盖安装到 `/Applications/AgentMonitor.app`；首次运行不会请求管理员权限。当前日常使用的就是 `/Applications` 里这份应用，安装后需要重新打开它才会加载新版本。

## Developer ID 归档

将 `YOUR_TEAM_ID` 替换为 Apple Developer Team ID，并确保钥匙串中已有对应的 “Developer ID Application” 证书：

```bash
xcodebuild \
  -project AgentMonitor.xcodeproj \
  -scheme AgentMonitor \
  -configuration Release \
  -archivePath build/AgentMonitor.xcarchive \
  DEVELOPMENT_TEAM="YOUR_TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  archive
```

签名后的应用位于 `build/AgentMonitor.xcarchive/Products/Applications/AgentMonitor.app`。提交前先验证：

```bash
codesign --verify --deep --strict --verbose=2 \
  build/AgentMonitor.xcarchive/Products/Applications/AgentMonitor.app
```

## 公证与装订票据

先在钥匙串保存一次公证凭据：

```bash
xcrun notarytool store-credentials AgentMonitor-notary \
  --apple-id "developer@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "YOUR_APP_SPECIFIC_PASSWORD"
```

然后压缩、提交、公证并装订票据：

```bash
ditto -c -k --keepParent \
  build/AgentMonitor.xcarchive/Products/Applications/AgentMonitor.app \
  build/AgentMonitor.zip

xcrun notarytool submit build/AgentMonitor.zip \
  --keychain-profile AgentMonitor-notary \
  --wait

xcrun stapler staple \
  build/AgentMonitor.xcarchive/Products/Applications/AgentMonitor.app

xcrun stapler validate \
  build/AgentMonitor.xcarchive/Products/Applications/AgentMonitor.app

spctl --assess --type execute --verbose=4 \
  build/AgentMonitor.xcarchive/Products/Applications/AgentMonitor.app
```

装订后重新生成最终分发压缩包，确保离线 Gatekeeper 验证也能找到公证票据。

当前仓库已验证未签名 Release 构建；Developer ID 签名与 Apple 公证尚未执行，因为它们需要发布者自己的证书和 Apple 凭据。

## 本机替换与回退

Release 安装脚本会先将完整应用写入临时目录，确认可执行文件存在后，正常退出正在运行的旧实例，再替换安装。旧版本保留在构建日志输出的 `/Applications/.AgentMonitor-install.*/AgentMonitor.previous.app` 路径；失败会尝试恢复原位置。安装不再自动切换前台，完成后重新打开应用。

2026-09-12：新版 Release 构建及安装成功，安装后再次验证完整 106 项测试通过。旧应用备份保留。Token 数据库在首次打开用量面板、触发刷新时自动备份并迁移；此前的副本核验和详细结果见 Token 验收说明。
