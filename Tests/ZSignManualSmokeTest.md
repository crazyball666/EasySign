# ZSign 企业描述文件 Entitlement 验收

此验收使用真实、已获授权的 IPA、企业 p12、企业 `.mobileprovision` 和物理 iOS 设备。它验证的场景是：原 App 含 `get-task-allow=true` 和 App Group，而新企业 profile 的 `get-task-allow=false` 且不含该 App Group。

## 前置条件

- 原 IPA 的主可执行文件 entitlement 确实包含 `get-task-allow=true` 与至少一个 `com.apple.security.application-groups` 成员。
- 所选企业 profile 未包含上述 App Group，且 `get-task-allow=false`。
- p12 的叶子证书属于该 profile 的 `DeveloperCertificates`。
- 准备一个已有内容的同名最终输出 IPA，用于确认失败不会覆盖旧文件。

## 步骤

1. 在 EasySign 中选择 IPA、企业 p12 和企业 profile，后端选择 **zsign**；不手工勾选或伪造 entitlement。
2. 开始重签，观察日志必须依序包含：签前 Mach-O 检查、profile/p12 归属检查、`zsign entitlement 移除`、候选 IPA 校验、最终 IPA 输出。
3. 若任一预检、签名或校验失败，确认旧的最终 IPA 仍存在且字节未变；隐藏 `.EasySign-*.tmp.ipa` 被清理。
4. 成功后解压 IPA，检查 `Payload/*.app/embedded.mobileprovision` 与选择的 profile 字节完全一致。
5. 读取主可执行文件的 XML entitlement，并确认：
   - 没有 `get-task-allow` key；
   - 没有原 App Group claim；
   - `application-identifier`、team identifier 与新 profile 一致。
6. 安装到物理设备并启动应用；记录安装与首次启动结果。

## 记录模板

| 项目 | 结果 |
| --- | --- |
| 原 IPA SHA-256 | |
| p12 证书 SHA-1 | |
| profile UUID | |
| 输出 IPA SHA-256 | |
| 设备型号 / iOS 版本 | |
| 安装结果 | |
| 启动结果 | |
| entitlement 复核结果 | |

没有授权的真实凭据或物理设备时，此项必须标为“未验证”；自动化测试和 Debug 构建不能替代设备安装结果。
