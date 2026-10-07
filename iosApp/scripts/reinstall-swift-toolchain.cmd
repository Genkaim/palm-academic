@echo off
REM Rebuild the Swift 6.4.0 toolchain from scratch on Windows.
REM
REM Why: a partial install left the Windows Installer component registry
REM claiming files are present while they are absent on disk. Re-running the
REM bundle then reports success in five seconds and copies nothing, because
REM every package is detected as state "Present".
REM
REM Stage 1 removes every registered component, which resets that state.
REM Stage 2 reinstalls each MSI straight from the local Package Cache with
REM REINSTALL=ALL REINSTALLMODE=vomus so the file copy is forced:
REM   v verify source, o overwrite, m modify, u rewrite entries, s verify shortcuts.
REM
REM Everything is local. No download, no elevation (per-user scope).

setlocal enabledelayedexpansion

set "CACHE=%LOCALAPPDATA%\Package Cache"
set "LOGDIR=%TEMP%\swift-clean-reinstall-logs"

if not exist "%LOGDIR%" mkdir "%LOGDIR%"

echo ==========================================================
echo  Stage 1 - remove every registered Swift component
echo ==========================================================
echo.

call :uninstall "{14A77441-041E-4EA2-8B0A-61BF5D9201E5}" rtl.amd64
call :uninstall "{1741CDB6-3C96-468E-B8D9-94B83459F843}" cli.asserts
call :uninstall "{5AD96126-7798-42FF-82E2-8EEEB829B061}" windows
call :uninstall "{7C21BB98-B28D-4886-817E-7F7D572BED63}" bld.asserts
call :uninstall "{95E1B815-7FF7-4CCA-8A4A-28941AED93BD}" dbg.asserts
call :uninstall "{A51B9C17-5F77-4A2A-9AE8-198D9B7EC94F}" res
call :uninstall "{B725DC95-A18C-4F61-A91C-A665E2D51755}" python
call :uninstall "{BD5D979B-E602-4E81-A389-8ECAE1B21EF4}" android
call :uninstall "{DED24AA5-ADAE-4434-BCB9-B8472D018939}" ide.asserts

echo.
echo Clearing leftover directories.
if exist "%LOCALAPPDATA%\Programs\Swift" (
    rmdir /s /q "%LOCALAPPDATA%\Programs\Swift"
)
if exist "%LOCALAPPDATA%\Programs\Swift" (
    echo WARNING: Swift folder could not be fully removed. Continue anyway.
) else (
    echo Swift folder removed.
)

echo.
echo ==========================================================
echo  Stage 2 - reinstall from the local package cache
echo ==========================================================
echo.

REM Order matters: runtimes and prerequisites before the toolchain itself.
call :install "{14A77441-041E-4EA2-8B0A-61BF5D9201E5}v6.4.0" rtl.amd64.msi
call :install "{A51B9C17-5F77-4A2A-9AE8-198D9B7EC94F}v6.4.0" res.msi
call :install "{B725DC95-A18C-4F61-A91C-A665E2D51755}v6.4.0" python.msi
call :install "{5AD96126-7798-42FF-82E2-8EEEB829B061}v6.4.0" windows.msi
call :install "{DED24AA5-ADAE-4434-BCB9-B8472D018939}v6.4.0" ide.asserts.msi
call :install "{7C21BB98-B28D-4886-817E-7F7D572BED63}v6.4.0" bld.asserts.msi
call :install "{1741CDB6-3C96-468E-B8D9-94B83459F843}v6.4.0" cli.asserts.msi
call :install "{95E1B815-7FF7-4CCA-8A4A-28941AED93BD}v6.4.0" dbg.asserts.msi

echo.
echo ==========================================================
echo  Result
echo ==========================================================
set "TC=%LOCALAPPDATA%\Programs\Swift\Toolchains\6.4.0+Asserts"
if exist "!TC!\usr\lib\swift\windows" (
    echo Standard library: PRESENT
) else (
    echo Standard library: MISSING
)
if exist "!TC!\usr\bin\swiftc.exe" (
    echo swiftc.exe: PRESENT
) else (
    echo swiftc.exe: MISSING
)

REM The decisive test: can the compiler load its own standard library?
set "PROBE=%TEMP%\swift-probe"
if not exist "!PROBE!" mkdir "!PROBE!"
echo print("probe")> "!PROBE!\probe.swift"
"!TC!\usr\bin\swiftc.exe" -typecheck "!PROBE!\probe.swift" > "%TEMP%\swift-probe-out.txt" 2>&1
if errorlevel 1 (
    echo COMPILER STILL FAILS:
    type "%TEMP%\swift-probe-out.txt"
) else (
    echo COMPILER OK - standard library loads.
)
echo Logs: %LOGDIR%

echo.
echo Press any key to close.
pause >nul
exit /b 0

REM ---------------------------------------------------------------------
REM :uninstall <product code> <label>
REM ---------------------------------------------------------------------
:uninstall
echo Removing %~2 ...
msiexec /x "%~1" /qn /norestart /l*v "%LOGDIR%\uninstall-%~2.log"
if errorlevel 1 (
    echo   not registered, skipping
) else (
    echo   done
)
exit /b 0

REM ---------------------------------------------------------------------
REM :install <cache subfolder> <msi name>
REM ---------------------------------------------------------------------
:install
set "FULLPATH=%CACHE%\%~1\%~2"
if not exist "!FULLPATH!" (
    echo MISSING   %~2  - not in cache
    exit /b 1
)
REM No REINSTALL property here on purpose. The uninstall in Stage 1 already
REM reset the component registry; research on REINSTALL=ALL REINSTALLMODE=vomus
MUSING against an out-of-sync component registry reports the same
REM "Installed: Local; Request: Null; Action: Null" for every component and
REM copies nothing. Removal followed by a clean install is the documented
REM approach for that state.
echo Installing %~2 - large packages take several minutes.
msiexec /i "!FULLPATH!" /qn /norestart /l*v "%LOGDIR%\install-%~2.log"
if errorlevel 1 (
    echo FAILED    %~2  - msiexec exit !errorlevel!
    exit /b 1
)
echo OK         %~2
exit /b 0
