# localhost 教务模拟器

Debug 构建固定连接 `http://127.0.0.1:18080/student`；Release 构建仍连接真实教务站。
Android 模拟器通过 `adb reverse tcp:18080 tcp:18080` 访问电脑 localhost。

运行完整测试：

```powershell
.\tools\mock-eams\run-emulator-tests.ps1
```

脚本会建立首次快照，再依次模拟新课表发布、课表变更、成绩发布、考试新增和鉴权过期，
最后从 Android 通知服务与 ActivityManager 中核对通知标题和前台保活服务。

也可以单独启动网页控制台：

```powershell
python .\tools\mock-eams\server.py
```

浏览器打开 `http://127.0.0.1:18080/` 后，可手动切换每一种测试状态。
