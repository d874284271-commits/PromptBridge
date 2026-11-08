# 架构

PromptBridge 把“生成译文”和“访问外部输入框”分开：主应用管理界面、模型与草稿，独立组件持有辅助功能权限，CLI 编辑器负责文件交接。

| 部分 | 职责 |
| --- | --- |
| DraftCore | 草稿状态、模型协议、配置、CLI 文件与安装事务 |
| PromptBridge | 原生浮窗、模型设置、用户级安装入口、CLI 状态 |
| AccessibilityContracts | IPC 3、签名身份、请求与响应校验 |
| AccessibilityRuntime / AccessibilityBroker | 当前输入目标、读取、单次替换、恢复、Terminal 定位 |
| promptbridge-editor | CLI editor 2 文件交接和启动透传 |

运行时按当前操作能力尝试接入。权限、目标身份、内容一致性和单次操作规则仍然检查，宿主版本仅作为证据。核心决策见 [运行时接入](adr/0007-runtime-integration-capabilities.md)与 [Auto](adr/0008-one-click-auto.md)。

主应用和组件从实际代码签名取得证书身份，再校验对端 bundle、同签名要求和用户身份；配置文件中的指纹不能单独授予信任。自签名用于应用组合的身份校验，不代表 Apple 公证。

测试构建通过 `PROMPTBRIDGE_TESTING` 包含合成宿主和验收执行器。发布构建不解析这些测试参数，也不包含演示翻译回退。
