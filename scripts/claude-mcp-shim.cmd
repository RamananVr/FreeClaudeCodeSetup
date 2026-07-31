@echo off
setlocal enabledelayedexpansion
REM claude-mcp-shim.cmd
REM Stand-in for the `claude` binary that Agency launches (via AGENCY_CLAUDE_PATH).
REM Agency writes a temp MCP config with an invalid string `tools` field on every
REM http server (workiq, bluebird), which Claude rejects, and keeps that temp file
REM WRITE-LOCKED while Claude runs. So we write a repaired COPY to a new path and
REM rewrite --mcp-config to point at the copy, then exec the real Claude binary.
REM
REM Install: point Agency's AGENCY_CLAUDE_PATH at this file (and keep fix-mcp-config.ps1
REM next to it). The shim self-locates that companion via %~dp0, so it works from
REM wherever the repo is cloned.

set "FIXSCRIPT=%OMNI_FIX_SCRIPT%"
if not defined FIXSCRIPT set "FIXSCRIPT=%~dp0fix-mcp-config.ps1"

REM Resolve the real Claude binary. Prefer OMNI_REAL_CLAUDE, else auto-detect the
REM newest installed .claude-cli\<version>\claude.exe so this keeps working across
REM Claude updates without editing the shim.
REM NOTE: Agency can inject OMNI_REAL_CLAUDE as a single space, which `if not defined`
REM treats as *defined*. So we trim the value and validate it points at a real file;
REM anything blank/whitespace/missing falls through to auto-detect instead of failing.
set "REALCLAUDE=%OMNI_REAL_CLAUDE%"
REM Trim surrounding quotes and whitespace (collapses a " " value to empty).
if defined REALCLAUDE set "REALCLAUDE=%REALCLAUDE:"=%"
for /f "tokens=* delims= " %%A in ("%REALCLAUDE%") do set "REALCLAUDE=%%A"

REM If it isn't a real file, auto-detect the newest installed claude.exe.
if not defined REALCLAUDE goto detect
if exist "%REALCLAUDE%" goto resolved

:detect
set "REALCLAUDE="
REM Pipe-free PS so nothing needs caret-escaping inside the for/f backticks.
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=Get-ChildItem \"$env:USERPROFILE\.claude-cli\" -Directory -EA SilentlyContinue; $m=@(); foreach($x in $d){ if($x.Name -match '^\d+\.\d+\.\d+$'){ $m += $x } }; $r=($m | Sort-Object { [version]$_.Name } -Descending)[0]; if($r){ Join-Path $r.FullName 'claude.exe' }"`) do set "REALCLAUDE=%%I"

:resolved
if not defined REALCLAUDE (
    echo claude-mcp-shim: could not resolve a real claude.exe. Set OMNI_REAL_CLAUDE or install Claude under %%USERPROFILE%%\.claude-cli. 1>&2
    exit /b 9009
)
if not exist "%REALCLAUDE%" (
    echo claude-mcp-shim: resolved claude binary does not exist: "%REALCLAUDE%" 1>&2
    exit /b 9009
)

set "NEWARGS="
set "FIXCFG="

:parse
if "%~1"=="" goto run
if /I "%~1"=="--mcp-config" (
    set "FIXCFG=%TEMP%\omni-mcp-fixed-%RANDOM%%RANDOM%.json"
    powershell -NoProfile -ExecutionPolicy Bypass -File "%FIXSCRIPT%" -Path "%~2" -OutPath "!FIXCFG!" 1>nul 2>nul
    if exist "!FIXCFG!" (
        set "NEWARGS=!NEWARGS! --mcp-config "!FIXCFG!""
    ) else (
        set "NEWARGS=!NEWARGS! --mcp-config "%~2""
    )
    shift
    shift
    goto parse
)
set "NEWARGS=!NEWARGS! "%~1""
shift
goto parse

:run
"%REALCLAUDE%" !NEWARGS!
exit /b %ERRORLEVEL%
