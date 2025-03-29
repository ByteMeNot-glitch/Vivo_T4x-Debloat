@echo off
setlocal EnableDelayedExpansion

echo === Smart Permission Manager ===
echo This script intelligently revokes only permissions that apps actually have.
echo No App Ops application is required - this uses ADB commands only.
echo.

:: Check for ADB connection
adb get-state >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Error: No ADB device connected or device not responding
    pause
    exit /b 1
)

:: Turn on airplane mode and disable location at start
echo Enabling Airplane Mode and Disabling Location...
adb shell settings put global airplane_mode_on 1
adb shell cmd connectivity airplane-mode enable
adb shell settings put secure location_mode 0
adb shell settings put global gps_enabled 0
echo.

:: Define test packages to process (added Play Store: com.android.vending)
set "packages_to_process=com.google.android.gms com.google.android.apps.maps com.facebook.katana com.android.chrome com.android.vending"

:: Initialize counter
set "current_package=1"
set "total_packages=5"

for %%p in (%packages_to_process%) do (
    set "package_name=%%p"
    call :ProcessPackageSmartly
    echo.
    set /a "current_package+=1"
)

:: Turn off airplane mode at end
echo.
echo Disabling Airplane Mode...
adb shell settings put global airplane_mode_on 0
adb shell cmd connectivity airplane-mode disable
echo.
echo Script completed successfully. Press any key to exit...
pause
exit /b 0

:ProcessPackageSmartly
echo Progress: [%current_package%/%total_packages%] - Processing: %package_name%

echo 1. Force stopping the app...
adb shell am force-stop %package_name%

echo 2. Getting app information and UID...
:: Get app UID using built-in ADB commands
for /f "tokens=2 delims==" %%i in ('adb shell dumpsys package %package_name% ^| findstr /r /c:"userId=[0-9]*"') do set UID=%%i
echo    App UID: !UID!

echo 3. Analyzing granted permissions...
:: Create temp files to store permissions data
set "runtime_perms_file=%temp%\runtime_perms.txt"
set "appops_file=%temp%\appops.txt"

:: Get runtime permissions directly from the Android system
adb shell dumpsys package %package_name% | findstr "granted=true" > "%runtime_perms_file%"

:: Get app ops settings directly from the Android system
adb shell cmd appops get %package_name% > "%appops_file%"

:: Count how many permissions we found
set /a runtime_perms_count=0
for /f %%i in ('type "%runtime_perms_file%" ^| find /c /v ""') do set runtime_perms_count=%%i

set /a appops_count=0
for /f %%i in ('type "%appops_file%" ^| find /c /v ""') do set appops_count=%%i

echo    Found !runtime_perms_count! runtime permissions and approximately !appops_count! app operations.

echo 4. Clearing app data...
adb shell pm clear %package_name% >nul 2>&1

echo 5. Revoking specific runtime permissions...
for /f "tokens=1 delims=:" %%p in ('type "%runtime_perms_file%" ^| findstr /r "android\.permission\.[A-Za-z0-9_]*"') do (
    set "perm=%%p"
    set "perm=!perm: =!"
    echo    Revoking: !perm!
    adb shell pm revoke %package_name% !perm! >nul 2>&1
)

echo 6. Setting app operations to 'ignore'...
:: This uses Android's built-in appops command, not the App Ops application
for /f "tokens=1,* delims=:" %%a in ('type "%appops_file%" ^| findstr /r /c:"Op [A-Z_]* [^:]*: [^i]"') do (
    set "line=%%b"
    for /f "tokens=1" %%c in ("!line!") do (
        set "op=%%c"
        set "op=!op: =!"
        if not "!op!"=="" (
            echo    Restricting: !op!
            adb shell cmd appops set %package_name% !op! ignore >nul 2>&1
        )
    )
)

echo 7. Applying critical permission restrictions...

:: 7.1 System Settings Modifications
echo    Restricting Modify System Settings...
adb shell pm revoke %package_name% android.permission.WRITE_SETTINGS >nul 2>&1
adb shell cmd appops set %package_name% WRITE_SETTINGS ignore >nul 2>&1
adb shell settings put secure enabled_accessibility_services "" >nul 2>&1

