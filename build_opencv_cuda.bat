@echo off
setlocal EnableExtensions EnableDelayedExpansion
title OpenCV CUDA build

rem =====================================================================
rem  build_opencv_cuda.bat - one-click OpenCV + CUDA build for Windows
rem
rem  Checks for: winget, Git, Python (+numpy), Visual Studio C++ tools,
rem  CMake, Ninja, CUDA Toolkit, cuDNN (optional). Installs what it can
rem  via winget, then configures and builds OpenCV with CUDA.
rem
rem  Usage (run from anywhere, it elevates itself):
rem    build_opencv_cuda.bat [--clean] [--no-cudnn] [--version 4.12.0]
rem                          [--arch 7.5] [--python C:\path\to\python.exe]
rem
rem  Sources: C:\build\opencv and C:\build\opencv_contrib (reused if present)
rem  Result:  C:\build\install  and the cv2 package inside the chosen Python site-packages
rem  Log:     C:\build\build.log
rem =====================================================================

rem ---- 1. administrator rights (needed for winget installs) ----
net session >nul 2>&1
if not errorlevel 1 goto have_admin
echo Requesting administrator rights ...
if "%~1"=="" (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
) else (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
)
exit /b
:have_admin

rem ---- 2. settings and arguments ----
set "ROOT=C:\build"
set "OPENCV_VERSION=latest"
set "CUDA_ARCH="
set "CLEAN=0"
set "NO_CUDNN=0"
set "PYEXE="

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="--clean" set "CLEAN=1"
if /i "%~1"=="--no-cudnn" set "NO_CUDNN=1"
if /i "%~1"=="--version" set "OPENCV_VERSION=%~2"
if /i "%~1"=="--arch" set "CUDA_ARCH=%~2"
if /i "%~1"=="--python" set "PYEXE=%~2"
if /i "%~1"=="--version" shift
if /i "%~1"=="--arch" shift
if /i "%~1"=="--python" shift
shift
goto parse
:parsed

set "SRC=%ROOT%\src"
set "BUILD=%ROOT%\build"
set "INSTALL=%ROOT%\install"
set "LOG=%ROOT%\build.log"
set "OCV=%ROOT%\opencv"
set "CONTRIB=%ROOT%\opencv_contrib"
if not exist "%ROOT%" mkdir "%ROOT%"
cd /d "%ROOT%"
>> "%LOG%" echo ===== %date% %time% =====

echo.
echo ============================================================
echo  OpenCV + CUDA builder      root: %ROOT%
echo ============================================================

rem ---- 2b. preflight: things this script cannot install by itself ----
>> "%LOG%" echo [%time%] STEP 2b. preflight: things this script cannot install by itself
set "HAVE_WINGET=0"
where winget >nul 2>&1 && set "HAVE_WINGET=1"
if "%HAVE_WINGET%"=="1" goto pf_winget_ok
echo.
echo [!] winget was not found. This script uses it to install Git, Python, VS Build Tools,
echo     CMake, Ninja and CUDA.
echo     How to fix: install "App Installer" from the Microsoft Store, or get it from
echo     https://aka.ms/getwinget . Or install those tools by hand - they will be detected.
choice /c OCA /n /m "[O] open download page and exit   [C] continue anyway   [A] abort : "
if errorlevel 3 goto fail_user
if errorlevel 2 goto pf_winget_ok
start "" https://aka.ms/getwinget
goto fail_user
:pf_winget_ok

set "FREE_GB="
for /f "usebackq delims=" %%G in (`powershell -NoProfile -Command "[int]((Get-PSDrive -Name '%ROOT:~0,1%').Free/1GB)"`) do set "FREE_GB=%%G"
if not defined FREE_GB goto pf_disk_ok
if %FREE_GB% GEQ 30 goto pf_disk_ok
echo.
echo [!] Only %FREE_GB% GB free on drive %ROOT:~0,2% - the toolchain plus the build needs about 30 GB.
echo     How to fix: free some space, or change ROOT at the top of this script to another drive.
choice /c CA /n /m "[C] continue anyway   [A] abort : "
if errorlevel 2 goto fail_user
:pf_disk_ok

