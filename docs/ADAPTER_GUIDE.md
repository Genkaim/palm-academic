# 学校适配指南

适配一所学校只需要编写两份文件：一份学校定义、一份适配器脚本。用**本地导入**方式测试时不需要合并仓库、也不需要重新编译 App。

| 文件 | 作用 |
|---|---|
| 学校定义 `xxx.json` | 学校名称、地址、登录方式、首页菜单、四个重绘入口、后台检查接口、作者信息 |
| 适配器 `xxx-reader.js` | 在隐藏网页中读取四个重绘入口的内容，转换成统一的原生页面数据 |

写好后在手机上通过"选择学校 → 导入本地规则"直接选用，安卓和 iPhone 操作完全一致。

## 规则的两种使用方式

| 方式 | 怎么做 | 谁能用 |
|---|---|---|
| **① 本地导入（自用 / 测试）** | 把 JSON + JS 两个文件传到手机，在"选择学校 → 导入本地规则"里依次选择，立即生效，不联网、不审核、不编译 | 仅导入的这台设备；可随时覆盖更新或删除 |
| **② 提交 PR 上云（分发给所有人）** | 按文末第六节把两个文件提交到仓库 main 分支；合并发布后，任意用户在"选择学校"页点右上角**刷新**即可拉到这所学校，无需传文件 | 安卓与 iOS 全体用户 |

本地规则与云端规则分开存放：本地导入的同名学校会优先于云端规则显示，刷新云端不会覆盖或删除它。建议先用方式①在真机上调通，再走方式②分发。

```text
普通功能项（无 quick 标记）
  JSON 里的 path 直接用内置浏览器打开学校官网，不做任何改写

四个重绘入口（quick: true）
  JSON 里的 path → 隐藏 WebView 打开网页 → 注入你的 JS 解析 → 原生界面重绘

后台定时检查
  JSON 里的 monitor 接口地址 → App 直接请求只读数据 → 比对前后 JSON
  （后台任务不执行适配器 JS）
```

## 一、方式①：应用内本地导入测试（最快）

1. 准备好学校定义 JSON 和适配器 JS 两个文件，放到手机可取用的位置（"文件"App、下载目录、LocalSend 等均可）。
2. 在登录页点"选择学校"，拉到列表**最底部**点"导入本地规则"。
3. 先选 JSON，再选 JS。App 会立即校验：两份文件通过后即出现在学校列表，带"本地"标记。
4. 选中这所学校直接登录测试。改了规则想更新：再次导入同名规则并确认覆盖，或先在列表里删除再重新导入。

本地规则保存在 App 自己的数据目录，刷新云端规则不会覆盖或删除它；只有本地导入的学校能删除，内置学校只读。学校行右侧的信息按钮可查看规则作者与联系方式。

导入时 JSON 中的 `readerAdapter` 路径会被自动重写为本机安全路径，所以 JS 文件名随意、不必与 JSON 里写的路径同名，但脚本内容必须实现 `PalmAcademicAdapter`（见第四节）。

### 可直接导入的现成示例

- [genkaim-top.json](../examples/local-adapters/genkaim-top.json) + [genkaim-top-reader.js](../examples/local-adapters/genkaim-top-reader.js)：演示如何把规则指向任意目标地址。
- [portal-cupk-test.json](../examples/local-adapters/portal-cupk-test.json) + [portal-cupk-test-reader.js](../examples/local-adapters/portal-cupk-test-reader.js)：以中石大克拉玛依融合门户为目标，完整演示 CAS 引擎登录（验证码、RSA 加密密码、execution 提取）和四个重绘入口；适配器只读取页面可见链接，适合作为最小骨架照抄。

想看一份真实生产级参考，可对照内置 cupk 学校：

- 定义：<https://raw.githubusercontent.com/Genkaim/palm-academic/main/app/src/main/assets/schools/cupk.json>
- 脚本：<https://raw.githubusercontent.com/Genkaim/palm-academic/main/app/src/main/assets/adapters/cupk-reader.js>

## 二、学校定义 JSON

### 最小骨架

