# 学校适配指南

PalmAcademic 的 Android 渲染层与学校网页解析逻辑彼此独立。每所学校必须拥有一个定义文件和一个完整、独立的脚本；脚本不得依赖其他学校的脚本。

```text
app/src/main/assets/
├── schools/
│   ├── index.json          # 内置与本地导入学校索引
│   └── <school>.json       # 该校页面、监测接口和脚本引用
└── adapters/
    └── <school>-reader.js  # 该校全部四个快捷入口的读取逻辑
```

合并到仓库 `main` 分支后，用户可在 App 的“选择学校”页面刷新内置规则；刷新不会覆盖本地导入规则。

## 1. 注册学校

在 `schools/index.json` 的 `builtIn` 数组添加学校。`imported` 只由 App 管理，在线/App 更新不得写入或清空它。

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

## 2. 定义菜单与监测接口

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
    "courseDataPathTemplate": "/for-std/course-table/get-data?semesterId={semesterId}",
    "gradePath": "/for-std/grade/sheet",
    "examPath": "/for-std/exam-arrange",
    "semesterIdPatterns": ["[\"']semesterId[\"']\\s*:\\s*[\"']?(\\d+)"]
  },
  "groups": []
}
```

`path` 和监测路径可为相对 `baseUrl` 的路径或完整 HTTPS URL。`courseDataPathTemplate` 必须含 `{semesterId}`；`semesterIdPatterns` 是按顺序匹配当前学期 ID 的正则，第一组捕获值必须是学期 ID。不同登录协议仍需同步扩展 Android 的登录实现。

## 3. 四个快捷入口

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

## 4. 单脚本接口

宿主在页面完成后注入 `PalmAcademicHost`。一个学校的脚本必须自行包含四个快捷入口所需的 DOM/API 解析、学期切换和发布逻辑，不得 `import`、拼接或调用另一所学校的适配脚本。

```js
window.PalmAcademicHost = {
  apiVersion: 1,
  schoolConfig: {},
  publish(payload) {}
};

window.PalmAcademicAdapter = {
  apiVersion: 1,
  read(),
  publish(),
  perform(actionId, value)
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

## 5. 四类数据格式

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

培养方案使用 `program`，`modules` 可递归嵌套：

```json
{
  "type": "program",
  "requiredCredits": "160",
  "completedCredits": "96",
  "modules": [{
    "title": "公共基础课",
    "requiredCredits": "40",
    "completedCredits": "36",
    "courses": [{"title":"大学英语","status":"已完成","credits":"2"}],
    "modules": []
  }]
}
```

通用 section 还包括 `text`、`fields`、`table`、`cards`、`stats`、`links`。空状态也要发布可读的 `text`，不能仅发布空索引。

## 6. 网页和数据如何提供

- `sourceUrl` 使用当前实际页面 URL；入口 `path` 负责让隐藏 WebView 打开正确网页。
- 可从 DOM 读取，也可复用官网的只读 API；只允许 HTTPS、GET/HEAD 及必要的只读查询 POST。
- 页面异步加载时等待目标 DOM/API 完成后再 `publish()`；可用带防抖的 `MutationObserver`。
- 学期选择放在 `choices`。Android 调用 `perform(actionId, value)` 后，脚本更新官网控件或请求对应数据，并再次发布完整结果。
- 不得读取、记录、上传或输出 Cookie、密码、Token；不得执行选课、退课、提交申请等写操作。
- 后台检查的 `monitor` 路径必须由该校定义提供，Android 不硬编码某个学校的表格 class 或接口地址。

## 7. 本地规则包

“选择学校 → 导入本地规则”接收一个 JSON 文件。App 会为它生成独立的定义和脚本路径，并写入索引的 `imported` 字段。

```json
{
  "schemaVersion": 1,
  "profile": {
    "id": "example-local",
    "name": "示例大学（本地）",
    "origin": "https://jw.example.edu.cn",
    "readerConfig": {"scheduleProfiles": [{"locationPattern":"","unitTimes":{"1":["08:00","08:45"]}}]}
  },
  "definition": {
    "schemaVersion": 1,
    "id": "example-local-eams",
    "name": "示例大学（本地）",
    "author": {"name":"local","email":"local@example.com"},
    "baseUrl": "https://jw.example.edu.cn/student",
    "readerAdapter": "adapters/placeholder.js",
    "auth": {},
    "monitor": {
      "coursePagePath":"/course-table",
      "courseDataPathTemplate":"/course-table/data?semesterId={semesterId}",
      "gradePath":"/grade",
      "examPath":"/exam"
    },
    "groups": [{
      "title":"快捷入口",
      "items":[
        {"title":"课表","path":"/course-table","quick":true,"nativeType":"schedule"},
        {"title":"成绩","path":"/grade","quick":true,"nativeType":"grade"},
        {"title":"考试","path":"/exam","quick":true,"nativeType":"exam"},
        {"title":"培养方案","path":"/program","quick":true,"nativeType":"program"}
      ]
    }]
  },
  "adapterScript": "(function(){ /* 完整独立脚本 */ })();"
}
```

文件上限 2 MB。再次导入同一 `id` 会替换该本地规则，但不能覆盖内置学校。

## 8. 提交前检查

1. 运行 `node tools/validate-adapters.mjs`，确保索引、定义和脚本通过校验。
2. 四个 `nativeType` 均能发布包含实际内容的非空数据，学期切换后会重新发布。
3. 普通网页入口可以打开；重绘与非重绘功能边界符合第 3 节。
4. 实测 `.ics` 与 WakeUp CSV，重点检查多校区、晚课、周次和跨节课程。
5. 一个 PR 只新增一所学校的索引项、定义和完整脚本，不提交账号、Cookie、真实课表或其他个人信息。

推荐通过 GitHub Pull Request 提交，以便逐行审查并单独回滚。详细流程见 [`CONTRIBUTING.md`](../CONTRIBUTING.md)。
