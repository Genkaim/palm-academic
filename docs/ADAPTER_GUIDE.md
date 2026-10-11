# 学校适配指南

本文是当前 Android 与 iOS 共用的适配流程。目标是先在真机上完成一组可反复覆盖的本地规则，再把同一份规则同步为仓库内置配置。

## 1. 先选一个起点

优先复制最接近目标学校的示例：

- `examples/local-adapters/genkaim-top.json` 与对应 JS：常规教务页面示例。
- `examples/local-adapters/portal-cupk-script-test.json` 与对应 JS：真实 CAS 表单的 RSA 密码、短信和跨域门户示例。
- `app/src/main/assets/schools/hznu.json` 与对应 JS：密码、短信、扫码三方式脚本登录参考。
- `app/src/main/assets/schools/cupk.json` 与 `app/src/main/assets/adapters/cupk-reader.js`：完整生产适配器参考。

本地调试时保留两个文件，文件名可自定义：

```text
my-school.json
my-school-reader.js
```

在 Android 或 iOS 的学校选择页依次导入 JSON 和 JS。应用会把 `readerAdapter` 重写为安全的本地路径；再次导入相同 `id` 时会询问是否覆盖。确认后，新规则立即替换旧的本地规则，无须改 ID。删除本地规则后，同 ID 的内置或在线规则会重新显现。

## 2. 编写学校定义 JSON

下面是适合开始调试的完整配置骨架；登录界面的字段和握手逻辑由下一节的 JS 提供。

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
    "type": "script",
    "loginUrl": "https://sso.example.edu.cn/login",
    "homePath": "/home",
    "successUrlPrefixes": ["https://jw.example.edu.cn/home"],
    "sessionCookieHosts": ["sso.example.edu.cn", "jw.example.edu.cn"],
    "sessionCookieNames": ["SESSION"]
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

## 3. 编写登录适配器

新适配优先使用 `auth.type: "script"`。App 负责受限网络、Cookie、加密和原生界面，学校 JS 只描述字段并编排登录握手。为兼容本地导入的“JSON + 一个 JS”流程，登录段通常与阅读段放在同一个 `<id>-reader.js` 中，并分别用运行环境作入口保护：

```js
(function () {
  if (!window.PalmAcademic || window.PalmAcademicLoginAdapter) return;
  const H = window.PalmAcademic;

  window.PalmAcademicLoginAdapter = {
    describe() {
      return {
        methods: [{
          id: 'password', kind: 'password', label: '账号密码', default: true,
          fields: [
            {id: 'username', type: 'text', label: '账号', required: true},
            {id: 'password', type: 'password', label: '密码', required: true}
          ],
          checkboxes: [
            {id: 'rememberCredential', label: '记住密码', defaultChecked: true, scope: 'local'}
          ]
        }]
      };
    },

    async submit(arg) {
      const v = arg.values || {};
      const response = await H.http({
        method: 'POST',
        url: 'https://sso.example.edu.cn/login',
        form: {username: v.username, password: v.password}
      });
      if (response.finalUrl.startsWith('https://jw.example.edu.cn/home')) {
        return {ok: true, kind: 'success'};
      }
      return {ok: false, kind: 'rejected', message: '账号或密码错误'};
    }
  };
})();
```

### JSON 配置

```json
"auth": {
  "type": "script",
  "loginUrl": "https://sso.example.edu.cn/login",
  "homePath": "/home",
  "successUrlPrefixes": ["https://jw.example.edu.cn/home"],
  "sessionCookieHosts": ["sso.example.edu.cn", "jw.example.edu.cn"],
  "sessionCookieNames": ["SESSION"]
}
```

`loginScript` 可为仓库内置规则指定单独的 `adapters/<id>-login.js`；省略时使用 `readerAdapter`。学校选择页的本地导入只接收一个 JS，因此本地调试必须省略 `loginScript`，把两个适配器合并在同一文件中。

所有 `H.http()` 请求及其重定向都必须是白名单内的 HTTPS。白名单由 `baseUrl`、`loginUrl`、`successUrlPrefixes` 和 `sessionCookieHosts` 的主机共同生成；跨 CAS、VPN、门户或教务域名时必须完整填写。脚本拿不到 Cookie，Cookie 由本次登录独立的原生容器管理，校验成功后才写入应用会话。

登录成功必须同时满足：最后一次请求的 `finalUrl` 命中 `successUrlPrefixes`，并且存在 `sessionCookieNames` 指定的非空 Cookie。`sessionCookieNames: []` 表示接受任意名称的非空 Cookie，不表示跳过 Cookie 校验。前缀应尽量写到登录后的具体路径，不要只写域名根路径。脚本也只能在服务端响应明确可判定时返回 `ok: true`。

### App 提供的 `PalmAcademic` API

| API | 输入 | 返回/行为 |
| --- | --- | --- |
| `H.http(req)` | `method`、`url`、可选 `headers`，以及 `form` / `json` / `body` 三选一 | `{status, finalUrl, text}`；自动维护 Cookie，但不向 JS 暴露 Cookie。 |
| `H.crypto(spec)` | `op` 与算法参数 | 直接返回字符串。支持 `sha1`、`md5`、`rsa-pkcs1`、`aes-cbc-pkcs7`。 |
| `H.sleep(ms)` | `0..120000` 毫秒 | 用于扫码轮询等短暂等待。 |
| `H.ui(event)` | 原生 UI 事件 | `qr`、`toast`、`state`；详见下文。 |

