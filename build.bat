@echo off
echo ==============================================
echo 🚀 TapAndGo Auto-Increment Version ^& Build APK
echo ==============================================

call fvm dart scripts/build_apk.dart

if %errorlevel% neq 0 (
    echo.
    echo ❌ Build process failed!
    pause
    exit /b %errorlevel%
)

echo.
echo 🎉 Done!
pause