:pf_driver_check
nvidia-smi >nul 2>&1 && goto pf_driver_ok
echo.
echo [!] NVIDIA driver not detected ^(nvidia-smi does not run^). The script does NOT install it.
echo     How to install: open https://www.nvidia.com/Download/index.aspx , pick your GPU
echo     ^(GeForce / RTX 20 Series / RTX 2070^) and Windows, run the installer, then reboot.
echo     Without a driver the build still works, but OpenCV will not see the GPU at run time.
choice /c ORCA /n /m "[O] open driver page and exit   [R] I installed it, re-check   [C] continue anyway   [A] abort : "
if errorlevel 4 goto fail_user
if errorlevel 3 goto pf_driver_ok
if errorlevel 2 goto pf_driver_check
start "" https://www.nvidia.com/Download/index.aspx
goto fail_user
:pf_driver_ok

rem ---- 3. Git ----
>> "%LOG%" echo [%time%] STEP 3. Git
call :ensure_cmd git Git.Git || goto fail

rem ---- 4. Python + numpy ----
>> "%LOG%" echo [%time%] STEP 4. Python + numpy
call :find_python
if defined PYEXE goto have_python
echo [missing] Python - installing Python 3.12
call :winget_install Python.Python.3.12
call :find_python
:have_python
if not defined PYEXE goto fail_python
echo [ok] Python: %PYEXE%
"%PYEXE%" -m pip install --upgrade pip numpy
if errorlevel 1 goto fail_python
"%PYEXE%" -m pip uninstall -y opencv-python opencv-contrib-python opencv-python-headless opencv-contrib-python-headless >nul 2>&1

rem ---- 5. Visual Studio C++ build tools ----
>> "%LOG%" echo [%time%] STEP 5. Visual Studio C++ build tools
call :find_vs
if defined VSPATH goto have_vs
echo [missing] Visual Studio C++ tools - installing VS 2022 Build Tools, this is a big download
if "%HAVE_WINGET%"=="0" goto fail_vs
winget install -e --id Microsoft.VisualStudio.2022.BuildTools --accept-package-agreements --accept-source-agreements --override "--passive --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
call :refresh_path
call :find_vs
:have_vs
if not defined VSPATH goto fail_vs
echo [ok] Visual Studio: %VSPATH%
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 goto fail_vs
where cl >nul 2>&1 || goto fail_vs

rem ---- 6. CMake and Ninja ----
>> "%LOG%" echo [%time%] STEP 6. CMake and Ninja
call :ensure_cmd cmake Kitware.CMake || goto fail
call :ensure_cmd ninja Ninja-build.Ninja || goto fail

rem ---- 7. CUDA Toolkit ----
>> "%LOG%" echo [%time%] STEP 7. CUDA Toolkit
if defined CUDA_PATH if exist "%CUDA_PATH%\bin\nvcc.exe" set "PATH=%CUDA_PATH%\bin;%PATH%"
where nvcc >nul 2>&1 && goto have_cuda
echo [missing] CUDA Toolkit - installing via winget, this is a big download
if "%HAVE_WINGET%"=="0" goto fail_cuda
winget install -e --id Nvidia.CUDA --silent --accept-package-agreements --accept-source-agreements
call :refresh_path
if defined CUDA_PATH if exist "%CUDA_PATH%\bin\nvcc.exe" set "PATH=%CUDA_PATH%\bin;%PATH%"
where nvcc >nul 2>&1 || goto fail_cuda
:have_cuda
for /f "tokens=5 delims=, " %%V in ('nvcc --version ^| findstr /i "release"') do set "CUDA_VER=%%V"
for /f "delims=." %%M in ("%CUDA_VER%") do set "CUDA_MAJOR=%%M"
if not defined CUDA_PATH for /f "delims=" %%N in ('where nvcc') do for %%D in ("%%N\..\..") do set "CUDA_PATH=%%~fD"
echo [ok] CUDA %CUDA_VER%  ^(%CUDA_PATH%^)

