@echo off
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title 视频下载助手
color 0b
python "%~dp0youtube_downloader.py" %*
if %errorlevel% neq 0 (
    echo.
    echo 提示: 程序异常退出
    pause
)