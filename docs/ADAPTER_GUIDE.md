# 学校适配指南

本文是当前 Android 与 iOS 共用的适配流程。目标是先在真机上完成一组可反复覆盖的本地规则，再把同一份规则同步为仓库内置配置。

## 1. 先选一个起点

优先复制最接近目标学校的示例：

- `examples/local-adapters/genkaim-top.json` 与对应 JS：常规教务页面示例。
- `examples/local-adapters/portal-cupk-test.json` 与对应 JS：跨域 CAS、密码加验证码、门户页面示例。
- `app/src/main/assets/schools/cupk.json` 与 `app/src/main/assets/adapters/cupk-reader.js`：完整生产适配器参考。

本地调试时保留两个文件，文件名可自定义：

```text
my-school.json
my-school-reader.js
```

在 Android 或 iOS 的学校选择页依次导入 JSON 和 JS。应用会把 `readerAdapter` 重写为安全的本地路径；再次导入相同 `id` 时会询问是否覆盖。确认后，新规则立即替换旧的本地规则，无须改 ID。删除本地规则后，同 ID 的内置或在线规则会重新显现。

## 2. 编写学校定义 JSON

下面是适合开始调试的骨架。示例省略了具体登录字段，下一节按登录方式补齐。

```json
{
  "schemaVersion": 1,
  "id": "my-school",
  "name": "示例大学",
  "author": {
    "name": "Your Name",
    "email": "your-name@users.noreply.github.com"
  },
  "baseUrl": "https://jw.example.edu.cn",
  "readerAdapter": "adapters/my-school-reader.js",
  "auth": {
    "type": "web",
    "loginUrl": "https://sso.example.edu.cn/login",
    "homePath": "/home",
    "successUrlPrefixes": ["https://jw.example.edu.cn/"]
  },
  "monitor": {
    "coursePagePath": "/course-table",
    "courseDataPathTemplate": "/course-table/data?semester={semesterId}&student={studentId}",
    "gradeDataPathTemplate": "/grade/{studentId}",
    "examDataPathTemplate": "/exam/{studentId}",
    "semesterIdPatterns": ["semesterId[\"']?\\s*[:=]\\s*[\"']?(\\d+)"],
    "studentIdPatterns": ["studentId[\"']?\\s*[:=]\\s*[\"']?(\\d+)"]
  },
  "groups": [
    {
      "title": "常用功能",
      "items": [
        {"title": "教务首页", "path": "/home"},
        {"title": "我的课表", "path": "/course-table", "quick": true, "nativeType": "schedule"},
        {"title": "课程成绩", "path": "/grade", "quick": true, "nativeType": "grade"},
        {"title": "考试安排", "path": "/exam", "quick": true, "nativeType": "exam"},
        {"title": "培养方案", "path": "/program", "quick": true, "nativeType": "program"}
      ]
    }
  ],
  "readerConfig": {
    "scheduleProfiles": [
      {
        "locationPattern": "",
        "unitTimes": {
          "1": ["08:00", "08:45"],
          "2": ["08:55", "09:40"]
        }
      }
    ]
  }
}
```

### 基础字段

| 字段 | 要求 |
| --- | --- |
| `schemaVersion` | 当前固定为 `1`。 |
| `id` | 全仓库唯一，使用小写字母、数字和连字符。发布后不要随意修改。 |
| `author` | 必须提供名称和可联系邮箱；可使用 GitHub `noreply` 邮箱。 |
| `baseUrl` | 学校系统的 HTTPS 根地址，不得包含账号、密码或 Token。 |
| `readerAdapter` | 指向该校独立 JS，通常为 `adapters/<id>-reader.js`。 |
| `groups[].items[].path` | `/` 开头的相对路径，或完整 HTTPS 地址。普通项在应用内 WebView 打开。 |
| `quick` / `nativeType` | 原生重绘入口。当前必须各提供一个 `schedule`、`grade`、`exam`、`program`。 |

普通网页不应添加 `quick`。如果点击后空白，先在真机 WebView 中检查实际跳转链、HTTPS 地址和登录 Cookie，而不是把普通页改造成重绘页。

### 作息时间

`readerConfig.scheduleProfiles` 至少包含一个 `locationPattern: ""` 的默认项，`unitTimes` 使用 `HH:mm`：

```json
{
  "locationPattern": "",
  "unitTimes": {
    "1": ["08:00", "08:45"],
    "2": ["08:55", "09:40"]
  }
}
```

可追加更具体的 `locationPattern` 覆盖不同校区。缺少作息时间时页面可能仍能显示，但日历和 WakeUp 导出会缺少正确时间。

## 3. 选择登录方式

只选择与学校实际流程一致的一种类型。

### `salted-sha1`：旧式盐值密码登录

