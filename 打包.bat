@echo off
REM 一键打包 FinFlow APK 并复制到桌面
REM Author: xlj
REM 创建日期: 2026-02-13

echo 正在打包 FinFlow APK...
echo.

REM 检查 flutter 命令是否可用
where flutter >nul 2>&1
if %errorlevel% neq 0 (
    echo 错误: 未找到 flutter 命令，请确保 Flutter SDK 已正确安装并添加到 PATH 环境变量。
    echo.
    pause
    exit /b 1
)

REM 检查桌面路径是否存在
set "DESKTOP_PATH=C:\Users\xulij\Desktop"
if not exist "%DESKTOP_PATH%" (
    echo 错误: 桌面路径不存在: %DESKTOP_PATH%
    echo 请确认当前用户桌面路径是否正确。
    echo.
    pause
    exit /b 1
)

REM 执行 flutter build apk --release -v
echo 执行命令: flutter build apk --release -v
echo.
flutter build apk --release -v

REM 检查构建是否成功
if %errorlevel% neq 0 (
    echo.
    echo 打包失败，请检查:
    echo 1. Flutter SDK 是否正确安装
    echo 2. Android 开发环境是否已配置
    echo 3. 当前目录是否为 Flutter 项目根目录
    echo.
    pause
    exit /b %errorlevel%
)

REM 查找生成的 APK 文件
set "APK_PATH=build\app\outputs\flutter-apk\app-release.apk"
if not exist "%APK_PATH%" (
    echo 错误: 未找到生成的 APK 文件: %APK_PATH%
    echo 请检查构建输出目录。
    echo.
    pause
    exit /b 1
)

REM 生成带时间戳的文件名
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value') do set "datetime=%%I"
set "timestamp=%datetime:~0,4%-%datetime:~4,2%-%datetime:~6,2%_%datetime:~8,2%-%datetime:~10,2%"
set "DEST_FILE=%DESKTOP_PATH%\FinFlow_%timestamp%.apk"

REM 复制 APK 到桌面
echo.
echo 正在复制 APK 文件到桌面...
copy "%APK_PATH%" "%DEST_FILE%" >nul

if %errorlevel% neq 0 (
    echo 错误: 复制文件失败。
    echo 源文件: %APK_PATH%
    echo 目标文件: %DEST_FILE%
    echo.
    pause
    exit /b 1
)

echo.
echo 打包完成!
echo APK 文件已复制到: %DEST_FILE%
echo 原始文件位置: %APK_PATH%
echo.
echo 文件信息:
dir "%DEST_FILE%" | findstr "FinFlow"
echo.
pause