密码字段不会以明文进入 JS。`type: "password"` 的字段值会被替换为 `__PA_PASSWORD__`；该占位符出现在 `http` 的 URL、header、form、JSON、body 或 `crypto` 参数中时，原生才临时替换真实密码，并在一次适配器调用结束后清除。不要把密码写入日志、返回值、二维码事件或其他普通字段。

`crypto` 参数：

- `{op: 'sha1'|'md5', data}`：返回小写十六进制摘要。
- `{op: 'rsa-pkcs1', data, publicKey}`：使用 Base64 X.509 公钥，返回 Base64 密文。
- `{op: 'aes-cbc-pkcs7', data, key, iv?, prefixLength?}`：UTF-8 key 必须为 16/24/32 字节，返回 Base64 密文；`prefixLength` 可用于金智类协议的随机前缀。

### `describe()` 界面协议

`describe()` 返回 `{methods, methodSwitch?}`。只有显式设置 `methodSwitch: true` 才显示多方式切换；否则即使声明多个方式，也只显示 `default: true` 的方式（没有默认项时取第一项）。

- `method.kind`：`password`、`sms` 或 `qrcode`。
- `fields[].type`：`text`、`password`、`tel`、`captcha`、`smsCode`。
- 图形验证码字段可带 `captcha: {url, refreshParam}`；图片由 App 拉取，不经过 JS。
- `checkboxes[].scope: "local"` 只控制 App 本地行为；`scope: "request"` 的值通过 `arg.checkboxes` 交给脚本。保存凭据复选框统一使用 `id: "rememberCredential"`。

`submit(arg)` 接收 `{methodId, values, checkboxes}`，返回：

- 成功：`{ok: true, kind: 'success'}`。
- 明确拒绝：`{ok: false, kind: 'rejected', message}`。
- 需要动态验证码：`{ok: false, kind: 'captcha', message, captcha: {url, refreshParam}}`。
- 密码校验后需要多因子认证：`{ok: false, kind: 'mfa', message, challenge}`。`challenge` 至少包含稳定的 `id`，还可声明 `title`、`message`、`inputLabel`、`placeholder`、`sendCode`、`sendLabel`、`rememberLabel`、`rememberDefault`。App 会显示原生弹窗；该流程仍属于原密码登录方式。

短信方式可额外实现 `sendSms(arg)`，返回 `{ok, message, cooldownSeconds?}`。扫码方式在 `submit()` 内轮询，并用 `H.ui({type:'qr', state, message, imageUrl? | imageBase64?})` 更新二维码；`state` 常用 `waiting`、`scanned`、`expired`。`toast` 事件使用 `{type:'toast', message}`，阶段事件使用 `{type:'state', state, message}`。

多因子认证适配器必须成对实现以下接口：

- `sendChallenge(arg)`：接收原 `methodId`、`values`、`checkboxes` 与 `challengeId`，发送验证码并返回 `{ok, message, cooldownSeconds?}`。
- `submitChallenge(arg)`：在上述参数之外接收 `code` 与 `remember`，校验后返回与 `submit()` 相同结构的结果。成功时仍返回 `{ok: true, kind: 'success'}`；服务端要求重试时可再次返回 `kind: 'mfa'` 和更新后的 `challenge`。

脚本可在 `submit()` 中保存这次握手所需的非敏感临时状态（例如 execution），供挑战接口使用，但不得把密码、Cookie 或 Token 放入返回值。App 只会在最终挑战成功后保存密码凭据与会话。会话过期后，App 会在后台用已保存的密码重新执行同一 `password` 方法；若服务端不再要求验证则静默恢复，若仍返回 `mfa` 或 `captcha` 才通知用户进入验证界面。明确拒绝不会自动循环提交。

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

用户在应用内 WebView 完成登录。Cookie 过期时，应用引导重新进入登录页。跨 CAS/门户域名时，把实际使用的主机都写入 `sessionCookieHosts`。

`salted-sha1` 与 `engine` 仍用于兼容已有规则，但新学校不要再把复杂握手堆进 JSON；迁移到 `script` 后可直接使用上面的统一 API。脚本密码登录的后台静默重登会复用脚本协议和可持久化的设备信任 Cookie，不会走旧 `AuthRepository`；短信、扫码和网页方式仍需用户交互。

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
7. 让 Cookie 失效，确认脚本密码登录先在后台静默重试；仅当服务端仍要求验证码或多因子认证时通知并打开验证界面，短信登录和网页登录则回到各自的交互式重新认证流程。
8. 对支持多因子的学校分别验证首次密码登录、发送验证码、错误验证码、信任设备和挑战成功后的会话保存；确认整个过程始终归属密码登录。
9. 导出课表，核对节次的实际开始/结束时间。
10. 用相同 ID 重新导入，确认覆盖弹窗和覆盖后的规则生效。

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

若内置规则显式使用独立的 `auth.loginScript`，还要在 Android 与 iOS 对应的 `adapters/` 目录各同步一份登录 JS；通常仍建议与 reader 合并，减少双文件漂移。

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

校验器会检查索引、HTTPS、ID、作者信息、四个快捷入口、监控模板、作息时间、登录配置、适配器引用和 JavaScript 语法，并核对 Android/iOS 随包资源一致性；对于 `type: "script"`，还会在隔离上下文中加载脚本并校验 `describe()`、`submit()`、短信方式协议，以及多因子 `sendChallenge()` / `submitChallenge()` 是否成对实现。校验通过不代表真实站点可用，真机双端验收仍是合并前提。

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