```json
"auth": {
  "type": "salted-sha1",
  "captcha": {"required": false},
  "loginPath": "/login",
  "saltPath": "/login-salt",
  "homePath": "/home"
}
```

适用于项目已支持的盐值 SHA-1 表单。无验证码且保存了凭据时，Cookie 过期会在后台静默重新登录。

### `web`：应用内网页登录

```json
"auth": {
  "type": "web",
  "loginUrl": "https://sso.example.edu.cn/login",
  "homePath": "/home",
  "successUrlPrefixes": ["https://jw.example.edu.cn/"],
  "sessionCookieHosts": ["sso.example.edu.cn", "jw.example.edu.cn"],
  "sessionCookieNames": ["SESSION"]
}
```

用户在应用内 WebView 完成登录。Cookie 过期时，应用弹窗引导进入登录页。跨 CAS/门户域名时，把登录链真正使用的主机都写入 `sessionCookieHosts`。Cookie 名稳定时优先显式填写；确实无法固定名称时才使用空数组接受有效 Cookie。

### `engine`：声明式密码或验证码登录

`engine.steps` 由三类步骤组成：

- `request`：GET/POST 页面或接口；表单使用 `contentType: "form"` 与 `form`。
- `extract`：从前一步响应中用正则提取动态字段。
- `transform`：转换密码，目前支持 `rsa-pkcs1-base64`、`sha1`、`md5`。

步骤中可引用 `{username}`、`{password}`、`{captcha}`、`{loginUrl}` 和此前步骤的结果。完整 CAS 示例见 `examples/local-adapters/portal-cupk-test.json`。

验证码登录需明确声明：

```json
"captcha": {
  "required": true,
  "imageUrl": "https://sso.example.edu.cn/captcha.jpg",
  "refreshQueryParameter": "id"
}
```

同时在 `engine.outcome` 中给出可判定的结果：

```json
"outcome": {
  "captcha": {
    "bodyContains": ["验证码错误", "请输入验证码"],
    "message": "验证码错误，请刷新后重试"
  },
  "rejected": {
    "bodyContains": ["账号或密码错误"],
    "message": "账号或密码错误"
  },
  "success": {
    "finalUrlPrefixes": ["https://jw.example.edu.cn/"]
  }
}
```

当前会话恢复策略如下，适配时必须逐项验证：

- `captcha.required: false` 的密码登录：过期后静默重试，不打扰用户。
- `captcha.required: true` 的密码登录：发出通知；用户进入应用后输入验证码即可恢复。
- `web` 登录：弹窗引导用户重新打开登录页。

## 4. 配置后台检查

`monitor` 用于登录后的预取、基线建立和后台变化比较，不只是页面菜单：

| 字段 | 用途 |
| --- | --- |
| `coursePagePath` | 用于发现学期、学生标识或预热会话的课表入口。 |
| `courseDataPathTemplate` | 课表数据地址，必须包含 `{semesterId}`，可同时使用 `{studentId}`。 |
| `gradeDataPathTemplate` | 成绩数据地址，可使用 `{studentId}`。 |
| `examDataPathTemplate` | 考试数据地址，可使用 `{studentId}`。 |
| `semesterIdPatterns` | 从响应中提取学期 ID 的正则列表。 |
| `studentIdPatterns` | 从响应中提取学生 ID 的正则列表，至少提供一条有效规则。 |

路径可以是 `/` 开头的相对地址或完整 HTTPS 地址。优先填写页面实际调用的只读数据接口；如果内容直接由服务端渲染在入口页中，也可把相应模板指向入口页，但必须验证 Android 与 iOS 都能解析并建立基线。

登录后，两端会预取四个重绘入口。已有缓存时应立即展示缓存，再在后台刷新；刷新期间右上角显示旋转状态。后台检查不保证执行页面 JS，因此不要只在适配器脚本中拼出监控所需的学期或学生标识。

## 5. 编写阅读适配器 JS

每所学校使用独立脚本，不要依赖另一所学校的适配器。宿主提供：

```js
window.PalmAcademicHost = {
  apiVersion: 1,
  schoolConfig: {},
  publish(payload) {}
};
```

适配器需要暴露并立即发布：