rem ---- 8. GPU architecture ----
>> "%LOG%" echo [%time%] STEP 8. GPU architecture
if not defined CUDA_ARCH for /f "usebackq delims=" %%A in (`nvidia-smi --query-gpu^=compute_cap --format^=csv^,noheader 2^>nul`) do if not defined CUDA_ARCH set "CUDA_ARCH=%%A"
if defined CUDA_ARCH set "CUDA_ARCH=%CUDA_ARCH: =%"
if not defined CUDA_ARCH (
    echo [warn] could not detect GPU compute capability, using 7.5 ^(RTX 20xx^)
    set "CUDA_ARCH=7.5"
)
echo [ok] CUDA_ARCH_BIN: %CUDA_ARCH%

rem ---- 9. cuDNN (optional) ----
>> "%LOG%" echo [%time%] STEP 9. cuDNN optional
set "CUDNN_INC="
set "CUDNN_LIB="
set "CUDNN_BIN="
set "CUDNN_ON=OFF"
set "CUDNN_FLAGS="
if "%NO_CUDNN%"=="1" goto cudnn_done
:cudnn_scan
call :find_cudnn "%CUDNN_PATH%"
if not defined CUDNN_LIB call :find_cudnn "%ProgramFiles%\NVIDIA\CUDNN"
if not defined CUDNN_LIB call :find_cudnn "%CUDA_PATH%"
if not defined CUDNN_INC goto cudnn_missing
if not defined CUDNN_LIB goto cudnn_missing
if "%CUDNN_INC:~-1%"=="\" set "CUDNN_INC=%CUDNN_INC:~0,-1%"
if "%CUDNN_BIN:~-1%"=="\" set "CUDNN_BIN=%CUDNN_BIN:~0,-1%"
set "CUDNN_INC_F=%CUDNN_INC:\=/%"
set "CUDNN_LIB_F=%CUDNN_LIB:\=/%"
set "CUDNN_ON=ON"
set "CUDNN_FLAGS=-DCUDNN_INCLUDE_DIR="%CUDNN_INC_F%" -DCUDNN_LIBRARY="%CUDNN_LIB_F%""
echo [ok] cuDNN: %CUDNN_LIB%
goto cudnn_done
:cudnn_missing
echo.
echo [!] cuDNN not found. The script does NOT install it ^(NVIDIA gives it only after login^).
echo     It is optional: needed only for the cv2.dnn CUDA backend ^(neural networks^),
echo     NOT needed for panorama stitching.
echo     How to install: 1^) open https://developer.nvidia.com/cudnn-downloads ^(free NVIDIA account^)
echo       2^) choose Windows / x86_64 / CUDA %CUDA_MAJOR% and run the installer with default folder
echo       3^) come back here and press R to re-scan.
choice /c ORSA /n /m "[O] open download page   [R] I installed it, re-scan   [S] skip cuDNN   [A] abort : "
if errorlevel 4 goto fail_user
if errorlevel 3 goto cudnn_done
if errorlevel 2 goto cudnn_rescan_go
start "" https://developer.nvidia.com/cudnn-downloads
goto cudnn_missing
:cudnn_rescan_go
set "CUDNN_INC="
set "CUDNN_LIB="
set "CUDNN_BIN="
goto cudnn_scan
:cudnn_done

rem ---- 10. Python paths for CMake ----
>> "%LOG%" echo [%time%] STEP 10. Python paths for CMake
set "PYINFO=%ROOT%\pyinfo.py"
> "%PYINFO%" echo import os, sys, sysconfig, numpy
>> "%PYINFO%" echo b = sys.base_prefix
>> "%PYINFO%" echo print(os.path.join(b, 'Include'))
>> "%PYINFO%" echo print(os.path.join(b, 'libs', 'python' + str(sys.version_info[0]) + str(sys.version_info[1]) + '.lib'))
>> "%PYINFO%" echo print(numpy.get_include())
>> "%PYINFO%" echo print(sysconfig.get_paths()['purelib'])
set "PYN=0"
set "PY_INC="
set "PY_LIB="
set "PY_NUMPY="
set "PYSITE="
for /f "usebackq delims=" %%I in (`""%PYEXE%" "%PYINFO%""`) do call :pyinfo_line "%%I"
if not exist "%PY_INC%\Python.h" goto fail_pyinc
if not exist "%PY_LIB%" goto fail_pyinc
echo [ok] Python headers: %PY_INC%
echo [ok] Python site-packages: %PYSITE%
set "PYEXE_F=%PYEXE:\=/%"
set "PY_INC_F=%PY_INC:\=/%"
set "PY_LIB_F=%PY_LIB:\=/%"
set "PY_NUMPY_F=%PY_NUMPY:\=/%"
set "PYSITE_F=%PYSITE:\=/%"
set "CUDA_PATH_F=%CUDA_PATH:\=/%"
set "CONTRIB_F=%CONTRIB:\=/%"
set "INSTALL_F=%INSTALL:\=/%"

