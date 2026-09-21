# 学校适配指南

PalmAcademic 的 Android 渲染层与学校网页解析逻辑彼此独立。每所学校必须拥有一个定义文件和一个完整、独立的脚本；脚本不得依赖其他学校的脚本。

## 适配主线：只需要重点编写两份文件

| 文件 | 负责什么 | 不负责什么 |
|---|---|---|
| `schools/<school>.json` | 学校名称、域名、作者、菜单入口、四个重绘入口、后台检查接口、学期/学生 ID 提取规则，以及 adapter 路径 | 不解析网页 DOM，不拼装原生页面数据 |
| `adapters/<school>-reader.js` | 读取该校四个快捷入口的 DOM/只读 API，把课表、成绩、考试、培养方案转换成统一 `PagePayload`，处理学期选择等只读操作 | 不决定学校域名和菜单，不依赖其他学校脚本 |

`schools/index.json` 只负责注册学校并提供作息 `readerConfig`，不是主要适配逻辑。建议按以下顺序完成：

1. 在 `index.json` 注册学校和作息。
2. 编写该校 `school.json`，先保证所有普通入口 URL 和四个快捷入口正确。
3. 在同一份 `school.json` 中配置 `monitor`，用真实响应确认课表、成绩、考试接口能返回实际数据。
4. 编写该校独立 `adapter.js`，依次完成 `schedule`、`grade`、`exam`、`program` 四类页面。
5. 运行校验并分别测试普通网页、原生重绘、下拉刷新、学期切换、后台检查日志和课表导出。

两条数据链路不要混淆：

```text
用户打开四个快捷入口
  school.json 的 groups.path -> 隐藏 WebView -> adapter.js 解析并 publish -> Android 原生重绘

后台定时检查
  school.json 的 monitor -> Android 请求只读数据接口 -> 解析成前后 JSON -> 判断变化/记录日志
```

也就是说，adapter 决定“页面如何显示”，school JSON 的 `monitor` 决定“后台如何检查”。后台任务不会执行 adapter。

```text
app/src/main/assets/
├── schools/
│   ├── index.json          # 内置学校索引
│   └── <school>.json       # 该校页面、监测接口和脚本引用
└── adapters/
    └── <school>-reader.js  # 该校全部四个快捷入口的读取逻辑
```

合并到仓库 `main` 分支后，用户可在 App 的“选择学校”页面刷新规则。App 不提供本地规则导入；适配必须经仓库审查后进入内置索引。

## 1. 注册学校

在 `schools/index.json` 的 `builtIn` 数组添加学校。schema v2 中的 `imported` 是旧版本兼容字段，必须保持空数组，当前 App 不读取它。

```json
{
  "schemaVersion": 2,
  "configVersion": 2,
  "builtIn": [
    {
      "id": "example-university",
      "name": "示例大学",
      "origin": "https://jw.example.edu.cn",
      "definitionAsset": "schools/example-university.json",
      "readerConfig": {
        "scheduleProfiles": [
          {
            "locationPattern": "",
            "unitTimes": {
              "1": ["08:00", "08:45"],
              "2": ["08:50", "09:35"]
            }
          }
        ]
      }
    }
  ],
  "imported": []
}
```

- `id` 仅使用小写字母、数字和连字符，仓库内唯一。
- `origin` 必须是 HTTPS，不包含末尾 `/student`。
- 每所学校使用独立的 `definitionAsset` 和 `readerAdapter`。
- `scheduleProfiles` 必须包含 `locationPattern: ""` 的默认作息；节次时间使用 24 小时制。多校区按地点正则从具体到默认排列。
- 作息会用于原生课表、iCalendar 和 WakeUp CSV，必须覆盖该校全部节次并实际检查导出时间。

## 2. 编写 school JSON：定义入口与后台检查

```json
{
  "schemaVersion": 1,
  "id": "example-eams",
  "name": "示例大学",
  "author": {"name": "adapter-author", "email": "author@example.com"},
  "baseUrl": "https://jw.example.edu.cn/student",
  "readerAdapter": "adapters/example-reader.js",
  "auth": {
    "type": "salted-sha1",
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
  "groups": [{
    "title": "快捷入口",
    "items": [
      {"title":"我的课表","path":"/for-std/course-table","quick":true,"nativeType":"schedule"},
      {"title":"课程成绩","path":"/for-std/grade/sheet","quick":true,"nativeType":"grade"},
      {"title":"考试信息","path":"/for-std/exam-arrange","quick":true,"nativeType":"exam"},
      {"title":"培养方案","path":"/for-std/program-completion-preview","quick":true,"nativeType":"program"}
    ]
  }]
}
```