```json
{
  "schemaVersion": 1,
  "id": "example-university",
  "name": "示例大学",
  "author": {"name": "你的名字", "email": "you@example.com"},
  "baseUrl": "https://jw.example.edu.cn/student",
  "readerAdapter": "adapters/example-reader.js",
  "auth": {
    "type": "salted-sha1",
    "captcha": {"required": false},
    "loginPath": "/login",
    "saltPath": "/login-salt",
    "homePath": "/home"
  },
  "monitor": {
    "coursePagePath": "/for-std/course-table",
    "courseDataPathTemplate": "/for-std/course-table/get-data?semesterId={semesterId}&dataId={studentId}",
    "gradeDataPathTemplate": "/for-std/grade/sheet/info/{studentId}",
    "examDataPathTemplate": "/for-std/exam-arrange/info/{studentId}",
    "semesterIdPatterns": ["[\"']semesterId[\"']\\s*:\\s*[\"']?(\\d+)"],
    "studentIdPatterns": ["/for-std/course-table/info/(\\d+)"]
  },
  "groups": [
    {"title": "常用功能", "items": [
      {"title": "选课信息", "path": "/for-std/course-select"}
    ]},
    {"title": "重绘入口", "items": [
      {"title": "我的课表", "path": "/for-std/course-table", "quick": true, "nativeType": "schedule"},
      {"title": "课程成绩", "path": "/for-std/grade/sheet", "quick": true, "nativeType": "grade"},
      {"title": "考试信息", "path": "/for-std/exam-arrange", "quick": true, "nativeType": "exam"},
      {"title": "培养方案", "path": "/for-std/program-completion-preview", "quick": true, "nativeType": "program"}
    ]}
  ],
  "readerConfig": {
    "scheduleProfiles": [
      {"locationPattern": "", "unitTimes": {
        "1": ["08:00", "08:45"],
        "2": ["08:50", "09:35"]
      }}
    ]
  }
}
```

### 字段说明

| 字段 | 说明 |
|---|---|
| `id` | 规则唯一标识，只能用小写字母、数字、连字符 |
| `name` / `author` | 显示名称；作者名和邮箱必填，会展示在学校详情中 |
| `baseUrl` | 目标站点基地址，必须 HTTPS；跨域的门户/CAS 可在各路径中写完整 URL |
| `readerAdapter` | 适配器脚本引用，本地导入时会被重写，照写 `adapters/<id>-reader.js` 即可 |
| `groups` | 首页菜单。普通项只写 `title`/`path`；四个重绘项加 `quick: true` 和 `nativeType` |
| `monitor` | 后台检查接口模板与学期/学生 ID 提取正则，见下文 |
| `readerConfig` | 作息时间表（本地规则直接写在 JSON 顶层即可） |

`path` 和 monitor 路径既可以写相对 `baseUrl` 的路径（`/for-std/...`），也可以写完整 HTTPS URL。不要把带 ticket、sid、token 或学号的临时链接写进规则。

### 登录方式（auth.type）

**账号密码由 App 原生登录页收集，适配器 JS 不需要也不允许接触密码。** 规则作者要做的只是在 JSON 的 `auth` 里描述"密码该怎样提交给学校服务器"，加密和网络请求都由 App 完成：

- **密码从哪来**：用户在登录页输入的明文密码，在引擎里用内置变量 `{password}` 引用；账号是 `{username}`，验证码是 `{captcha}`。
- **salted-sha1**：不用自己写加密。App 自动先取 `saltPath` 的盐值，计算 `SHA1(salt + "-" + 密码)`，再把 `{username, password, captchaToken}` 以 JSON POST 到 `loginPath`。
- **engine**：`{password}` 默认是**明文**。学校系统若要求加密（如 CAS 常见的 RSA 公钥加密），加一个 `transform` 步骤声明算法即可，App 会在提交前完成加密；支持 `rsa-pkcs1-base64`（X.509 Base64 公钥）、`sha1`、`md5`，需要多次处理就串多个 transform 步骤。
- **web**：完全由用户在网页里输入，App 不参与表单，只在落到成功地址后捕获会话 Cookie。
- **记住密码**：用户勾选后，密码经系统密钥库加密保存在本机，仅用于会话过期时自动静默重登，不会上传、不会写进规则文件。规则里绝不允许硬编码任何账号或密码。