rem ---- 11. sources ----
>> "%LOG%" echo [%time%] STEP 11. sources
if exist "%OCV%\.git" goto src_exist
if /i "%OPENCV_VERSION%"=="latest" call :resolve_latest
echo [git] cloning OpenCV %OPENCV_VERSION% ...
git clone --depth 1 --branch %OPENCV_VERSION% https://github.com/opencv/opencv.git "%OCV%" || goto fail
git clone --depth 1 --branch %OPENCV_VERSION% https://github.com/opencv/opencv_contrib.git "%CONTRIB%" || goto fail
goto src_done
:src_exist
for /f "delims=" %%T in ('git -C "%OCV%" describe --tags --abbrev^=0 2^>nul') do set "OPENCV_VERSION=%%T"
echo [ok] reusing existing sources in %OCV% ^(%OPENCV_VERSION%^)
if not exist "%CONTRIB%\modules" git clone --depth 1 --branch %OPENCV_VERSION% https://github.com/opencv/opencv_contrib.git "%CONTRIB%" || goto fail
:src_done

rem ---- 12. configure ----
>> "%LOG%" echo [%time%] STEP 12. configure
rem note: stale PYTHON* cache entries from earlier runs are cleared in the cmake call below (-UPYTHON*)
rem reuse an existing build dir only if it was made with Ninja; otherwise use a fresh one
if not exist "%BUILD%\CMakeCache.txt" goto gen_ok
findstr /c:"CMAKE_GENERATOR:INTERNAL=Ninja" "%BUILD%\CMakeCache.txt" >nul 2>&1 && goto gen_ok
echo [info] existing build dir uses another generator - using %ROOT%\build_ninja instead
set "BUILD=%ROOT%\build_ninja"
:gen_ok
if "%CLEAN%"=="1" if exist "%BUILD%" rmdir /s /q "%BUILD%"
if not exist "%BUILD%" mkdir "%BUILD%"
echo.
echo [cmake] configuring ^(OpenCV %OPENCV_VERSION%, CUDA %CUDA_VER%, arch %CUDA_ARCH%, cuDNN %CUDNN_ON%^) ...
cmake -G Ninja -S "%OCV%" -B "%BUILD%" ^
 "-UPYTHON*" ^
 -DCMAKE_BUILD_TYPE=Release ^
 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ^
 -DCMAKE_INSTALL_PREFIX="%INSTALL_F%" ^
 -DOPENCV_EXTRA_MODULES_PATH="%CONTRIB_F%/modules" ^
 -DOPENCV_ENABLE_NONFREE=ON ^
 -DWITH_CUDA=ON ^
 -DCUDA_TOOLKIT_ROOT_DIR="%CUDA_PATH_F%" ^
 -DCUDA_ARCH_BIN=%CUDA_ARCH% ^
 -DCUDA_ARCH_PTX= ^
 -DENABLE_FAST_MATH=ON ^
 -DCUDA_FAST_MATH=ON ^
 -DWITH_CUBLAS=ON ^
 -DWITH_CUDNN=%CUDNN_ON% ^
 -DOPENCV_DNN_CUDA=%CUDNN_ON% ^
 %CUDNN_FLAGS% ^
 -DBUILD_opencv_python3=ON ^
 -DOPENCV_PYTHON3_INSTALL_PATH="%PYSITE_F%" ^
 -DPYTHON3_EXECUTABLE="%PYEXE_F%" ^
 -DPYTHON3_INCLUDE_DIR="%PY_INC_F%" ^
 -DPYTHON3_LIBRARY="%PY_LIB_F%" ^
 -DPYTHON3_NUMPY_INCLUDE_DIRS="%PY_NUMPY_F%" ^
 -DBUILD_TESTS=OFF ^
 -DBUILD_PERF_TESTS=OFF ^
 -DBUILD_EXAMPLES=OFF ^
 -DBUILD_DOCS=OFF ^
 -DBUILD_JAVA=OFF ^
 -DBUILD_opencv_java=OFF ^
 2>&1 | powershell -NoProfile -Command "$input | Tee-Object -FilePath '%LOG%' -Append"
