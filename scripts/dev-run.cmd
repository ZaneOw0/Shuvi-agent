@echo off
setlocal
rem Shuvi 一键启动脚本（Windows 包装，转发到 dev-run.sh）
rem 用法：scripts\dev-run.cmd [选项]   例如 scripts\dev-run.cmd --force-sign

where bash >nul 2>nul
if errorlevel 1 (
  echo [错误] 未找到 bash。请安装 Git for Windows，并将 Git Bash 的 bash.exe 加入 PATH。
  exit /b 1
)

bash "%~dp0dev-run.sh" %*
exit /b %errorlevel%
