@echo off
setlocal

rem Shuvi CI gate script (Windows).
rem
rem Requires these environment variables:
rem   CLT_HOME  Command Line Tools install dir, e.g. D:\command-line-tools
rem   JAVA_HOME compatible JDK dir, e.g. C:\Univ\jdk21
rem
rem Usage:
rem   scripts\ci-windows.cmd               full gate (install + lint + build)
rem   scripts\ci-windows.cmd --no-install  skip dependency install
rem
rem Notes:
rem  - Keep this file ASCII-only and CRLF-terminated. cmd.exe parses batch
rem    files using the system code page, so non-ASCII text can break parsing.
rem  - codelinter.bat always exits with code 1, even on clean code, so its
rem    exit code is NOT used here. This gate reads its JSON report instead.
rem  - ArkTS strict rules (arkts-*) are enforced by the build step
rem    (hvigorw assembleHap), which fails on any ArkTS compiler error.

if "%CLT_HOME%"=="" (
  echo [ERROR] CLT_HOME is not set. Point it to the Command Line Tools directory.
  exit /b 1
)
if "%JAVA_HOME%"=="" (
  echo [ERROR] JAVA_HOME is not set. Point it to a compatible JDK ^(JDK 21 verified^).
  exit /b 1
)

set "PATH=%CLT_HOME%\bin;%JAVA_HOME%\bin;%CLT_HOME%\tool\node;%PATH%"

set "ROOT=%~dp0.."
cd /d "%ROOT%"
if not exist "build-profile.json5" (
  echo [ERROR] build-profile.json5 not found. Run this script from the repo scripts directory.
  exit /b 1
)

echo ==^> toolchain versions
call hvigorw.bat -v
call codelinter.bat -v
java -version

if not "%~1"=="--no-install" (
  echo ==^> install dependencies
  call ohpm.bat install --all || exit /b 1
)

echo ==^> lint
set "REPORT=%TEMP%\shuvi-codelinter.json"
if exist "%REPORT%" del /q "%REPORT%"
call codelinter.bat -f json -o "%REPORT%"
if not exist "%REPORT%" (
  echo [ERROR] codelinter did not produce a report at %REPORT%
  exit /b 1
)
node -e "const fs=require('fs');const p=process.argv[1];const r=JSON.parse(fs.readFileSync(p,'utf8'));const n=Array.isArray(r)?r.length:0;if(n>0){console.error('[ERROR] codelinter reported '+n+' issue(s), see '+p);process.exit(1);}console.log('[OK] codelinter: no issues');" "%REPORT%" || exit /b 1

echo ==^> build
call hvigorw.bat assembleHap --no-daemon || exit /b 1

echo ==^> gate passed
exit /b 0