三种 `type` 的具体写法如下。

**1. `salted-sha1`（内置教务默认）**：配置 `loginPath`、`saltPath`、`homePath` 即可。

**2. `web`（纯网页登录/CAS 跳转）**：App 直接在内置浏览器打开登录页，落到成功地址即视为登录完成。

```json
{
  "auth": {
    "type": "web",
    "loginUrl": "https://cas.example.edu.cn/",
    "successUrlPrefixes": ["https://portal.example.edu.cn/portal/"],
    "sessionCookieHosts": ["portal.example.edu.cn"],
    "sessionCookieNames": ["JSESSIONID"]
  }
}
```

- `successUrlPrefixes`：进入其中任一地址即登录成功。
- `sessionCookieHosts`：需要捕获会话 Cookie 的主机；**CAS 与门户不同域时两个主机都要列**，否则会话无法跨域恢复（如 `["portal.example.edu.cn", "cas.example.edu.cn"]`）。
- `sessionCookieNames`：会话 Cookie 名；留空数组 `[]` 表示接受落点主机的任意非空 Cookie；名称稳定时建议显式写出。

**3. `engine`（步骤式通用登录引擎，双端语义一致）**：适用于 CAS、统一身份认证、RSA 加密密码等任意账密握手。App 不内置任何登录假设，完全按 `engine.steps` 依次执行：

| 步骤类型 | 作用 | 关键字段 |
|---|---|---|
| `request` | 发一次 HTTP 请求，自动跟随重定向并收集全程 Cookie | `method`、`url`、`headers`、`contentType`（`form`/`json`）、`form`/`json`/`body` |
| `extract` | 正则提取变量（默认取第一捕获组，取上一个请求的响应） | `from`、`regex`、`group` |
| `transform` | 加密/摘要 | `algorithm`：`rsa-pkcs1-base64`/`sha1`/`md5`；RSA 时给 `publicKey`、`input` |

内置变量：`{username}`、`{password}`、`{captcha}`、`{baseUrl}`、`{loginUrl}`；每个步骤的输出以其 `id` 命名，后续用 `{id}` 插值。

`outcome` 对最后一个请求的结果做判定：

- `captcha` / `rejected`：必须给出非空 `bodyContains`（任一命中），命中才按 `message` 提示并退回登录页。**不能只凭 401/403 判定密码错误**（网关、预会话失效也会返回这些码）。
- `success`：`finalUrlPrefixes`、`cookies`（默认取 `sessionCookieNames`）、`statusCodes` 全部满足才算成功。
- 都不命中视为网络/会话问题，App 持续重试，不打断用户。

完整 CAS 示例（含验证码）可直接看 [portal-cupk-test.json](../examples/local-adapters/portal-cupk-test.json)，下面是精简版：

```json
{
  "auth": {
    "type": "engine",
    "loginUrl": "https://cas.example.edu.cn/cas/login?service=https%3A%2F%2Fportal.example.edu.cn%2Fportal%2F",
    "successUrlPrefixes": ["https://portal.example.edu.cn/portal/"],
    "sessionCookieHosts": ["portal.example.edu.cn", "cas.example.edu.cn"],
    "sessionCookieNames": [],
    "captcha": {
      "required": true,
      "imageUrl": "https://cas.example.edu.cn/cas/captcha.jpg",
      "refreshQueryParameter": "id"
    },
    "engine": {
      "steps": [
        {"id": "loginPage", "request": {"method": "GET", "url": "{loginUrl}"}},
        {"id": "execution", "extract": {"regex": "name=\"execution\" value=\"([^\"]+)\""}},
        {"id": "encryptedPassword", "transform": {
          "algorithm": "rsa-pkcs1-base64",
          "publicKey": "<X.509 Base64 公钥>",
          "input": "{password}"
        }},
        {"id": "loginPost", "request": {
          "method": "POST", "url": "{loginUrl}", "contentType": "form",
          "form": {
            "username": "{username}",
            "password": "{encryptedPassword}",
            "captcha": "{captcha}",
            "execution": "{execution}",
            "_eventId": "submit"
          }
        }}
      ],
      "outcome": {
        "captcha": {"bodyContains": ["验证码错误"], "message": "验证码错误，请刷新后重试"},
        "rejected": {"bodyContains": ["用户名或密码错误"], "message": "账号或密码错误"},
        "success": {"finalUrlPrefixes": ["https://portal.example.edu.cn/"]}
      }
    }
  }
}
```

