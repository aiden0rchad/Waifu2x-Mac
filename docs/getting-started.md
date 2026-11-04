# Build and first run

The v1.0.1 source preview targets **Apple Silicon and macOS 26**. The build was exercised on macOS 26.5.1 with Qt 6.11.1. The Homebrew formulas and Apple command-line tools must support your version of macOS. The engine archives contain the executables and model weights, so leave room for both the downloads and the assembled app.

## 1. Install the build tools

Install Apple's command-line tools if prompted by `xcode-select -p`. Install [Homebrew](https://brew.sh/) in its standard Apple Silicon location, `/opt/homebrew`.

```sh
xcode-select --install
```

Run the following commands in a new Terminal after the Apple installer finishes.

```sh
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install gh qtbase qt5compat qtmultimedia qtsvg qttools ffmpeg imagemagick gifsicle sox
gh auth status || gh auth login
```

The packaging script looks up media helpers under `/opt/homebrew/bin`. Keep FFmpeg and ImageMagick installed while using the app. Gifsicle provides GIF optimization and SoX covers optional audio tooling. APNG tooling depends on separately available `apngasm` and `apngdis` executables.

## 2. Compile the GUI

Clone the release tag using the commands below, or download and verify the [source archive](releases.md) and start at `mkdir -p build-mac` from the extracted project directory.

```sh
git clone --depth 1 --branch v1.0.1 https://github.com/aiden0rchad/Waifu2x-Mac.git
cd Waifu2x-Mac
mkdir -p build-mac
cd build-mac
/opt/homebrew/bin/qmake6 ../src/Waifu2xMacGUI.pro -spec macx-clang
make -j"$(sysctl -n hw.logicalcpu)"
cd ..
```

The result is `build-mac/Waifu2xMacGUI.app`. Assemble it before testing media jobs so the GUI can find the tools and weights it needs.

## 3. Download the engine archives

Run this block from the repository root. It keeps each upstream macOS asset and its extracted contents in the layout expected by the bundle script.

```sh
(
  set -e
  fetch_engine() {
    dir="build-mac/engines/$1"
    mkdir -p "$dir"
    gh release download "$3" --repo "$2" --pattern "$4" --dir "$dir" --skip-existing
    unzip -oq "$dir/$4" -d "$dir"
  }

  fetch_engine waifu2x nihui/waifu2x-ncnn-vulkan 20250915 waifu2x-ncnn-vulkan-20250915-macos.zip
  fetch_engine realsr nihui/realsr-ncnn-vulkan 20220728 realsr-ncnn-vulkan-20220728-macos.zip
  fetch_engine srmd nihui/srmd-ncnn-vulkan 20220728 srmd-ncnn-vulkan-20220728-macos.zip
  fetch_engine rife nihui/rife-ncnn-vulkan 20221029 rife-ncnn-vulkan-20221029-macos.zip
  fetch_engine realcugan nihui/realcugan-ncnn-vulkan 20220728 realcugan-ncnn-vulkan-20220728-macos.zip
  fetch_engine realesrgan xinntao/Real-ESRGAN v0.2.5.0 realesrgan-ncnn-vulkan-20220424-macos.zip
)
```

## 4. Assemble and open the app

```sh
scripts/bundle-mac.sh build-mac/Waifu2xMacGUI.app build-mac/engines
codesign --verify --deep --strict dist/Waifu2x-Mac.app
open dist/Waifu2x-Mac.app
```

This creates an ad-hoc-signed local build. In the app, open **Settings → Run engine check**. Start with one image and follow the [illustrated walkthrough](walkthrough.md). If a check fails, use the [troubleshooting guide](troubleshooting.md).

To install the app for normal use, drag `dist/Waifu2x-Mac.app` into **Applications** in Finder. Keep the standard Homebrew tools installed. Use a separate writable folder for your first output.
