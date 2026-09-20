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

提交前在仓库根目录执行：

```powershell
node tools/validate-adapters.mjs
```

该命令不构建 App，会检查 JSON、文件引用、作者邮箱、HTTPS 地址、默认作息、节次时间格式、菜单结构和 JavaScript 语法。PR 创建后，GitHub Actions 会再次执行同一检查；检查通过后才进入人工审核。

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

## 审核与合并

1. 自动检查必须通过；失败原因会直接显示在 PR 的 Checks 中。
2. `CODEOWNERS` 会请求维护者审核学校配置和适配器。
3. 人工审核重点检查登录域名、外部网络请求、写操作、隐私数据和课表导出时间。
4. `main` 已启用分支保护：要求分支保持最新、自动检查通过、至少一名代码所有者批准、所有讨论解决，并禁止强推和删除。仓库管理员保留紧急维护的绕过权限。
5. 合并后配置立即进入 `main`，用户可在学校选择页点击刷新获取；不需要等待新版 APK。

自动校验不能证明学校页面解析一定正确，因此真实登录、各 `quick` 页面和导出文件仍需由提交者人工验证。

完整字段和 JavaScript 接口见 [`docs/ADAPTER_GUIDE.md`](docs/ADAPTER_GUIDE.md)。
