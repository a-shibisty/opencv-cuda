# build_opencv_cuda.bat

One-file Windows script that builds **OpenCV with CUDA** (plus `opencv_contrib` and the Python `cv2` bindings).
It checks the required tools, installs what it can through `winget`, asks about what it cannot install, then configures and builds with CMake + Ninja.

> Status: tested on Windows 11, RTX 2070, Visual Studio, CUDA 13.x, cuDNN 9.x.
> The "clean machine" path (installing everything from scratch) follows the same code but has not been run end-to-end.

## Quick start

1. Install the **NVIDIA driver** first (the script cannot do it for you).
2. Put `build_opencv_cuda.bat` anywhere and run it (double-click or from a terminal). It asks for administrator rights.
3. Point it at the Python you will actually use, ideally a venv:

```bat
build_opencv_cuda.bat --python C:\path\to\venv\Scripts\python.exe
```

A full build takes from one to several hours and about 30 GB of disk space. Re-running is safe: finished steps are skipped and Ninja only rebuilds what changed.

## Options

| Option | Meaning |
|---|---|
| `--python <python.exe>` | Python to build the bindings for and install `cv2` into (venv recommended) |
| `--version X.Y.Z` | OpenCV tag to build. Default: the latest 4.x release |
| `--arch 7.5` | CUDA compute capability. Default: detected with `nvidia-smi`, fallback 7.5. **Use the dotted form** (`7.5`, not `75`) |
| `--no-cudnn` | Build without cuDNN (no CUDA backend for `cv2.dnn`) |
| `--clean` | Delete the build directory first (forces a full rebuild) |

The work directory is `C:\build` (`ROOT` at the top of the script). Sources are expected in `C:\build\opencv` and `C:\build\opencv_contrib` and are cloned there if missing.

## What it does

1. Asks for administrator rights.
2. **Preflight** — things the script cannot install by itself. For each one it explains how to install it and asks what to do (open the download page / re-check / continue anyway / abort):
   - `winget` (App Installer)
   - at least 30 GB of free disk space
   - NVIDIA driver (`nvidia-smi` must run)
   - cuDNN (optional, only needed for `cv2.dnn` on CUDA; the script searches `CUDNN_PATH`, `Program Files\NVIDIA\CUDNN` and the CUDA folder)
3. Installs through `winget` if missing: Git, Python 3.12, Visual Studio 2022 Build Tools (C++ workload), CMake, Ninja, CUDA Toolkit.
4. Detects the CUDA version and the GPU architecture.
5. Installs `numpy` into the chosen Python and removes `opencv-python*` pip packages that would shadow the build.
6. Configures (Ninja, Release, `WITH_CUDA`, `OPENCV_ENABLE_NONFREE`, contrib modules, cuDNN if found) and builds the `install` target into `C:\build\install`.
7. Installs the `cv2` package into the chosen Python's `site-packages`, writes `opencv_cuda.pth` with the extra DLL directories (OpenCV, CUDA, cuDNN), and verifies:

```
import cv2; print(cv2.__version__, cv2.cuda.getCudaEnabledDeviceCount())
```

A progress line for every step and any failure label is appended to `C:\build\build.log`, followed by the full CMake and Ninja output.

## Pip wheel

If `make_wheel.py` sits next to the script, the last step packs the finished build into `C:\build\wheel\opencv_cuda_custom-<ver>+cuda<ver>-cp312-cp312-win_amd64.whl`
(OpenCV DLLs bundled, relocatable loader config, no absolute `C:\build` paths). You can also run it by hand:

```bat
python make_wheel.py --cv2-dir <site-packages>\cv2 --bin-dir C:\build\install\x64\vc18\bin --out C:\build\wheel --version 4.14.0 --cuda 13.5
```

Install it into any venv with the same Python minor version:

```bat
pip uninstall -y opencv-python opencv-contrib-python opencv-python-headless opencv-contrib-python-headless
pip install --force-reinstall C:\build\wheel\opencv_cuda_custom-4.14.0+cuda13.5-cp312-cp312-win_amd64.whl
```

CUDA Toolkit and cuDNN DLLs are **not** bundled: the target machine needs the NVIDIA driver and the same CUDA major version
(found via `CUDA_PATH` or the default install folder), plus cuDNN if `cv2.dnn` on CUDA is used.

## Check the result

```bat
python -c "import cv2; print(cv2.__file__, cv2.__version__); print(cv2.cuda.getCudaEnabledDeviceCount())"
```

You should see a path inside your `site-packages`, a 4.x version and a device count of 1 or more. Count `0` with a working import means OpenCV was built with CUDA but cannot see the GPU (driver problem) or another CPU-only `cv2` is shadowing it.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `nvcc fatal: Unsupported gpu architecture 'compute_7'` | `CUDA_ARCH_BIN` was given as `75`. Use `7.5` |
| `fatal error C1083: Cannot open include file: 'Python.h'` | The Python has no headers (or is a venv created from a Python without them). The script now checks this and stops early. Reinstall Python with default options or pass another `--python` |
| `Python.h` still not found although the headers exist | CMake cached wrong Python paths from an earlier failed run. The script clears `PYTHON*` cache entries (`-UPYTHON*`) on every configure |
| App still reports "CUDA unavailable" | Another `cv2` (usually a pip `opencv-python`) is imported. Run the check command above with the same Python the app uses and compare `cv2.__file__` |
| `ImportError: DLL load failed` | CUDA 13 on Windows keeps DLLs in `bin\x64`. The generated `opencv_cuda.pth` adds it; if you copied `cv2` by hand, add the directory with `os.add_dll_directory` |
| CMake complains about a different generator | An old build directory was made with Visual Studio. The script detects this and builds in `C:\build\build_ninja` instead |
| `winget` not found | Install "App Installer" from the Microsoft Store (https://aka.ms/getwinget) or install the tools manually; they are detected |
| A tool "is still not found after install" | Close the window and run the script again (PATH is refreshed, but some installers need a fresh session or a reboot) |

## Notes

- The Visual Studio 2022 toolset is preferred; if none is found the newest installed one is used.
- Changing the compiler, CUDA version or Python between runs may make CMake invalidate the cache. Use `--clean` if a configure step fails after such a change.
- The script only touches `C:\build`, the chosen Python's `site-packages` (installs `cv2`, `numpy`, `opencv_cuda.pth`) and installs the tools listed above via `winget`.
