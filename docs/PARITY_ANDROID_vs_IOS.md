# Android / iOS 功能对照

对比基准：`app/src/main`（Android，v0.4.5 正式客户端）与 `iosApp/Sources`（iOS，实验原型）。
方法：关键字命中数 + 源码结构核对，不含真机跑通验证。

## 一、总览

| 能力 | Android | iOS | 差异 |
|---|---|---|---|
| 底部导航 | LiquidBottomTabs（4 项） | LiquidTabBar（首页/快捷/记录/设置） | 一致 |
| 账号密码登录 | 有 | 有 | 一致 |
| 应用内网页登录 | WebView | WKWebView | 一致 |
| 课表/成绩/考试/培养方案原生重绘 | 12/13/12/6 文件 | 3/3/3/2 文件 | **iOS 覆盖明显偏薄** |
| 学校配置 GitHub 动态刷新 | 有 | 有 | 一致 |
| 学校选择独立页 | 有 | 有 | 一致 |
| 后台检查 | WorkManager（6 处） | BGTaskScheduler（5 处） | 一致，间隔同为 15/30/60/180 分钟 |
| 变更通知 | NotificationManager（15 处） | UNUserNotificationCenter（8 处） | 一致，均含课表/成绩/考试/培养四类开关 |
| 检查更新 | `releases/latest` | `latestRelease` | 一致 |
| 快捷入口 | QuickEntry（17 处） | quickEntry（14 处） | 一致 |

## 二、iOS 缺失项

### 1. 课表导出（Android 独有）

Android 支持三种导出格式，iOS 端完全没有对应实现：

- **iCalendar**（`BEGIN:VCALENDAR`）：Android `app/src/main` 命中，iOS **0**
- **WakeUp CSV**：Android 10 处，iOS **0**
- **JSON**：随上述导出一并提供，iOS 无

iOS 侧 `iosApp/Sources` 全文检索 `导出` / `export` / `ShareLink` / `.ics`，只命中 `shared`、
`SchoolCatalog.shared` 这类同名子串，无任何导出入口或 `UIActivityViewController` 分享封装。

### 2. 主题缺「跟随系统」态

Android 是三态枚举：

```kotlin
enum class PortalThemeMode(val storedValue: String, val displayName: String) {
    SYSTEM("system", "跟随系统"),
    LIGHT("light", "浅色"),
    DARK("dark", "深色");
}
```

iOS 是二值布尔 + 强制指定外观：

```swift
@Published var isDark = false
// PalmAcademicApp.swift:14
.preferredColorScheme(state.isDark ? .dark : .light)
```

后果：iOS 无法跟随系统深浅色切换。系统切到深色时 App 仍强制浅色（`isDark == false` 时），
只能靠 App 内开关手动切。`colorScheme` 关键字在 `iosApp/Sources` 命中 0 次。

### 3. 下拉刷新覆盖面

Android `PullRefresh` 相关 14 处；iOS 仅 `Features/MaterialPageScreen.swift:91` 一处
`.refreshable`。首页课表/成绩列表与设置页均无下拉刷新。

## 三、iOS 端额外具备

- **Liquid Glass 玻璃质感控件**：`UI/SystemGlassSupport.swift` + `UI/LiquidTabBar.swift`，
  运行时经 ObjC runtime 取 `UIGlassEffect`；`hasNativeGlassAPI` 区分编译期能力，
  `isLiquidGlassOS` 区分运行期能力，缺任一则回落到 `UIBlurEffect` 系统材质。
  Android 侧对应实现是 `com.kyant.backdrop.catalog.components.Liquid*` 自绘组件。

## 四、真机验证结果（iOS 27.2 beta3 / LiveContainer）

### P0：`选择学校` 页空白，登录流程无法开始

真机截图（`ios-shots/walkthrough-01/`，30 帧 3s 间隔连拍，去重后 4 个画面）显示：
登录页常驻红色错误「请选择学校」，点进「选择学校」后是**全空白页**，只有标题栏和「完成」。

根因：**macOS CI 产出的 IPA 根本没打进学校资源**。对比两个 IPA 的 `Payload/` 内容：

| 文件 | Windows 本地 `iosApp/build-ios/PalmAcademic.ipa` | macOS CI `build-out/PalmAcademic-ios-liquidglass.ipa` |
|---|---|---|
| `schools/index.json` | 有 | **无** |
| `schools/cup.json` | 有 | **无** |
| `schools/cupk.json` | 有 | **无** |
| `adapters/cupk-reader.js` | 有 | **无** |
| `PalmAcademic` 可执行文件 | 有 | 有 |
| `Assets.car` / 图标 / `Info.plist` | 有 | 有 |

CI 产物只有 7 个文件，`Payload/PalmAcademic.app/` 下根本没有 `schools/` 和 `adapters/` 目录。

两条构建链的资源处理不一致：

- **Windows 交叉编译**（`iosApp/scripts/build-ios.sh:205-207`）显式建目录再拷：
  ```bash
  mkdir -p "$APP_DIR/schools" "$APP_DIR/adapters"
  cp "$ROOT"/Resources/schools/*.json "$APP_DIR/schools/"
  cp "$ROOT"/Resources/adapters/*.js  "$APP_DIR/adapters/"
  ```
- **macOS + XcodeGen**（`iosApp/project.yml`）的 `sources:` 只声明了两项，漏掉这两个资源目录：
  ```yaml
  sources:
    - Sources
    - path: Resources/Assets.xcassets
      buildPhase: resources
  ```

`SchoolCatalog.readBundledText(assetPath:)` 用
`Bundle.main.url(forResource:withExtension:subdirectory:)` 按 `schools/` 目录去找文件，
资源缺失时静默失败（`try?`），`options` 为空 → 选校页渲染空白。

**修法**（`iosApp/project.yml` 的 `sources` 追加两项，用 `type: folder` 保持目录结构）：

```yaml
      - path: Resources/schools
        type: folder
        buildPhase: resources
      - path: Resources/adapters
        type: folder
        buildPhase: resources
```

### 设备与工具链状态

| 项目 | 状态 |
|---|---|
| 设备 | iPhone12,3 / iOS 27.2 beta3，Developer Mode 已开 |
| 掌上门户安装位置 | LiveContainer `/Documents/Applications/cn.edu.cupk.portalreader.ios.app`（不出现在系统 `apps list`） |
| IPA 落盘 | `我的 iPhone → LocalSend → PalmAcademic-ios-liquidglass.ipa`，678814 B，sha256 校验一致 |
| DDI | `mounter auto-mount` 自动挂 Cryptex1，约 20s |
| 截屏 | 原生 `com.apple.mobile.screenshotr` 在 iOS 27 beta 返 `InvalidService`；改走 DVT（需先建无 root 用户态隧道） |
| 模拟点击 | **做不到**：pymobiledevice3 无 HID 注入，DVT condition inducer 无 tap profile，XCUITest 需设备侧 test runner。故本轮对比由「用户手动点 + 脚本连拍」完成，脚本见 `tools/burst_shot.py` |
| 无障碍元素树 | `developer accessibility list-items` 可用，可交叉验证页面文案 |

