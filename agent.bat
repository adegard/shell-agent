@echo off
:: Quick launcher for shell-agent on Windows
:: Usage: agent.bat "write a hello world script"
::        agent.bat (no args = interactive mode)

setlocal

set AGENT_DIR=%~dp0
set PATH=%USERPROFILE%\.local\bin;%PATH%

if "%~1"=="" (
    bash "%AGENT_DIR%agent.sh"
) else (
    bash "%AGENT_DIR%agent.sh" "%*"
)