:: 7.2 Picture in Picture
echo    Restricting Picture in Picture...
adb shell pm revoke %package_name% android.permission.PICTURE_IN_PICTURE >nul 2>&1
adb shell cmd appops set %package_name% PICTURE_IN_PICTURE ignore >nul 2>&1

:: 7.3 Usage Access
echo    Restricting Usage Access...
adb shell pm revoke %package_name% android.permission.PACKAGE_USAGE_STATS >nul 2>&1
adb shell cmd appops set %package_name% GET_USAGE_STATS ignore >nul 2>&1
adb shell cmd appops set %package_name% LOADER_USAGE_STATS ignore >nul 2>&1

:: 7.4 Display over other apps
echo    Restricting Display Over Other Apps...
adb shell pm revoke %package_name% android.permission.SYSTEM_ALERT_WINDOW >nul 2>&1
adb shell cmd appops set %package_name% SYSTEM_ALERT_WINDOW ignore >nul 2>&1
adb shell cmd appops set %package_name% TOAST_WINDOW ignore >nul 2>&1

:: 7.5 Background data - more aggressive approach
echo    Restricting Background Data...
adb shell cmd netpolicy add restrict-background-blacklist !UID! >nul 2>&1
adb shell settings put global restrict_background_data 1 >nul 2>&1
adb shell cmd netpolicy add restrict-background true >nul 2>&1
adb shell cmd netpolicy set metered-network %package_name% true >nul 2>&1
adb shell settings put global data_saver_enabled 1 >nul 2>&1
adb shell settings put global network_metered_multipath_preference 0 >nul 2>&1

:: 7.6 Background activity - more thorough approach
echo    Restricting Background Activity...
adb shell cmd device_config put battery_saver app_standby_enabled true >nul 2>&1
adb shell settings put global app_standby_enabled 1 >nul 2>&1
adb shell cmd appops set %package_name% RUN_IN_BACKGROUND deny >nul 2>&1
adb shell cmd appops set %package_name% RUN_ANY_IN_BACKGROUND deny >nul 2>&1
adb shell dumpsys deviceidle whitelist -%package_name% >nul 2>&1
adb shell settings put global adaptive_battery_management_enabled 1 >nul 2>&1
adb shell dumpsys batterysaver set restrictBackground true >nul 2>&1

:: 7.7 Battery optimization
echo    Enforcing Battery Optimization...
adb shell cmd appops set %package_name% REQUEST_IGNORE_BATTERY_OPTIMIZATIONS ignore >nul 2>&1
adb shell pm revoke %package_name% android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS >nul 2>&1
adb shell dumpsys deviceidle whitelist -%package_name% >nul 2>&1

:: 7.8 Disable "Open by default" links
echo    Disabling App Links...
adb shell pm set-app-links --package %package_name% 0 all >nul 2>&1
adb shell pm set-app-links-allowed --package %package_name% false >nul 2>&1
adb shell cmd package set-app-link-state %package_name% 0 >nul 2>&1

:: 7.9 Enhanced notification controls
echo    Disabling Notifications...
adb shell cmd notification set-importance %package_name% none >nul 2>&1
adb shell cmd appops set %package_name% POST_NOTIFICATION ignore >nul 2>&1
adb shell pm revoke %package_name% android.permission.POST_NOTIFICATIONS >nul 2>&1
adb shell cmd notification set-not-disturb-by-app %package_name% true >nul 2>&1
adb shell settings put global heads_up_notifications_enabled 0 >nul 2>&1
adb shell cmd notification set-bubbles %package_name% 0 >nul 2>&1

:: 7.10 Special access revocation
echo    Revoking Special Access...
adb shell pm revoke %package_name% android.permission.ACCESS_NOTIFICATIONS >nul 2>&1
adb shell cmd notification allow_listener %package_name% false >nul 2>&1
adb shell settings put secure enabled_notification_listeners "" >nul 2>&1
adb shell settings put secure enabled_notification_assistant "" >nul 2>&1

:: Clean up temp files
del "%runtime_perms_file%" >nul 2>&1
del "%appops_file%" >nul 2>&1

echo 8. Completed processing %package_name%
exit /b 0

