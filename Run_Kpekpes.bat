@echo off
title Kpekpes PC Gaming Optimization
color 0A

setlocal enabledelayedexpansion

:: ============================================================
::  Kpekpes PC Gaming Optimization - Launcher
::  Auto-handles: OneDrive sync, execution policy, admin rights
:: ============================================================

set "SOURCE_DIR=%~dp0"
set "SOURCE_DIR=%SOURCE_DIR:~0,-1%"
set "SAFE_DIR=C:\KpekpesOptimizer"

echo.
echo ============================================================
echo   Kpekpes PC Gaming Optimization
echo ============================================================
echo.

:: ---- Sanity check: all 3 files present ----
if not exist "%SOURCE_DIR%\Gaming-Profile.ps1" (
    echo [ERROR] Gaming-Profile.ps1 is missing.
    echo.
    echo Please make sure ALL 3 files are extracted into the SAME folder:
    echo   1. Run_Kpekpes.bat
    echo   2. Kpekpes-PC-Gaming-Optimization.ps1
    echo   3. Gaming-Profile.ps1
    echo.
    pause
    exit /b 1
)
if not exist "%SOURCE_DIR%\Kpekpes-PC-Gaming-Optimization.ps1" (
    echo [ERROR] Kpekpes-PC-Gaming-Optimization.ps1 is missing.
    echo Please make sure all 3 files are in the same folder.
    echo.
    pause
    exit /b 1
)

:: ---- Detect OneDrive path (breaks PowerShell process piping) ----
set "RUN_DIR=%SOURCE_DIR%"
echo %SOURCE_DIR% | findstr /i "OneDrive" >nul
if !errorlevel!==0 (
    echo Detected OneDrive folder. Relocating to a safe location...
    echo.
    if not exist "%SAFE_DIR%" mkdir "%SAFE_DIR%" >nul 2>&1
    xcopy "%SOURCE_DIR%\*" "%SAFE_DIR%\" /E /Y /Q >nul 2>&1
    set "RUN_DIR=%SAFE_DIR%"
    echo Copied files to: %SAFE_DIR%
    echo.
)

:: ---- Fix execution policy silently (one-time, current user only) ----
echo Preparing system (first-run setup)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue } catch {}" >nul 2>&1

:: ---- Launch the GUI with admin rights ----
echo Launching Kpekpes Optimizer...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File \"%RUN_DIR%\Kpekpes-PC-Gaming-Optimization.ps1\"' -Verb RunAs"

endlocal
exit /b 0