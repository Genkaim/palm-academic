@echo off
REM Force-repair every Swift 6.4.0 component, then verify.
REM
REM Background: a partial install left the Windows Installer component
REM registry claiming files are present while they are absent on disk. The
REM installer therefore reports success and copies nothing. Evidence from the
REM verbose log:
REM     Component: filrmO3w...; Installed: Local; Request: Null; Action: Null
REM 859 components, all Action: Null, and zero "Installing file" lines.
REM
REM Repair mode is used rather than a plain /i. Per MSDN the syntax is
REM     msiexec.exe [/f{p|o|e|d|c|a|u|m|s|v}] <product_code>
REM /fa forces all files to be reinstalled. Exactly one letter is allowed;
REM the letters are alternatives, so passing e.g. /fa /fv /fm together makes
REM msiexec print its help screen. Repair mode also takes a product code
REM directly, so no cached MSI file is needed.
REM
REM If repair mode still reports Action: Null, fall back to
REM scripts\reinstall-swift-toolchain.cmd which uninstalls first.
REM
REM Per-user scope: no elevation required.

setlocal enabledelayedexpansion

set "LOGDIR=%TEMP%\swift-repair2-logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

echo ==========================================================
echo  Stage 1 - force repair all components
echo ==========================================================
echo.

REM Product codes taken from the installer cache directory names.
call :repair "{7C21BB98-B28D-4886-817E-7F7D572BED63}" bld.asserts
call :repair "{1741CDB6-3C96-468E-B8D9-94B83459F843}" cli.asserts
call :repair "{5AD96126-7798-42FF-82E2-8EEEB829B061}" windows
call :repair "{DED24AA5-ADAE-4434-BCB9-B8472D018939}" ide.asserts
call :repair "{95E1B815-7FF7-4CCA-8A4A-28941AED93BD}" dbg.asserts
call :repair "{14A77441-041E-4EA2-8B0A-61BF5D9201E5}" rtl.amd64
call :repair "{A51B9C17-5F77-4A2A-9AE8-198D9B7EC94F}" res
call :repair "{B725DC95-A18C-4F61-A91C-A665E2D51755}" python
call :repair "{BD5D979B-E602-4E81-A389-8ECAE1B21EF4}" android

echo.
echo ==========================================================
echo  Stage 2 - verify
echo ==========================================================
set "TC=%LOCALAPPDATA%\Programs\Swift\Toolchains\6.4.0+Asserts"
set "STDLIB=%TC%\usr\lib\swift\windows"

if exist "!STDLIB!" (
    echo Standard library directory: PRESENT
) else (
    echo Standard library directory: MISSING
)

if exist "!TC!\usr\bin\swiftc.exe" (
    echo swiftc.exe: PRESENT
) else (
    echo swiftc.exe: MISSING
)

REM The decisive test: can the compiler load its own standard library?
echo.
echo Testing the compiler on a trivial program...
set "PROBE=%TEMP%\swift-probe"
if not exist "!PROBE!" mkdir "!PROBE!"
echo print("probe")> "!PROBE!\probe.swift"
"!TC%\usr\bin\swiftc.exe" -typecheck "!PROBE!\probe.swift" > "%TEMP%\swift-probe-out.txt" 2>&1
if errorlevel 1 (
    echo COMPILER STILL FAILS. Output:
    type "%TEMP%\swift-probe-out.txt"
    echo.
    echo The component registry is out of sync with disk. Run the
    echo uninstall-then-install script instead:
    echo   scripts\reinstall-swift-toolchain.cmd
) else (
    echo COMPILER OK - standard library loads.
)

echo.
echo Logs: %LOGDIR%
echo Press any key to close.
pause >nul
exit /b 0

REM ---------------------------------------------------------------------
REM :repair <product code> <label>
REM Per MSDN the syntax is /f{p|o|e|d|c|a|u|m|s|v} - exactly one letter.
REM /fa forces every file to be reinstalled. The other letters (p o e d c u
REM m s v) are alternatives, not additional arguments; passing several of
REM them makes msiexec print its help screen instead of running.
REM ---------------------------------------------------------------------
:repair
echo Repairing %~2 ...
msiexec /fa "%~1" /qn /norestart /l*v "%LOGDIR%\repair-%~2.log"
if errorlevel 1 (
    echo   FAILED  msiexec exit !errorlevel!
) else (
    echo   done
)
exit /b 0