if not exist "%BUILD%\build.ninja" goto fail_cfg

rem ---- 13. build + install ----
>> "%LOG%" echo [%time%] STEP 13. build + install
echo.
echo [cmake] building and installing - this takes a long time ...
if exist "%INSTALL%" rmdir /s /q "%INSTALL%"
cmake --build "%BUILD%" --target install 2>&1 | powershell -NoProfile -Command "$input | Tee-Object -FilePath '%LOG%' -Append"
if not exist "%PYSITE%\cv2\__init__.py" goto fail_build

rem ---- 14. make 'import cv2' work from this Python ----
>> "%LOG%" echo [%time%] STEP 14. make 'import cv2' work from this Python
set "MKPTH=%ROOT%\make_pth.py"
set "OCV_BIN="
for /d %%D in ("%INSTALL%\x64\vc*") do set "OCV_BIN=%%D\bin"
> "%MKPTH%" echo import os, sys, sysconfig
>> "%MKPTH%" echo dlls = [d for d in sys.argv[1:] if d and os.path.isdir(d)]
>> "%MKPTH%" echo pth = os.path.join(sysconfig.get_paths()['purelib'], 'opencv_cuda.pth')
>> "%MKPTH%" echo with open(pth, 'w') as f:
>> "%MKPTH%" echo     f.write('import os; [os.add_dll_directory(d) for d in ' + repr(dlls) + ' if os.path.isdir(d)]\n')
>> "%MKPTH%" echo print('wrote', pth)
"%PYEXE%" "%MKPTH%" "%OCV_BIN%" "%CUDA_PATH%\bin" "%CUDA_PATH%\bin\x64" "%CUDNN_BIN%"

rem ---- 15. verify ----
>> "%LOG%" echo [%time%] STEP 15. verify
echo.
echo [verify] import cv2 ...
"%PYEXE%" -c "import cv2;print('OpenCV',cv2.__version__);print('CUDA devices:',cv2.cuda.getCudaEnabledDeviceCount())"
if errorlevel 1 goto fail_verify

echo.
echo ============================================================
echo  DONE.  OpenCV with CUDA installed to %INSTALL%
echo  Log: %LOG%
echo ============================================================
pause
exit /b 0


rem =====================================================================
rem  subroutines
rem =====================================================================

:ensure_cmd
where %~1 >nul 2>&1 && (echo [ok] %~1 & exit /b 0)
echo [missing] %~1 - installing %~2
call :winget_install %~2
where %~1 >nul 2>&1 && exit /b 0
echo [ERROR] %~1 is still not found after install. Close this window and run the script again.
exit /b 1

:winget_install
if "%HAVE_WINGET%"=="0" exit /b 1
winget install -e --id %~1 --silent --accept-package-agreements --accept-source-agreements
call :refresh_path
exit /b 0

:refresh_path
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')"`) do set "PATH=%%P;%PATH%"
for /f "usebackq delims=" %%C in (`powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable('CUDA_PATH','Machine')"`) do set "CUDA_PATH=%%C"
exit /b 0

:pyinfo_line
set /a PYN+=1
if %PYN%==1 set "PY_INC=%~1"
if %PYN%==2 set "PY_LIB=%~1"
if %PYN%==3 set "PY_NUMPY=%~1"
if %PYN%==4 set "PYSITE=%~1"
exit /b 0

:find_python
if defined PYEXE exit /b 0
for /f "delims=" %%P in ('where python 2^>nul') do call :try_python "%%P"
if defined PYEXE exit /b 0
for /f "delims=" %%P in ('py -3 -c "import sys;print(sys.executable)" 2^>nul') do call :try_python "%%P"
exit /b 0

:try_python
if defined PYEXE exit /b 0
echo %~1| findstr /i "WindowsApps" >nul && exit /b 0
set "PYEXE=%~1"
exit /b 0

