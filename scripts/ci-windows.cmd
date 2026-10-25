@echo off
setlocal

rem Shuvi CI gate script (Windows).
rem
rem Requires these environment variables:
rem   CLT_HOME  Command Line Tools install dir, e.g. D:\command-line-tools
rem   JAVA_HOME compatible JDK dir, e.g. C:\Univ\jdk21
rem   CODELINTER_LOG_DIR actual CLT analyzer log directory
rem
rem Usage:
rem   scripts\ci-windows.cmd               full gate (install + lint + build)
rem   scripts\ci-windows.cmd --no-install  skip dependency install
rem
rem Notes:
rem  - Keep this file ASCII-only and CRLF-terminated. cmd.exe parses batch
rem    files using the system code page, so non-ASCII text can break parsing.
rem  - Code Linter exit behavior differs by version. The gate verifies the
rem    current report AND complete engine logs; exit code alone is insufficient.
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
if "%CODELINTER_LOG_DIR%"=="" (
  echo [ERROR] CODELINTER_LOG_DIR is not set. See docs/deployment CI instructions.
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
call "%CLT_HOME%\bin\hvigorw.bat" -v || exit /b 1
call "%CLT_HOME%\bin\codelinter.bat" -v
"%JAVA_HOME%\bin\java.exe" -version || exit /b 1

if not "%~1"=="--no-install" (
  echo ==^> install dependencies
  call "%CLT_HOME%\bin\ohpm.bat" install --all || exit /b 1
)

echo ==^> lint
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\ci-lint.ps1" -CodeLinterPath "%CLT_HOME%\bin\codelinter.bat" -LogDirectory "%CODELINTER_LOG_DIR%" || exit /b 1

echo ==^> build
call "%CLT_HOME%\bin\hvigorw.bat" assembleHap --no-daemon || exit /b 1

echo ==^> gate passed
exit /b 0
