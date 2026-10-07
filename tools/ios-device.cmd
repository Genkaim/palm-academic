@echo off
REM Inspects a connected iPhone from the command line: screenshots, live logs,
REM installed apps, crash reports.
REM
REM What this gives you:
REM   screenshots  - pymobiledevice3 developer dvt screenshot <file>
REM   live logs     - pymobiledevice3 syslog live -m <keyword>
REM   installed apps- pymobiledevice3 apps list
REM   crash reports - pymobiledevice3 crash pull <dir>
REM
REM Run with no arguments to install, verify the connection and mount the developer disk
REM image. Pass a subcommand to forward straight to pymobiledevice3:
REM   ios-device.cmd shot my.png          take a screenshot
REM   ios-device.cmd log PalmAcademic     stream logs matching a keyword
REM
REM Two things worth knowing, because both cost real time to rediscover:
REM
REM   1. This uses a dedicated virtualenv, not your system Python. pymobiledevice3's
REM      download of the developer image goes through requests/urllib3, and a version
REM      mismatch there breaks the TLS stream mid-transfer. The venv pins a matched set.
REM
REM   2. The developer image is cached under %TEMP%\iosdevice\ddi and fetched with curl
REM      using resume, not by Python. The same flaky TLS path is what makes Python's own
REM      download fail partway through a 15 MB file; curl recovers from it. Once cached,
REM      mounting needs no network at all.
REM
REM Nothing here modifies the device beyond what Developer Mode already implies. The
REM developer image is Apple's own, pulled over the network, and is what allows screenshots
REM to be taken at all.

setlocal enabledelayedexpansion

set "VENVPY=%TEMP%\iosdevice\venv\Scripts\python.exe"
set "BINDIR=%TEMP%\iosdevice"
set "DDIDIR=%BINDIR%\ddi"
set "DDI_BASE=https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized"

REM The venv lives on %TEMP% next to this script's output, not in the runtime directory,
REM so clearing %TEMP% is the one thing that undoes it.
if not exist "%VENVPY%" (
    echo Creating the isolated environment ^(first run only^)...
    set "BASEPY="
    for %%P in (
        "C:\Users\cxh20\.workbuddy\binaries\python\versions\3.13.12\python.exe"
        "C:\Python313\python.exe"
        "python"
    ) do (
        if not defined BASEPY (
            %%~P -c "import sys" >nul 2>&1
            if not errorlevel 1 set "BASEPY=%%~P"
        )
    )
    if not defined BASEPY (
        echo Python not found. Install Python 3.10 or newer and run this again.
        pause
        exit /b 1
    )
    "%BASEPY%" -m venv "%BINDIR%\venv"
    if errorlevel 1 (
        echo Could not create the virtual environment.
        pause
        exit /b 1
    )
    "%VENVPY%" -m pip install --upgrade pip --quiet
    "%VENVPY%" -m pip install --upgrade pymobiledevice3
    if errorlevel 1 (
        echo.
        echo Install failed. Check the network and try again.
        pause
        exit /b 1
    )
)

if "%~1"=="" goto setup
if /i "%~1"=="shot" goto do_shot
if /i "%~1"=="log" goto do_log
if /i "%~1"=="apps" goto do_apps
if /i "%~1"=="crash" goto do_crash
if /i "%~1"=="shell" goto do_shell

rem Anything else is passed straight through.
"%VENVPY%" -W ignore -m pymobiledevice3 %*
exit /b %errorlevel%

:setup
echo ==========================================================
echo  Checking the connection
echo ==========================================================
echo.
"%VENVPY%" -W ignore -m pymobiledevice3 version
echo.
echo Devices on USB:
"%VENVPY%" -W ignore -m pymobiledevice3 usbmux list
echo.

echo Unlock the iPhone if it is locked, and tap Trust if asked.
echo.

REM ---------------------------------------------------------------- DDI cache
echo ==========================================================
echo  Developer disk image
echo ==========================================================
echo.
if not exist "%DDIDIR%" mkdir "%DDIDIR%" 2>nul

if not exist "%DDIDIR%\Image.dmg" (
    echo Fetching the developer image ^(about 15 MB, resumable^)...
) else (
    echo Developer image already cached, mounting from disk.
)

REM Each file is fetched with curl rather than Python. The transfer is resumable, so
REM the occasional dropped connection costs a retry instead of the whole file.
set "DDI_FILES=Image.dmg BuildManifest.plist Image.dmg.trustcache"
for %%F in (%DDI_FILES%) do (
    if not exist "%DDIDIR%\%%F" (
        echo   downloading %%F ...
        curl -sSL -C - --retry 8 --retry-all-errors --retry-delay 3 --max-time 900 ^
            -o "%DDIDIR%\%%F" "%DDI_BASE%/%%F"
    )
)

if not exist "%DDIDIR%\Image.dmg" (
    echo.
    echo Could not download the developer image, so screenshots will not work.
    echo Everything else below still works. Re-run once the network is steadier.
    goto ready
)

echo.
echo Mounting...
"%VENVPY%" -W ignore -m pymobiledevice3 mounter mount-personalized ^
    "%DDIDIR%\Image.dmg" "%DDIDIR%\Image.dmg.trustcache" "%DDIDIR%\BuildManifest.plist"
if errorlevel 1 (
    echo.
    echo Mounting failed. If the device rebooted, unlock it and re-run.
    goto ready
)

:ready
echo.
echo ==========================================================
echo  Ready
echo ==========================================================
echo.
echo   Screenshot : "%~f0" shot screen.png
echo   Live logs   : "%~f0" log PalmAcademic
echo   App list    : "%~f0" apps
echo   Crash logs  : "%~f0" crash
echo   Anything else is forwarded, e.g. "%~f0" help
echo.
pause
exit /b 0

:do_shot
if "%~2"=="" (
    set "OUT=%BINDIR%\screen.png"
) else (
    set "OUT=%~2"
)
if not exist "%OUT%\..\" mkdir "%OUT%\.." 2>nul
REM Screenshots are a developer command on iOS 17+, so they go over the userspace
REM tunnel. That needs no admin rights, unlike the kernel tunnel.
"%VENVPY%" -W ignore -m pymobiledevice3 developer dvt screenshot --userspace "%OUT%"
if errorlevel 1 (
    echo.
    echo Screenshot failed. Run this script without arguments first to mount the
    echo developer image, and confirm Developer Mode is on in the device settings.
) else (
    echo Saved to %OUT%
)
exit /b %errorlevel%

:do_log
if "%~2"=="" (
    "%VENVPY%" -W ignore -m pymobiledevice3 syslog live
) else (
    "%VENVPY%" -W ignore -m pymobiledevice3 syslog live -m %~2
)
exit /b %errorlevel%

:do_apps
"%VENVPY%" -W ignore -m pymobiledevice3 apps list
exit /b %errorlevel%

:do_crash
if "%~2"=="" (
    set "OUT=%BINDIR%\crashes"
) else (
    set "OUT=%~2"
)
mkdir "!OUT!" 2>nul
"%VENVPY%" -W ignore -m pymobiledevice3 crash pull "!OUT!"
echo Crash reports written to !OUT!
exit /b %errorlevel%

:do_shell
"%VENVPY%" -W ignore -m pymobiledevice3 %2 %3 %4 %5 %6 %7 %8 %9
exit /b %errorlevel%