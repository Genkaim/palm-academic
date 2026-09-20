# 贡献学校适配

学校适配建议统一通过 GitHub Pull Request 提交。适配 JavaScript 会在用户已登录的教务页面中执行，因此所有代码必须公开审查并只从本仓库的 `main` 分支分发。

## 提交流程

1. Fork 本仓库并同步最新 `main`。
2. 创建 `adapter/<school-id>` 分支，例如 `adapter/example-university`。
3. 新增或修改以下文件：
   - `app/src/main/assets/schools/index.json`
   - `app/src/main/assets/schools/<school-id>.json`
   - `app/src/main/assets/adapters/<school-id>-reader.js`
4. 按 PR 模板填写验证结果后，向本仓库的 `main` 分支发起 Pull Request。

一个 PR 应只包含一所学校的适配。修复已有适配时使用 `fix/adapter-<school-id>` 分支，并在 PR 中说明受影响页面。

## 作者联系方式

每个学校定义必须提供：

```json
"author": {
  "name": "GitHub 用户名或姓名",
  "email": "author@example.com"
}
```

邮箱用于适配失效时联系维护者，会公开保存在仓库中。可以使用 GitHub 隐私邮箱，避免公开私人邮箱。

## 提交范围

- `id` 和文件名使用小写字母、数字及连字符。
- 使用学校正式 HTTPS 教务地址，不加入测试网址、代理或第三方转发地址。
- 不修改无关 Android 代码；若新学校需要不同登录协议，请先开 Issue 讨论。
- 不加入混淆、压缩后的 JavaScript，也不加载仓库之外的远程脚本。
- 不实现选课、退课、申请提交等写操作。
- 不提交账号、密码、Cookie、Token、学号或任何真实个人教务数据。

## 提交前验证

- JSON 可以正常解析，`readerAdapter` 引用存在。
- 登录、首页和所有标为 `quick: true` 的页面均已检查。
- 学期切换后会重新发布页面数据。
- `scheduleProfiles[].unitTimes` 覆盖所有节次并含默认 profile。
- 已实际检查 iCalendar 和 WakeUp CSV 导出的上课时间。
- 适配器只读取当前学校域名的数据，不上传用户数据。

完整字段和 JavaScript 接口见 [`docs/ADAPTER_GUIDE.md`](docs/ADAPTER_GUIDE.md)。
