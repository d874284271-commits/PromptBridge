# 从源码构建

需要 macOS 14+、Apple Silicon、Swift 6 工具链及 Python 3（仅开发脚本）。应用运行不依赖 Python。

```sh
swift build
swift run --skip-build DraftCoreChecks
swift run --skip-build ReleaseChecks
swift run --skip-build CLIEditorChecks
swift run --skip-build CLIIntegrationChecks
swift run --skip-build AccessibilityContractsChecks
swift run --skip-build AccessibilityRuntimeChecks
python3 Tests/DesktopPackaging/checks.py
python3 scripts/check-api.py
python3 scripts/check-models.py
```

检查使用合成数据、本地模拟服务或临时目录，不需要真实模型 Key。`swift run PromptBridge` 可用于直接输入界面开发；连接正式辅助组件需要正确签名与配套安装。

## 界面检查

```sh
python3 scripts/run-ui-checks.py Tests/PromptBridgeUITests/ui-refinement.json .build/ui-check-new
```

需要可用的桌面会话，输出目录必须尚不存在。脚本单独编译 `PROMPTBRIDGE_TESTING`，使用测试应用身份，不向真实聊天输入框写入。报告与截图一起检查。正式包不接受测试启动参数。

## 签名与打包

可在 macOS“钥匙串访问”的证书助理中创建自签名的代码签名证书。保持同一发布身份，不将私钥提交到仓库。查看证书指纹：

```sh
security find-identity -p codesigning
python3 scripts/build-desktop.py --certificate YOUR_CERTIFICATE_SHA1 --app-build 49 --component-build 21 --no-publish-current
python3 scripts/package-release.py --manifest dist/candidates/desktop-0.9.0-build49.json
```

参数接受构建者自己的 40 位 SHA-1 指纹；主应用、辅助组件和 CLI 编辑器使用同一证书。自签名身份可能显示为未获信任，这不等于 Apple Developer ID 或公证。发布时须记录首次打开和辅助权限的实机结果。

`package-release.py` 验签后生成单应用入口的 ZIP 与 SHA-256 校验文件。版本或 build 已存在时不能覆盖，请显式增加 `--app-build` / `--component-build`。

## 公开快照

```sh
python3 scripts/export-public.py --output .build/public-source
```

只复制公开清单中的文件，排除本机配置、签名配置、构建产物和历史执行记录，并检查敏感内容。不复制原 `.git`；输出不会覆盖已有目录。正式发布前从该快照重新构建。

CI 在 macOS runner 上构建并检查核心行为。签名发布工作流需要维护者配置私有签名材料；普通 PR 不接触签名密钥。源码测试通过不等于真实宿主和冷安装已验收。