```js
(function () {
  'use strict';
  if (!window.PalmAcademicHost || window.PalmAcademicAdapter) return;

  function read() {
    return {
      title: document.title || '教务页面',
      sourceUrl: location.href,
      choices: [],
      actions: [{id: 'refresh', label: '刷新网页', value: ''}],
      sections: [{
        type: 'cards',
        title: '页面信息',
        cards: [{
          title: '当前页面',
          subtitle: '',
          fields: [{label: '地址', value: location.href}]
        }]
      }]
    };
  }

  function publish() {
    window.PalmAcademicHost.publish(read());
  }

  function perform(actionId) {
    if (actionId !== 'refresh') return false;
    location.reload();
    return true;
  }

  window.PalmAcademicAdapter = {apiVersion: 1, read, publish, perform};
  publish();

  if (document.body) {
    let timer;
    new MutationObserver(function () {
      clearTimeout(timer);
      timer = setTimeout(publish, 150);
    }).observe(document.body, {childList: true, subtree: true, characterData: true});
  }
})();
```

`read()` 必须返回可 JSON 序列化的普通对象。页面异步加载时，用防抖后的 `MutationObserver` 再次发布，避免首次只得到空壳。不要把完整 HTML、Cookie、Token 或其他敏感值放入 payload。

常用 section 类型：

- `schedule`：`semesterStartDate`、`days[].lessons[]`，课程可带周次、节次、教师、地点和起止时间。
- `cards`：`cards[].title/subtitle/fields[]`，适合成绩、考试和普通信息卡片。
- `table`：表头与二维行数据。
- `program`：学分概览与可递归的培养方案模块。
- `text`、`fields`、`stats`、`links`：较简单的文本、键值、统计和链接内容。

`actions` 与 `choices` 由 `perform(actionId, value)` 处理。适配器只允许读取页面、切换只读视图或刷新，不得代替用户提交选课、退课、评教、申请等写操作。

## 6. 真机验收顺序

不要只在桌面浏览器中验证 DOM。按下面顺序在 Android 和 iOS 各测一遍：

1. 首次登录成功，关闭并重开应用后能恢复会话。
2. 普通入口显示真实网页，返回栏不遮住网页，跨域/同域重定向正常。
3. 四个重绘分组均出现，并分别能打开课表、成绩、考试、培养方案。
4. 首次登录后不手动点击，四个重绘页面仍会在后台预取并建立基线。
5. 再次打开已有缓存的重绘页，缓存立即显示，同时后台刷新且刷新图标旋转。
6. 手动刷新不闪退；异步页面最终能重新发布完整数据。
7. 让 Cookie 失效，确认无验证码、验证码、网页登录分别走预期恢复流程。
8. 导出课表，核对节次的实际开始/结束时间。
9. 用相同 ID 重新导入，确认覆盖弹窗和覆盖后的规则生效。

若失败，优先记录最终 URL、HTTP 状态、重定向链、Cookie 所属域、页面是否异步渲染，以及 `monitor` 正则是否在真实响应中命中。日志中不要保留真实凭据和学生数据。

## 7. 提交为内置适配

本地测试通过后，同步以下文件：

```text
app/src/main/assets/schools/<id>.json
app/src/main/assets/adapters/<id>-reader.js
app/src/main/assets/schools/index.json

iosApp/Resources/schools/<id>.json
iosApp/Resources/adapters/<id>-reader.js
iosApp/Resources/schools/index.json
```

两个平台的学校定义、JS 和索引条目应保持一致。索引为 `schemaVersion: 2`，在 `builtIn` 中登记：

```json
{
  "id": "my-school",
  "name": "示例大学",
  "origin": "https://jw.example.edu.cn",
  "definitionAsset": "schools/my-school.json",
  "readerConfig": {
    "scheduleProfiles": [
      {
        "locationPattern": "",
        "unitTimes": {"1": ["08:00", "08:45"]}
      }
    ]
  }
}
```

修改索引或学校规则时递增 `configVersion`。在线更新固定从 `main` 分支的 `app/src/main/assets/` 获取；iOS 目录仍必须同步，因为它用于随包资源和离线回退。

提交前运行：

```powershell
node tools/validate-adapters.mjs
```

校验器会检查索引、HTTPS、ID、作者信息、四个快捷入口、监控模板、作息时间、登录引擎结构、适配器引用和 JavaScript 语法。校验通过不代表真实站点可用，真机双端验收仍是合并前提。

## 8. 提交检查清单

- [ ] 未提交账号、密码、Cookie、Token、私钥或真实学生数据。
- [ ] 普通页面与四个重绘页面在 Android、iOS 均可打开。
- [ ] 登录恢复与 Cookie 过期流程符合声明的登录类型。
- [ ] 登录后自动预取、缓存秒开、后台刷新和变化通知正常。
- [ ] `readerConfig` 包含默认作息，课表导出时间正确。
- [ ] Android 与 iOS 的内置资源已同步，`configVersion` 已递增。
- [ ] `node tools/validate-adapters.mjs` 通过。
- [ ] Pull Request 说明测试学校、测试设备、登录方式与已验证页面，但不包含敏感信息。

更多仓库协作要求见 [贡献指南](../CONTRIBUTING.md)。
