@echo off
REM 一键启动 FinFlow 应用（Windows 平台）
REM Author: xlj
REM 创建日期: 2026-02-13

echo 正在启动 FinFlow 应用...
echo.

REM 检查 flutter 命令是否可用
where flutter >nul 2>&1
if %errorlevel% neq 0 (
    echo 错误: 未找到 flutter 命令，请确保 Flutter SDK 已正确安装并添加到 PATH 环境变量。
    echo.
    pause
    exit /b 1
)

echo 准备 Windows 桌面环境...
flutter config --enable-windows-desktop
if %errorlevel% neq 0 (
    echo.
    echo 启用 Windows 桌面支持失败，请检查 Flutter SDK 状态。
    echo.
    pause
    exit /b %errorlevel%
)
echo.

echo 正在预缓存 Windows 依赖...
flutter precache --windows
if %errorlevel% neq 0 (
    echo.
    echo 预缓存 Windows 依赖失败，请检查网络或 Flutter SDK 状态。
    echo.
    pause
    exit /b %errorlevel%
)
echo.

echo 正在清理旧的构建产物...
flutter clean
if %errorlevel% neq 0 (
    echo.
    echo 清理构建产物失败，请关闭占用 build 目录的程序后重试。
    echo.
    pause
    exit /b %errorlevel%
)
echo.

echo 正在拉取依赖...
flutter pub get
if %errorlevel% neq 0 (
    echo.
    echo 依赖拉取失败，请检查网络或 pub 配置。
    echo.
    pause
    exit /b %errorlevel%
)
echo.

REM 运行 flutter run -d windows
echo 执行命令: flutter run -d windows
echo.
flutter run -d windows

REM 如果 flutter 命令执行失败，显示错误信息
if %errorlevel% neq 0 (
    echo.
    echo 启动失败，请检查:
    echo 1. Flutter SDK 是否正确安装
    echo 2. Windows 桌面开发环境是否已配置
    echo 3. 当前目录是否为 Flutter 项目根目录
    echo.
    pause
    exit /b %errorlevel%
)

echo.
echo 应用已启动完成。
pause
