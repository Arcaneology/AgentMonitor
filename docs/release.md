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

产物位于 `/tmp/AgentMonitorDerivedData/Build/Products/Debug/AgentMonitor.app`。可将它复制到 `~/Applications` 后启动；首次运行不会请求管理员权限。

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
