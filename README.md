# 掌上教务（PalmAcademic）

掌上教务是一个同时支持 Android 与 iOS 的教务客户端。项目用“学校定义 JSON + 独立 JavaScript 阅读适配器”描述学校差异，两端共用同一套菜单、登录、页面读取、后台检查和作息配置。

## 主要功能

- 支持账号密码、验证码密码、应用内网页三类登录流程，并复用已登录会话。
- 普通入口直接在应用内打开学校网页；课表、成绩、考试、培养方案可显示为原生界面。
- 登录后自动预取原生重绘页面并建立后台比较基线；命中缓存时立即显示旧数据，同时在后台刷新。
- Cookie 过期时按登录类型处理：无验证码密码登录静默重试；验证码登录发出通知并等待用户输入；网页登录引导返回登录页。
- 后台检查课表、成绩和考试变化，并发送系统通知。
- 课表可导出为 iCalendar、WakeUp CSV 和 JSON。
- 支持浅色、深色和跟随系统主题，可从 GitHub 检查应用更新与学校规则更新。
- 支持本地导入学校 JSON 与适配器 JS；导入相同 ID 时可确认覆盖，便于真机调试。

## 使用现有学校

在学校选择页选择学校并登录即可。学校系统若只允许校园网或 VPN 访问，设备也必须处于相应网络环境；应用不会绕过学校的访问限制。

普通页面由内置 WebView 加载，无法读取系统浏览器的 Cookie。需要网页登录时，请在应用内完成登录。

## 新增或调试学校适配

推荐先做本地适配，再提交到仓库：

1. 从 `examples/local-adapters/` 复制一组 JSON 与 JS 示例。
2. 在 JSON 中配置学校地址、登录方式、普通入口、四个原生重绘入口和后台检查地址。
3. 在 JS 中读取当前页面，并通过 `PalmAcademicHost.publish()` 发布结构化数据。
4. 在 Android 或 iOS 的学校选择页依次导入 JSON、JS；修改后用相同 ID 再次导入并确认覆盖。
5. 两端验证登录、普通网页、四个重绘页面、缓存刷新和 Cookie 过期行为。
6. 运行校验器，通过后再同步到内置资源并提交 Pull Request。

完整字段、示例和验收清单见 [学校适配指南](docs/ADAPTER_GUIDE.md)。协作约定见 [贡献指南](CONTRIBUTING.md)。

```powershell
node tools/validate-adapters.mjs
```

## 项目结构

```text
app/                         Android 客户端
iosApp/                      iOS 客户端
app/src/main/assets/
  schools/                   内置学校索引与定义
  adapters/                  内置阅读适配器
iosApp/Resources/
  schools/                   iOS 随包学校资源
  adapters/                  iOS 随包阅读适配器
examples/local-adapters/     可直接导入的本地测试示例
docs/ADAPTER_GUIDE.md        最新适配流程与字段说明
tools/validate-adapters.mjs  适配配置校验器
```

在线更新从仓库 `main` 分支的 `app/src/main/assets/` 读取。下载失败或配置校验失败时，应用继续使用上一次可用版本或随包版本。远程适配器只接受本仓库固定来源，并在已登录的学校 WebView 中运行。

## 构建 Android

需要 JDK 17、Android SDK 和项目依赖所需的网络连接。

```powershell
.\gradlew.bat assembleDebug
```

Debug APK 输出到 `app/build/outputs/apk/debug/app-debug.apk`。

Release 签名信息不进入仓库。复制 `signing.properties.example` 为 `signing.properties`，填写本机密钥后运行：

```powershell
.\gradlew.bat assembleRelease
```

## 构建 iOS

本地构建需要 macOS、Xcode 与 XcodeGen：

```bash
cd iosApp
xcodegen generate
```

随后可用生成的 `PalmAcademicIOS.xcodeproj` 在 Xcode 中运行或归档。仓库也提供以下 GitHub Actions：

- `Build unsigned iOS IPA`：生成未签名 IPA，安装前必须重签名。
- `Build signed iOS IPA (macOS, Liquid Glass)`：使用新版本 Xcode SDK 构建并生成临时签名产物。
- `Build signed iOS IPA (developer certificate)`：使用仓库密钥中的证书和描述文件生成设备可安装 IPA。

## 发布与更新

- 学校适配更新：提升 `app/src/main/assets/schools/index.json` 的 `configVersion`，并保持 Android、iOS 随包资源一致。
- 应用更新：发布 GitHub Release，标签使用 `v<version>`，例如 `v0.4.7`。
- Android Release 建议附加 `.apk`；客户端优先打开安装包资产，没有匹配资产时打开 Release 页面。
- iOS 客户端同样检查 latest Release，但安装方式取决于签名和分发渠道。

## 安全边界

- 适配器应只读取页面或学校官方只读接口，不得代替用户选课、退课、评教、提交申请或执行其他写操作。
- 不要把账号、密码、Cookie、Token、私钥或真实学生数据写入配置、脚本、日志和提交记录。
- 新域名、登录链路或 Cookie 范围应保持最小化，并在 Android 与 iOS 真机上分别验证。
