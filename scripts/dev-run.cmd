@echo off
setlocal enabledelayedexpansion

rem Shuvi dev launcher: Windows wrapper for scripts/dev-run.sh
rem Usage: scripts\dev-run.cmd [options]   e.g. scripts\dev-run.cmd --force-sign
rem
rem Requirements on any member machine:
rem   - Git for Windows (provides Git Bash + coreutils)
rem   - DevEco Studio / DevEco Code, with devecocli on PATH
rem
rem NOTE: keep this file ASCII-only + CRLF. cmd.exe parses batch files with the
rem system code page, so non-ASCII text breaks parsing on Chinese Windows.
rem NOTE: do NOT call "bash" from PATH -- on many machines that resolves to the
rem WSL launcher (C:\Windows\System32\bash.exe), which cannot run Windows paths.
rem Git Bash is located explicitly below and validated before use.

set "BASH="
set "GITEXE="

rem 1) Derive Git Bash from git.exe (covers <Git>\cmd, <Git>\mingw64\bin, <Git>\usr\bin)
for /f "delims=" %%G in ('where git 2^>nul') do (
  if not defined GITEXE set "GITEXE=%%G"
)
if defined GITEXE (
  for %%D in ("!GITEXE!") do set "GITDIR=%%~dpD"
  if not defined BASH if exist "!GITDIR!bash.exe" set "BASH=!GITDIR!bash.exe"
  if not defined BASH if exist "!GITDIR!..\bin\bash.exe" set "BASH=!GITDIR!..\bin\bash.exe"
  if not defined BASH if exist "!GITDIR!..\..\bin\bash.exe" set "BASH=!GITDIR!..\..\bin\bash.exe"
)

rem 2) Fall back to standard Git for Windows install locations
if not defined BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"

if not defined BASH (
  echo [ERROR] Git Bash not found.
  echo Install Git for Windows, or add its bin directory to PATH, then retry.
  exit /b 1
)

rem 3) Reject the WSL launcher explicitly
echo %BASH% | findstr /i /c:"\System32\bash.exe" >nul && (
  echo [ERROR] Resolved bash is the WSL launcher, not Git Bash: %BASH%
  exit /b 1
)

echo Using Git Bash: %BASH%

pushd "%~dp0.." || exit /b 1
"%BASH%" scripts/dev-run.sh %*
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%