主要字段的职责：

| 字段 | 写法 |
|---|---|
| `id` / `name` / `author` | 该校定义标识、显示名和维护者联系方式；`id` 在仓库内唯一 |
| `baseUrl` | 教务系统学生端基地址，必须为 HTTPS |
| `readerAdapter` | 指向该校唯一且完整的 `adapters/<school>-reader.js` |
| `auth` | 登录协议说明；当前只是元数据，新协议仍需扩展 Android 登录实现 |
| `groups` | 首页菜单；普通入口只写 `title`/`path`，四个重绘入口额外写 `quick: true` 和 `nativeType` |
| `monitor` | 后台检查的数据接口模板，以及从入口页/最终 URL 提取学期 ID、学生 ID 的正则 |

`path` 和监测路径可为相对 `baseUrl` 的路径或完整 HTTPS URL。`courseDataPathTemplate` 必须含 `{semesterId}`，需要学生 ID 的接口使用 `{studentId}`。`semesterIdPatterns` 与 `studentIdPatterns` 会按顺序匹配入口页面内容和最终 URL，每个正则的第一组捕获值必须分别是学期 ID、学生 ID。

后台检查必须请求真正包含数据的只读接口，不能只填写菜单入口页。课表接口应返回课程/教学班/安排，成绩接口应返回实际成绩行，考试接口应返回实际考试行。日志只保存解析后的前后 JSON 用于肉眼比较，不保存完整 HTML；请求状态、最终 URL 和脱敏后的诊断信息单独记录。接口结构不同的学校只修改自己的定义与独立脚本，Android 通用层不写学校域名、表格 class 或固定 ID。

当前 Android 登录实现支持项目已有的 salted-SHA1 流程。`auth` 仅用于说明适配所需协议，尚不会自动生成新的登录实现；不同登录协议仍需同步扩展 Android 登录代码。

### school JSON 中的四个快捷入口

每所学校必须各提供一次下列 `nativeType`。四者都由同一个该校脚本读取并原生重绘。

| `nativeType` | 推荐标题 | 必须提供的核心数据 |
|---|---|---|
| `schedule` | 我的课表 | 学期、开学日期、星期、课程名、周次、节次、地点、教师 |
| `grade` | 课程成绩 | 课程名、成绩及页面可见的学分、绩点、课程性质等字段 |
| `exam` | 考试信息 | 课程名、日期时间、地点、座位等页面可见字段 |
| `program` | 培养方案完成情况 | 学分统计与可递归展开的模块、课程完成状态 |

```json
{"title":"我的课表","path":"/course-table","quick":true,"nativeType":"schedule"}
```

非重绘功能不设置 `quick`/`nativeType`，App 直接打开官网页面。选课、申请、查询等普通页面只需提供正确 `path`；不得在适配脚本里自动执行写操作。

## 3. 编写 adapter JS：解析并发布四个页面

宿主在页面完成后注入 `PalmAcademicHost`。一个学校的脚本必须自行包含四个快捷入口所需的 DOM/API 解析、学期切换和发布逻辑，不得 `import`、拼接或调用另一所学校的适配脚本。

```ts
type PalmAcademicHost = {
  apiVersion: 1;
  schoolConfig: Record<string, unknown>;
  publish: (payload: PagePayload) => void;
};

type PalmAcademicAdapter = {
  apiVersion: 1;
  read: () => PagePayload;
  publish: () => void;
  perform: (actionId: string, value: string) => boolean;
};
```

最小发布结构：

```js
(function () {
  if (!window.PalmAcademicHost || window.PalmAcademicAdapter) return;
  function read() {
    return {
      title: document.title,
      sourceUrl: location.href,
      choices: [],
      actions: [],
      sections: [{type: "text", title: "内容", paragraphs: [document.body.innerText.trim()]}]
    };
  }
  function publish() { PalmAcademicHost.publish(read()); }
  function perform() { return false; }
  window.PalmAcademicAdapter = {apiVersion: 1, read, publish, perform};
  publish();
})();
```

一份 adapter 推荐按下面的结构组织，四类逻辑必须都在当前文件内：

