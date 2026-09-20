$ErrorActionPreference = "Stop"

$workspace = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$sdkRoot = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $env:LOCALAPPDATA "Android\Sdk" }
$adb = Join-Path $sdkRoot "platform-tools\adb.exe"
$apk = Join-Path $workspace "app\build\outputs\apk\debug\app-debug.apk"
$server = Join-Path $PSScriptRoot "server.py"
$package = "cn.edu.cupk.portalreader"
$receiver = "$package/.DebugAuthReceiver"

if (-not (Test-Path -LiteralPath $adb)) { throw "未找到 adb: $adb" }
if (-not (& $adb devices | Select-String "\sdevice$")) { throw "没有运行中的 Android 模拟器" }

& (Join-Path $workspace "gradlew.bat") :app:assembleDebug
if ($LASTEXITCODE -ne 0) { throw "Debug APK 构建失败" }

$python = (Get-Command python.exe).Source
$serverProcess = Start-Process -FilePath $python -ArgumentList @($server, "--port", "18080") -WindowStyle Hidden -PassThru
try {
    Start-Sleep -Seconds 1
    & $adb reverse tcp:18080 tcp:18080 | Out-Null
    & $adb install -r $apk | Out-Null
    & $adb shell pm clear $package | Out-Null

    function Invoke-LoginCase(
        [string]$name,
        [string]$username,
        [string]$password,
        [bool]$expectedSuccess,
        [string]$expectedMessage
    ) {
        & $adb shell am broadcast -a "$package.DEBUG_TEST_LOGIN" -n $receiver --es username $username --es password $password | Out-Null
        $result = ""
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            Start-Sleep -Milliseconds 500
            $result = (& $adb shell run-as $package cat shared_prefs/debug_auth_result.xml 2>$null) -join "`n"
            if ($result.Contains('value="finished"')) { break }
        }
        $actualSuccess = $result.Contains('name="success" value="true"')
        $messageMatches = -not $expectedMessage -or $result.Contains($expectedMessage)
        if ($actualSuccess -eq $expectedSuccess -and $messageMatches) {
            Write-Host "PASS password login: $name"
        } else {
            throw "密码登录测试失败 [$name]: $result"
        }
    }

    Invoke-LoginCase "correct password" "test" "test" $true ""
    Invoke-LoginCase "wrong password" "test" "wrong" $false "账号或密码错误"
    Invoke-LoginCase "captcha required" "captcha" "test" $false "教务系统要求安全验证"
}
finally {
    Stop-Process -Id $serverProcess.Id -ErrorAction SilentlyContinue
}