需要图片验证码时必须提供 HTTPS 的 `imageUrl` 和 `refreshQueryParameter`；App 会在同一登录会话中先打开登录页、再加载验证码图片并提交，点按图片按刷新参数重新获取。无验证码的学校也建议显式写 `"captcha": {"required": false}`。

### 四个重绘入口

每所学校必须恰好各提供一个 `nativeType`，都由同一个适配器脚本处理：

| `nativeType` | 建议标题 | 需要的核心数据 |
|---|---|---|
| `schedule` | 我的课表 | 学期、星期、课程名、周次、节次、地点、教师 |
| `grade` | 课程成绩 | 课程名、成绩及页面可见的学分、绩点、性质等 |
| `exam` | 考试信息 | 课程名、时间、地点、座位等 |
| `program` | 培养方案 | 学分统计、可递归的模块与课程完成状态 |

### 后台检查（monitor）

- `courseDataPathTemplate` 必须包含 `{semesterId}`；需要学号的接口用 `{studentId}`。
- 接口必须返回**真正含数据**的只读响应（课程行/成绩行/考试行），不能只填菜单页地址。
- `semesterIdPatterns`、`studentIdPatterns` 按顺序在入口页 HTML 和最终 URL 上匹配，取第一捕获组；两者都必须是非空正则数组。
- 日志只保存解析后的 JSON 摘要，不保存完整 HTML、Cookie 或个人凭据。

### 作息时间（readerConfig.scheduleProfiles）

- 必须包含一个 `locationPattern: ""` 的默认作息；多校区按地点正则匹配，顺序从具体到默认。
- 节次键是 `"1"`、`"2"` 这样的字符串，时间为 24 小时制 `["HH:mm", "HH:mm"]`。
- 作息会用于原生课表、日历（.ics）导出，必须覆盖全部节次。

## 三、适配器 JS

网页加载完成后，宿主会注入 `PalmAcademicHost`。脚本通过 `window.PalmAcademicAdapter` 暴露四个入口：

```ts
type PalmAcademicHost = {
  apiVersion: 1;
  schoolConfig: Record<string, unknown>;
  publish: (payload: PagePayload) => void;   // 把解析结果交给原生层
};

type PalmAcademicAdapter = {
  apiVersion: 1;
  read: () => PagePayload;                   // 只读解析当前页
  publish: () => void;                       // read() 后交给 host
  perform: (actionId: string, value: string) => boolean;  // 学期切换等交互
};
```

最小可用模板：

```js
(function () {
  'use strict';
  if (!window.PalmAcademicHost || window.PalmAcademicAdapter) return;

  function read() {
    return {
      title: document.title,
      sourceUrl: location.href,
      choices: [],
      actions: [],
      sections: [{type: 'text', title: '内容', paragraphs: [document.body.innerText.trim()]}]
    };
  }
  function publish() { PalmAcademicHost.publish(read()); }
  function perform() { return false; }

  window.PalmAcademicAdapter = {apiVersion: 1, read, publish, perform};
  publish();
})();
```

建议按页面拆分函数，在 `read()` 里按 URL 分发；四类逻辑必须在同一个文件内，**不得引用或复制其他学校的脚本**：

```js
function read() {
  const p = location.pathname;
  if (p.includes('/course-table')) return schedulePage();
  if (p.includes('/grade'))        return gradePage();
  if (p.includes('/exam-arrange')) return examPage();
  if (p.includes('/program'))      return programPage();
  return {title: document.title, sourceUrl: location.href, sections: []};
}
```

约束：