```js
function schedulePage() { /* 读取课表 DOM/API，返回 PagePayload */ }
function gradePage() { /* 读取实际成绩内容，不能只返回行号 */ }
function examPage() { /* 读取课程、时间、地点、座位等 */ }
function programPage() { /* 读取学分统计、模块和课程 */ }

function read() {
  const path = location.pathname;
  if (path.includes('/course-table')) return schedulePage();
  if (path.includes('/grade')) return gradePage();
  if (path.includes('/exam')) return examPage();
  if (path.includes('/program')) return programPage();
  return {title: document.title, sourceUrl: location.href, sections: []};
}
```

- `read()`：只读取当前页面状态并返回完整 `PagePayload`，不得产生写操作。
- `publish()`：调用 `PalmAcademicHost.publish(read())`；页面异步变化后必须再次发布完整结果。
- `perform(actionId, value)`：处理学期选择、排名类型等只读交互，完成后触发页面/API 更新并再次 `publish()`。
- `MutationObserver`：仅用于等待异步 DOM，必须防抖，避免连续发布相同数据。
- 四个 page 函数可以共享当前文件内的工具函数，但不能加载或复制依赖另一所学校的脚本。

## 4. adapter 发布的四类数据格式

所有入口发布统一的 `PagePayload`：

```ts
type PagePayload = {
  title: string;
  sourceUrl: string;
  choices?: {id:string; label:string; value:string; options:{value:string; label:string}[]}[];
  actions?: {id:string; label:string; value:string}[];
  sections: Section[];
};
```

课表使用 `schedule` section：

```json
{
  "type": "schedule",
  "semesterStartDate": "2026-09-07",
  "days": [{
    "name": "周一",
    "lessons": [{
      "title": "高等数学",
      "schedule": {
        "weeks": "1-16周",
        "startSection": "1",
        "endSection": "2",
        "teacher": "教师",
        "location": "A101",
        "startTime": "08:00",
        "endTime": "09:35"
      }
    }]
  }]
}
```

成绩与考试优先使用 `cards`，把网页可见字段全部放入 `fields`，不要只返回行号或数组索引：

```json
{
  "type": "cards",
  "title": "课程成绩",
  "cards": [{
    "title": "高等数学",
    "subtitle": "必修",
    "fields": [
      {"label":"成绩","value":"95"},
      {"label":"学分","value":"4"},
      {"label":"绩点","value":"4.5"}
    ]
  }]
}
```

考试同样使用 `cards`，例如字段 `考试时间`、`地点`、`座位号`。如官网天然为表格，也可使用 `table`：`headers: string[]` 与 `rows: string[][]`，但每一行必须包含实际内容。

培养方案使用 `program`。顶层 `modules` 中的模块通过 `children` 递归；`courses` 必须是与 `headers` 对齐的二维字符串数组：

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

通用 section 还包括 `text`、`fields`、`table`、`cards`、`stats`、`links`。空状态也要发布可读的 `text`，不能仅发布空索引。

## 5. adapter 如何取得网页和数据

- `sourceUrl` 使用当前实际页面 URL；入口 `path` 负责让隐藏 WebView 打开正确网页。
- 可从 DOM 读取，也可复用官网的只读 API；只允许 HTTPS、GET/HEAD 及必要的只读查询 POST。
- 页面异步加载时等待目标 DOM/API 完成后再 `publish()`；可用带防抖的 `MutationObserver`。
- 学期选择放在 `choices`。Android 调用 `perform(actionId, value)` 后，脚本更新官网控件或请求对应数据，并再次发布完整结果。
- 不得读取、记录、上传或输出 Cookie、密码、Token；不得执行选课、退课、提交申请等写操作。
- 后台检查的 `monitor` 路径必须由该校定义提供，Android 不硬编码某个学校的表格 class 或接口地址。

## 6. 提交前检查

1. 运行 `node tools/validate-adapters.mjs`，确保索引、定义和脚本通过校验。
2. 四个 `nativeType` 均能发布包含实际内容的非空数据，学期切换后会重新发布；所有原生重绘页面下拉刷新后也必须发布最新完整结果。
3. 用真实账号确认后台检查的学生 ID、学期 ID 均能解析，课表/成绩/考试日志能显示解析后的前后 JSON，而不是索引、空壳对象或完整 HTML。
4. 普通网页入口可以打开；重绘与非重绘功能边界符合第 3 节。
5. 实测 `.ics` 与 WakeUp CSV，重点检查多校区、晚课、周次和跨节课程。
6. 一个 PR 只新增一所学校的索引项、定义和完整脚本，不提交账号、Cookie、真实课表或其他个人信息。

推荐通过 GitHub Pull Request 提交，以便逐行审查并单独回滚。详细流程见 [`CONTRIBUTING.md`](../CONTRIBUTING.md)。
