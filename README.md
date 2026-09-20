# 掌上教务（PalmAcademic）

一个基于 Jetpack Compose + Material 3 的 Android 教务客户端。项目通过“学校配置 + JavaScript 阅读适配器”隔离不同学校的域名、菜单、页面 DOM 与作息时间，不需要为每所学校复制 Android UI。

## 功能

- 历史会话可用时直接进入首页，并在后台验证登录状态。
- 支持账号密码登录和应用内网页登录。
- 课表、成绩、考试、培养方案等页面可转换为原生 Material 界面；其他入口直接显示学校官网页面。
- 课表可导出 iCalendar、WakeUp CSV 和 JSON。
- WorkManager 后台检测课表、成绩与考试变化，并可选择启用常驻通知保活。
- 学校选择为独立页面，可从本仓库动态刷新学校配置和阅读适配器。
- 在设置中通过 GitHub Releases 检查新版本并下载 APK。
- 支持浅色、深色和跟随系统主题。

## 学校适配

完整规范见 [学校适配指南](docs/ADAPTER_GUIDE.md)。新增学校通常只需要：

1. 在 `app/src/main/assets/schools/index.json` 注册学校、域名和作息时间。
2. 新增 `schools/<school>.json`，声明菜单入口及哪些页面使用原生重绘。
3. 新增或复用 `adapters/<school>-reader.js`，通过 `PalmAcademicHost.publish()` 发布结构化页面。
4. 务必配置 `readerConfig.scheduleProfiles[].unitTimes`；缺少时间会导致课表看似正常，但导出的日历/WakeUp 文件没有正确的上课时间。

App 的学校页面会从以下仓库目录检查更新：

- `app/src/main/assets/schools/`
- `app/src/main/assets/adapters/`

远程文件会经过 HTTPS、路径、大小、JSON schema 和适配器引用校验，并保存到 App 私有目录；更新失败时继续使用 APK 内置版本。

## 构建

需要 Android SDK、JDK 17 和网络连接：

```powershell
.\gradlew.bat assembleDebug
```

Debug 和 Release 均连接学校正式教务地址。Debug APK 位于 `app/build/outputs/apk/debug/app-debug.apk`。

Release 签名配置不进入仓库。复制 `signing.properties.example` 为 `signing.properties`，填写本机密钥信息后运行：

```powershell
.\gradlew.bat assembleRelease
```

## 在线更新

- 学校适配：读取 GitHub 仓库 `main` 分支中上述 assets 目录。
- App 版本：读取 `Genkaim/palm-academic` 的 latest Release；版本标签使用 `v<versionName>`，例如 `v0.3.0`。
- Release 中建议附加一个 `.apk` 文件，App 会优先打开该资产的下载地址；没有 APK 时打开 Release 页面。

## 注意事项

- 部分学校的教务系统仅允许校园网或学校 VPN 访问，App 无法绕过网络访问限制。
- Android 周期后台任务最短间隔为 15 分钟，实际执行时间还会受到系统省电策略影响。
- App 不能读取系统 Chrome 的 Cookie；网页登录必须在应用内完成。
- 远程 JavaScript 适配器会在已登录的教务 WebView 内运行，因此 App 只信任代码中固定的官方仓库。