- 只做只读操作：禁止选课、退课、提交申请等任何写操作；禁止读取/输出 Cookie、密码、Token。
- 页面异步渲染时，用**防抖的** `MutationObserver` 等内容到位后再 `publish()`，避免重复发同一份数据。
- 学期/排名切换通过 `choices` 声明；原生层调用 `perform(actionId, value)` 后，脚本操作页面控件或请求对应数据，并再次 `publish()` 完整结果。
- 可直接读 DOM，也可调用官网自己的只读接口（仅 HTTPS、GET/HEAD 或必要的只读查询 POST）。
- 没有数据时也要发布可读的空状态 `text`，不能只发空壳。

## 四、PagePayload 数据格式

```ts
type PagePayload = {
  title: string;
  sourceUrl: string;
  choices?: {id: string; label: string; value: string;
               options: {value: string; label: string}[]}[];
  actions?: {id: string; label: string; value: string}[];
  sections: Section[];
};
```

**课表 schedule**：

```json
{
  "type": "schedule",
  "semesterStartDate": "2026-09-07",
  "days": [{"name": "周一", "lessons": [{
    "title": "高等数学",
    "schedule": {
      "weeks": "1-16周",
      "startSection": "1", "endSection": "2",
      "teacher": "张老师", "location": "A101",
      "startTime": "08:00", "endTime": "09:35"
    }
  }}]}
}
```

**成绩 / 考试 cards**：把页面可见字段全部放进 `fields`，不要只给行号：

```json
{
  "type": "cards",
  "title": "课程成绩",
  "cards": [{
    "title": "高等数学", "subtitle": "必修",
    "fields": [
      {"label": "成绩", "value": "95"},
      {"label": "学分", "value": "4"},
      {"label": "绩点", "value": "4.5"}
    ]
  }]
}
```

考试同样用 `cards`（字段如考试时间、地点、座位号）；官网本身就是表格时可用 `table`：`headers: string[]` + `rows: string[][]`，每行必须有实际内容。

**培养方案 program**：模块通过 `children` 递归，`courses` 与 `headers` 对齐：

```json
{
  "type": "program",
  "requiredCredits": "160",
  "completedCredits": "96",
  "modules": [{
    "id": "public-basic",
    "title": "公共基础课",
    "depth": 1,
    "status": "36 / 40 学分",
    "requirements": ["应修 40 学分", "已完成 36 学分"],
    "headers": ["课程", "学分", "状态"],
    "courses": [["大学英语", "2", "已完成"]],
    "children": []
  }]
}
```

其余通用 section：`text`、`fields`、`stats`、`links`。

## 五、自测清单

导入时 App 已自动校验 JSON/JS 语法、HTTPS 地址、作者信息、四个 `nativeType` 齐全和引擎步骤合法性。真机上再逐项确认：

1. 四个重绘入口都能显示**真实内容**（不是空壳或整页 innerText），下拉刷新后发布最新完整结果。
2. 学期切换（choices/perform）可用，切换后重新发布。
3. 普通功能项能正常打开官网页面，登录态保持正常。
4. 后台"立即检查"能解析出学期 ID、学生 ID，课表/成绩/考试日志显示的是解析后的 JSON。
5. 日历导出的节次时间与实际作息一致（重点看多校区、晚课、跨节次）。
6. 规则文件里不含账号、Cookie、Token 或真实个人数据。

## 六、方式②：提交 PR 上云，分发给所有用户（可选）

本地规则在真机上验证稳定后，如希望所有用户直接选用，可向仓库提交 Pull Request。PR 审查合并到 `main` 后，安卓与 iOS 用户在"选择学校"页点右上角**刷新**，就会从仓库拉到新学校，无需手动传文件。

提交步骤：

1. 把 JSON 放到 `app/src/main/assets/schools/<id>.json`，JS 放到 `app/src/main/assets/adapters/<id>-reader.js`，作息移到 `app/src/main/assets/schools/index.json` 的注册项 `readerConfig` 中。
2. **两端资源都要更新**：同两份文件复制到 iOS 工程的 `iosApp/Resources/schools/` 与 `iosApp/Resources/adapters/`，并在两端 `index.json` 注册（iOS 端云端刷新读取的是这份资源）。
3. 本地运行 `node tools/validate-adapters.mjs` 通过校验。
4. 一个 PR 只新增一所学校；不要提交任何个人凭据、密码、Cookie 或真实个人数据。审查流程见 [CONTRIBUTING.md](../CONTRIBUTING.md)。
