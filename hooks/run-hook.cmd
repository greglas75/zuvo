: << 'BATCH_GUARD'
@echo off
REM Polyglot script: bash treats the colon as a no-op and skips to the
REM Unix section below. cmd.exe runs the batch block between here and
REM the BATCH_GUARD label.
REM
REM Receives a hook script name (e.g. "session-start" or "block-no-verify.sh")
REM as its first argument and executes hooks/<name> via bash.
REM
REM LINE ENDINGS: stored with LF, NOT CRLF, deliberately. Every Claude Code hook
REM routes through this file, so bash on macOS/Linux reads it on every hook
REM invocation — and bash does NOT tolerate CRLF here (verified: "line 37: :
REM command not found", "shift: command not found", hook path unresolvable).
REM The cmd.exe LF hazard is specifically MULTI-LINE parenthesised blocks, so
REM every conditional below is kept on ONE line. Do not reformat them back into
REM multi-line ( ... ) blocks: that would require CRLF, which would in turn
REM break every hook on macOS and Linux.

if "%~1"=="" ( echo run-hook.cmd: no hook name provided >&2 & exit /b 1 )

set "HOOKS_DIR=%~dp0"

REM Standard Git for Windows install paths first. This fallback is the whole
REM reason hooks route through this file: Git's "Git Bash only" install option
REM deliberately does NOT put bash on the system PATH, so a hook wired straight
REM to `bash ...` is silently dead on exactly those machines.
if exist "C:\Program Files\Git\bin\bash.exe" ( "C:\Program Files\Git\bin\bash.exe" "%HOOKS_DIR%%~1" %2 %3 %4 %5 %6 %7 %8 %9 & exit /b %ERRORLEVEL% )
if exist "C:\Program Files (x86)\Git\bin\bash.exe" ( "C:\Program Files (x86)\Git\bin\bash.exe" "%HOOKS_DIR%%~1" %2 %3 %4 %5 %6 %7 %8 %9 & exit /b %ERRORLEVEL% )

REM Then any bash on PATH.
where bash >nul 2>nul
if %ERRORLEVEL% equ 0 ( bash "%HOOKS_DIR%%~1" %2 %3 %4 %5 %6 %7 %8 %9 & exit /b %ERRORLEVEL% )

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
