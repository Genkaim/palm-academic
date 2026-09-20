# 学校适配指南

PalmAcademic 的 Android 渲染层与学校网页解析逻辑彼此独立。学校相关内容位于：

```text
app/src/main/assets/
├── schools/
│   ├── index.json          # 学校注册表、域名、作息时间
│   └── <school>.json       # 菜单和阅读适配器引用
└── adapters/
    └── <school>-reader.js  # DOM/API 到 PagePayload 的转换
```

合并到仓库 `main` 分支后，用户可以在 App 的“选择学校”页面点击右上角刷新，不必等待下一版 APK。

## 1. 注册学校

在 `schools/index.json` 的 `schools` 数组添加：

```json
{
  "id": "example-university",
  "name": "示例大学",
  "origin": "https://jw.example.edu.cn",
  "definitionAsset": "schools/example-university.json",
  "readerConfig": {
    "scheduleProfiles": [
      {
        "locationPattern": "东校区",
        "unitTimes": {
          "1": ["08:00", "08:45"],
          "2": ["08:50", "09:35"]
        }
      },
      {
        "locationPattern": "",
        "unitTimes": {
          "1": ["08:30", "09:15"],
          "2": ["09:20", "10:05"]
        }
      }
    ]
  }
}
```

字段要求：

- `id`：仅小写字母、数字和连字符，仓库内唯一。
- `origin`：必须是 HTTPS，不包含末尾 `/student`。
- `definitionAsset`：必须指向 `schools/` 内的 JSON 文件。
- `readerConfig`：原样暴露给阅读适配器的学校级配置。

### 课表导出时间（必须检查）

`scheduleProfiles` 不只是页面显示配置。适配器利用它把“第 1 节”转换为 `startTime/endTime`，Android 导出 iCalendar 和 WakeUp CSV 时也会以默认 profile 的 `unitTimes` 作为回退。

- `locationPattern` 是匹配上课地点的正则表达式，按数组顺序选择第一个匹配项。
- 必须提供一个 `locationPattern: ""` 的默认 profile，建议放在最后。
- 节次 key 必须是字符串，例如 `"1"`；值必须是 24 小时制 `[开始, 结束]`。
- 覆盖学校可能出现的全部节次。遗漏第 11/12 节是最常见的导出错误。
- 多校区作息不同时，为每个校区添加带 `locationPattern` 的 profile，再提供默认 profile。

验证时不要只看 App 课表页面，还应实际导出 `.ics` 和 WakeUp CSV，检查早晚课程的开始、结束时间。

## 2. 定义菜单

新增 `schools/example-university.json`：

```json
{
  "schemaVersion": 1,
  "id": "example-eams",
  "name": "示例大学",
  "baseUrl": "https://jw.example.edu.cn/student",
  "readerAdapter": "adapters/example-reader.js",
  "auth": {
    "type": "salted-sha1",
    "loginPath": "/login",
    "saltPath": "/login-salt",
    "homePath": "/home"
  },
  "groups": [
    {
      "title": "选课与课表",
      "items": [
        {"title": "我的课表", "path": "/for-std/course-table", "quick": true},
        {"title": "选课信息", "path": "/for-std/course-select"}
      ]
    }
  ]
}
```

- `quick: true`：使用隐藏 WebView + JavaScript 适配器读取并由 Android 原生重绘。
- 未设置或为 `false`：直接显示教务官网页面，不需要为该页实现结构化解析。
- `path` 可以是相对 `/student` 的路径，也可以是完整 HTTPS URL。

当前账号密码登录协议仍由 Android 端实现，新增不同登录协议需要同步扩展 `AuthRepository`，不能仅靠 JSON 完成。

## 3. 阅读适配器接口

宿主在页面加载完成后注入：

```js
window.PalmAcademicHost = {
  apiVersion: 1,
  schoolConfig: {/* index.json 中的 readerConfig */},
  publish(payload) {/* 发送给 Android */}
};
```

适配器必须暴露：

```js
window.PalmAcademicAdapter = {
  apiVersion: 1,
  read,                         // 读取当前页面并返回 PagePayload
  publish,                      // 调用 PalmAcademicHost.publish(read())
  perform(actionId, value)      // 响应学期选择等原生 UI 操作
};
```

最小实现：

```js
(function () {
  if (!window.PalmAcademicHost || window.PalmAcademicAdapter) return;

  function read() {
    return {
      title: document.title,
      sourceUrl: location.href,
      choices: [],
      actions: [],
      sections: [{
        type: "text",
        title: "内容",
        paragraphs: [document.body.innerText.trim()]
      }]
    };
  }

  function publish() {
    PalmAcademicHost.publish(read());
  }

  function perform(actionId, value) {
    return false;
  }

  window.PalmAcademicAdapter = {apiVersion: 1, read, publish, perform};
  publish();
})();
```

## 4. PagePayload

顶层结构：

```ts
type PagePayload = {
  title: string;
  sourceUrl: string;
  choices?: Choice[];
  actions?: Action[];
  sections: Section[];
};

type Choice = {
  id: string;
  label: string;
  value: string;
  options: {value: string; label: string}[];
};

type Action = {id: string; label: string; value: string};
```

支持的 section：

| `type` | 必需数据 | 用途 |
|---|---|---|
| `text` | `paragraphs: string[]` | 说明和空状态 |
| `fields` | `fields: {label,value}[]` | 单条详情 |
| `table` | `headers: string[]`, `rows: string[][]` | 普通表格 |
| `cards` | `cards: Card[]` | 成绩、考试等卡片 |
| `stats` | `items: {label,value}[]` | GPA、排名等指标 |
| `links` | `links: {title,url}[]` | 可打开的官网链接 |
| `schedule` | `semesterStartDate`, `days` | 周课表及导出 |
| `program` | 学分与递归 `modules` | 培养方案完成情况 |

`Card` 可包含：

```ts
type Card = {
  title: string;
  subtitle?: string;
  accent?: string;
  fields?: {label: string; value: string}[];
  schedule?: {
    weeks: string;
    startSection: string;
    endSection: string;
    teacher?: string;
    location?: string;
    startTime?: string; // HH:mm
    endTime?: string;   // HH:mm
  };
};
```

课表 section 的 `days` 格式为 `{name, lessons: Card[]}[]`。`semesterStartDate` 应尽量提供 `yyyy-MM-dd`，用于把教学周换算为实际日期。

## 5. 操作与页面更新

当用户在原生 UI 选择学期或点击 action 时，Android 调用：

```js
PalmAcademicAdapter.perform(actionId, value);
```

适配器应更新官网页面控件或请求数据，并在 DOM/数据稳定后再次调用 `publish()`。可使用 `MutationObserver`，但要防抖，避免在页面频繁变动时连续发布。

WebView 只允许 HTTPS，以及 GET/HEAD 和少量只读查询型 POST 路径。适配器不得实现选课、退课、提交申请等写操作。

## 6. 提交前检查

- `index.json` 和学校 JSON 能被标准 JSON 解析器读取。
- 所有远程引用都位于 `schools/` 或 `adapters/`，路径不含 `..`。
- 学校域名使用 HTTPS，登录页、首页和至少一个普通菜单可访问。
- 所有 `quick: true` 页面都能发布非空 `PagePayload`。
- 学期切换后会重新发布内容。
- 课表地点、教师、周次和节次解析正确。
- 导出的 `.ics` 与 WakeUp CSV 时间正确，尤其是多校区和晚课。
- 不在适配器中记录、上传或输出 Cookie、账号、密码及个人教务数据。
