$ErrorActionPreference = "Stop"

$workspace = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$sdkRoot = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $env:LOCALAPPDATA "Android\Sdk" }
$adb = Join-Path $sdkRoot "platform-tools\adb.exe"
$apk = Join-Path $workspace "app\build\outputs\apk\debug\app-debug.apk"
$server = Join-Path $PSScriptRoot "server.py"
$package = "cn.edu.cupk.portalreader"

if (-not (Test-Path -LiteralPath $adb)) { throw "未找到 adb: $adb" }
if (-not (& $adb devices | Select-String "\sdevice$")) { throw "没有运行中的 Android 模拟器" }

& (Join-Path $workspace "gradlew.bat") :app:assembleDebug
if ($LASTEXITCODE -ne 0) { throw "Debug APK 构建失败" }

$python = (Get-Command python.exe).Source
$serverProcess = Start-Process -FilePath $python -ArgumentList @($server, "--port", "18080") -WindowStyle Hidden -PassThru
try {
    Start-Sleep -Seconds 1
    Invoke-RestMethod "http://127.0.0.1:18080/__test/scenario?name=reset" | Out-Null
    & $adb reverse tcp:18080 tcp:18080
    & $adb install -r $apk
    & $adb shell pm clear $package | Out-Null
    & $adb shell pm grant $package android.permission.POST_NOTIFICATIONS
    # A foreground service may only be enabled while the app is in an allowed foreground state.
    & $adb shell am start -W -n "$package/.MainActivity" | Out-Null
    & $adb shell am broadcast -a "$package.DEBUG_PREPARE" -n "$package/.DebugPollReceiver"

    function Invoke-Poll([string]$scenario) {
        if ($scenario) {
            Invoke-RestMethod "http://127.0.0.1:18080/__test/scenario?name=$scenario" | Out-Null
        }
        & $adb shell am broadcast -a "$package.DEBUG_RUN_POLL" -n "$package/.DebugPollReceiver" | Out-Null
        Start-Sleep -Seconds 3
    }

    Invoke-Poll ""
    Invoke-Poll "schedule_publish"
    Invoke-Poll "schedule_change"
    Invoke-Poll "grade_publish"
    Invoke-Poll "exam_publish"
    Invoke-Poll "auth_expire"

    $notifications = (& $adb shell dumpsys notification --noredact) -join "`n"
    $services = (& $adb shell dumpsys activity services $package) -join "`n"
    $failures = [System.Collections.Generic.List[string]]::new()
    $expected = @("课表变动", "成绩变动", "考试变动", "教务登录已过期")
    foreach ($title in $expected) {
        if ($notifications.Contains($title)) { Write-Host "PASS notification: $title" }
        else { Write-Host "FAIL notification: $title"; $failures.Add($title) }
    }
    if ($notifications.Contains("掌上教务后台监测运行中")) {
        Write-Host "PASS keep-alive notification is visible"
    } else {
        Write-Host "FAIL keep-alive notification is missing"
        $failures.Add("keep-alive notification")
    }
    if ($services.Contains("PortalKeepAliveService") -and $services.Contains("isForeground=true")) {
        Write-Host "PASS keep-alive service is foreground"
    } else {
        Write-Host "FAIL keep-alive service is not foreground"
        $failures.Add("foreground service")
    }

    $pidBefore = ((& $adb shell pidof $package) -join "").Trim()
    & $adb shell input keyevent KEYCODE_HOME
    Start-Sleep -Seconds 2
    & $adb shell am kill $package
    Start-Sleep -Seconds 5
    $pidAfter = ((& $adb shell pidof $package) -join "").Trim()
    $servicesAfter = (& $adb shell dumpsys activity services $package) -join "`n"
    if ($pidBefore -and $pidAfter -and $servicesAfter.Contains("isForeground=true")) {
        Write-Host "PASS keep-alive survives background process reclamation"
    } else {
        Write-Host "FAIL keep-alive did not survive background process reclamation"
        $failures.Add("background keep-alive")
    }
    if ($failures.Count -gt 0) { throw "测试失败: $($failures -join ', ')" }
}
finally {
    Stop-Process -Id $serverProcess.Id -ErrorAction SilentlyContinue
}
