: << 'BATCH_GUARD'
@echo off
REM Polyglot script: bash treats the colon as a no-op and skips to the
REM Unix section below. cmd.exe runs the batch block between here and
REM the BATCH_GUARD label.
REM
REM Receives a hook script name (e.g. "session-start") as its first
REM argument and executes hooks/<name> via bash.

if "%~1"=="" (
    echo run-hook.cmd: no hook name provided >&2
    exit /b 1
)

set "HOOKS_DIR=%~dp0"

REM Attempt standard Git for Windows install paths first
if exist "C:\Program Files\Git\bin\bash.exe" (
    "C:\Program Files\Git\bin\bash.exe" "%HOOKS_DIR%%~1" %2 %3 %4 %5 %6 %7 %8 %9
    exit /b %ERRORLEVEL%
)
if exist "C:\Program Files (x86)\Git\bin\bash.exe" (
    "C:\Program Files (x86)\Git\bin\bash.exe" "%HOOKS_DIR%%~1" %2 %3 %4 %5 %6 %7 %8 %9
    exit /b %ERRORLEVEL%
)

REM Fall back to any bash on the system PATH
where bash >nul 2>nul
if %ERRORLEVEL% equ 0 (
    bash "%HOOKS_DIR%%~1" %2 %3 %4 %5 %6 %7 %8 %9
    exit /b %ERRORLEVEL%
)

REM No bash available — exit cleanly so the plugin load is not blocked
exit /b 0
BATCH_GUARD

# --- Unix / macOS ---------------------------------------------------------
# Resolve the directory this script lives in, then hand off to the
# named hook script with any remaining arguments.
HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_NAME="$1"
shift
exec bash "${HOOKS_DIR}/${HOOK_NAME}" "$@"