:find_vs
set "VSPATH="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" exit /b 0
for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -version "[17.0,18.0)" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%I"
if defined VSPATH exit /b 0
for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%I"
exit /b 0

:find_cudnn
if "%~1"=="" exit /b 0
if not exist "%~1" exit /b 0
rem prefer the folder that matches the installed CUDA major version
for /f "delims=" %%F in ('dir /s /b "%~1\cudnn.h" 2^>nul ^| findstr /i "\\%CUDA_MAJOR%\."') do if not defined CUDNN_INC set "CUDNN_INC=%%~dpF"
for /f "delims=" %%F in ('dir /s /b "%~1\cudnn.h" 2^>nul') do if not defined CUDNN_INC set "CUDNN_INC=%%~dpF"
for /f "delims=" %%F in ('dir /s /b "%~1\cudnn.lib" 2^>nul ^| findstr /i "x64" ^| findstr /i "\\%CUDA_MAJOR%\."') do if not defined CUDNN_LIB set "CUDNN_LIB=%%F"
for /f "delims=" %%F in ('dir /s /b "%~1\cudnn.lib" 2^>nul ^| findstr /i "x64"') do if not defined CUDNN_LIB set "CUDNN_LIB=%%F"
for /f "delims=" %%F in ('dir /s /b "%~1\cudnn64_*.dll" 2^>nul ^| findstr /i "\\%CUDA_MAJOR%\."') do if not defined CUDNN_BIN set "CUDNN_BIN=%%~dpF"
for /f "delims=" %%F in ('dir /s /b "%~1\cudnn64_*.dll" 2^>nul') do if not defined CUDNN_BIN set "CUDNN_BIN=%%~dpF"
exit /b 0

:resolve_latest
set "PS1=%ROOT%\latest_tag.ps1"
> "%PS1%" echo $t = git ls-remote --tags --refs https://github.com/opencv/opencv.git
>> "%PS1%" echo $t ^| ForEach-Object { ($_ -split 'refs/tags/')[1] } ^| Where-Object { $_ -match '^^4\.\d+\.\d+$' } ^| Sort-Object { [version]$_ } ^| Select-Object -Last 1
for /f "delims=" %%T in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"') do set "OPENCV_VERSION=%%T"
if /i "%OPENCV_VERSION%"=="latest" set "OPENCV_VERSION=4.12.0"
echo [ok] latest OpenCV release: %OPENCV_VERSION%
exit /b 0

rem =====================================================================
rem  failures
rem =====================================================================
:fail_python
>> "%LOG%" echo [%time%] FAILED at :fail_python
echo [ERROR] Python not found or pip failed. Install Python 3.9+ or pass --python C:\path\python.exe
goto fail
:fail_vs
>> "%LOG%" echo [%time%] FAILED at :fail_vs
echo [ERROR] Visual Studio C++ tools not found. Install "Desktop development with C++" and re-run.
goto fail
:fail_cuda
>> "%LOG%" echo [%time%] FAILED at :fail_cuda
echo [ERROR] CUDA Toolkit not found. Install it from https://developer.nvidia.com/cuda-downloads and re-run.
goto fail
:fail_pyinc
echo [ERROR] Python.h or python3x.lib not found for %PYEXE%
echo         Reinstall Python from python.org with the default options ^(headers and libs included^) or pass --python.
goto fail
:fail_cfg
>> "%LOG%" echo [%time%] FAILED at :fail_cfg
echo [ERROR] CMake configure failed. See %LOG%
goto fail
:fail_build
>> "%LOG%" echo [%time%] FAILED at :fail_build
echo [ERROR] Build failed. See %LOG%
goto fail
:fail_verify
>> "%LOG%" echo [%time%] FAILED at :fail_verify
echo [ERROR] Build finished but 'import cv2' failed. Check the DLL paths and %LOG%
goto fail
:fail_user
>> "%LOG%" echo [%time%] FAILED at :fail_user
echo.
echo Aborted by user.
pause
exit /b 1
:fail
>> "%LOG%" echo [%time%] FAILED at :fail
echo.
echo Build aborted.
pause
exit /b 1
