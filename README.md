# VNT GUI

VNT GUI

> **对于本项目你可以问问 <a href="https://deepwiki.com/lmq8267/vntAPP"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki"></a> 来了解功能或 `Frok` 后简单的修改一些功能，修改后github可以自动打包好**

## Build

### Install

After [Flutter](https://docs.flutter.dev/get-started/install) and [Rust](https://www.rust-lang.org/tools/install) are installed, install `flutter_rust_bridge`

### Run
```
flutter run
```


## iOS 项目配置与编译

本项目 iOS 侧已去除硬编码标识，改为通过工程变量注入。默认占位值可直接编译模拟器，真机发布前请替换为你自己的标识。

### 1) 配置标识变量
仓库中的以下文件是公开占位值：
- [ios/Flutter/Debug.xcconfig](ios/Flutter/Debug.xcconfig)
- [ios/Flutter/Release.xcconfig](ios/Flutter/Release.xcconfig)

本地请创建私有覆盖文件（不会提交）：
1. 复制 [ios/Flutter/Private.xcconfig.example](ios/Flutter/Private.xcconfig.example) 为 `ios/Flutter/Private.xcconfig`
2. 将真实标识写入 `Private.xcconfig`

关键变量：
- `APP_BUNDLE_ID`：主 App 包名（例如 `com.yourcompany.vntapp`）
- `APP_EXTENSION_BUNDLE_ID`：扩展包名（独立配置，不要求与主包名存在拼接关系）
- `TEST_BUNDLE_ID`：测试包名（默认 `$(APP_BUNDLE_ID).RunnerTests`）
- `APP_GROUP_ID`：App Group（例如 `group.com.yourcompany.vntapp.shared`）

### 2) 签名与能力
在 Xcode 中打开 [ios/Runner.xcworkspace](ios/Runner.xcworkspace)：
- 为 `Runner` 与 `PacketTunnelExtension` 选择同一 Team
- 确认两者都启用 `App Groups`
- 确认两者的 `App Groups` 值一致，并与 `APP_GROUP_ID` 对应
- 确认扩展启用 `Network Extensions`（Packet Tunnel）

### 3) 编译命令
```bash
flutter pub get
cd ios && pod install && cd ..
flutter build ios --simulator --debug
# 真机包（本地签名）
flutter build ios --debug
```

### 4) 说明
- `Info.plist` 与 `entitlements` 均使用变量（如 `$(APP_GROUP_ID)`）注入，不再在代码中硬编码你的私有标识。
- `ios/Flutter/Private.xcconfig` 已加入 `.gitignore`，将真实标识放在该文件不会上传到 git。
- 若仅做联调，可先使用默认占位值；上架或分发前必须替换为真实标识并完成签名。

## Special

Thanks to ChatGPT for helping with a lot of the work on this project.



