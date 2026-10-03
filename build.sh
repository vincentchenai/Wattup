#!/bin/bash
# 编译 Wattup 并组装成可运行的 .app bundle
#
#   ./build.sh               构建 release 版，产物在 .build/Wattup.app
#   ./build.sh --run         构建后启动
#   ./build.sh --install     构建后装到 /Applications 并启动（之后可从访达直接开）
#   ./build.sh --preview     构建后以预览窗口模式启动（不开菜单栏项，方便截图核对界面）
#   ./build.sh --clean       清理构建目录后重新构建
#   ./build.sh --help        显示这份说明
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Wattup"
BUNDLE_ID="app.wattup.menubar"
VERSION="0.1.0"          # ← 发版时改这里，会同时写进 Info.plist 与「关于」面板
CONFIG="release"
OUT_DIR=".build"
APP_DIR="${OUT_DIR}/${APP_NAME}.app"
INSTALL_DIR="/Applications/${APP_NAME}.app"

usage() {
    cat <<'USAGE'
用法: ./build.sh [选项]

  （无选项）     构建 release 版，产物在 .build/Wattup.app
  --run          构建后启动
  --install      构建后装到 /Applications 并启动；之后可从访达/启动台直接开
  --preview      构建后以预览窗口模式启动（不开菜单栏项，方便截图核对界面）
  --clean        先删掉 .build 再重新构建
  --help, -h     显示这份说明

产物是自包含的 .app，可以直接拖进「应用程序」文件夹使用。
USAGE
    exit 0
}

DO_RUN=0
DO_INSTALL=0
DO_PREVIEW=0
DO_CLEAN=0

for arg in "$@"; do
    case "${arg}" in
        --help|-h)  usage ;;
        --run)      DO_RUN=1 ;;
        --install)  DO_INSTALL=1 ;;
        --preview)  DO_PREVIEW=1 ;;
        --clean)    DO_CLEAN=1 ;;
        *)
            echo "未知参数: ${arg}（用 --help 看用法）" >&2
            exit 2
            ;;
    esac
done

if [ "${DO_CLEAN}" = 1 ]; then
    echo "==> 清理 ${OUT_DIR}"
    rm -rf "${OUT_DIR}"
fi

echo "==> swift build -c ${CONFIG}"
# 某些受限环境（含从终端/沙箱启动的 CI）下 SwiftPM 无法用 sandbox-exec 编译 manifest，
# 报 "sandbox-exec: sandbox_apply: Operation not permitted"，此时自动回退
if ! swift build -c "${CONFIG}"; then
    echo "    ⚠️  常规构建失败，改用 --disable-sandbox 重试"
    swift build -c "${CONFIG}" --disable-sandbox
fi

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [ ! -x "${BIN_PATH}" ]; then
    echo "构建产物不存在: ${BIN_PATH}" >&2
    exit 1
fi

echo "==> 组装 ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# 应用图标：没有图标时，本应用在弹窗的能耗排行里会显示成一个空白方块
ICON_SRC="resources/AppIcon.icns"
if [ -f "${ICON_SRC}" ]; then
    cp "${ICON_SRC}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
else
    echo "    ⚠️  缺少 ${ICON_SRC}（可用 tools/make_icon.py 生成）"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Wattup</string>
</dict>
</plist>
PLIST

# ad-hoc 签名。打包成正式分发（Developer ID + 公证）时替换这一步。
# 签名失败不中断构建 —— 本地跑仍然可用，只是「开机自启」可能注册不上，
# 所以这里只警告，不让整个流程卡在最后一步。
echo "==> ad-hoc 签名"
if ! codesign --force --sign - --timestamp=none "${APP_DIR}" 2>&1 | sed 's/^/    /'; then
    echo "    ⚠️  签名失败：应用仍可运行，但 SMAppService 开机自启可能注册不上" >&2
fi

echo "==> 完成: ${APP_DIR}  (v${VERSION})"

if [ "${DO_INSTALL}" = 1 ]; then
    echo "==> 安装到 ${INSTALL_DIR}"
    # 按 bundle 内的可执行路径匹配，而不是写死 ${INSTALL_DIR} ——
    # 从 .build/Wattup.app 直接启动的实例路径不含 /Applications，
    # 只匹配 INSTALL_DIR 会漏掉它，装完就变成两个菜单栏图标。
    if pgrep -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1; then
        echo "    退出正在运行的旧实例（含从 .build 启动的）"
        pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" || true
        sleep 1
    fi
    if ditto "${APP_DIR}" "${INSTALL_DIR}" 2>/dev/null; then
        echo "    已安装。之后可从访达 / 启动台直接打开，也可以在这里删："
        echo "    rm -rf \"${INSTALL_DIR}\""
        echo "==> 启动已安装的副本"
        open "${INSTALL_DIR}"
    else
        echo "    ❌ 写入 /Applications 失败（可能不是管理员账户）。两种办法：" >&2
        echo "       1) sudo ditto \"${APP_DIR}\" \"${INSTALL_DIR}\"" >&2
        echo "       2) 直接把 ${APP_DIR} 拖进「应用程序」文件夹" >&2
        exit 1
    fi
elif [ "${DO_RUN}" = 1 ]; then
    echo "==> 启动"
    open "${APP_DIR}"
elif [ "${DO_PREVIEW}" = 1 ]; then
    echo "==> 预览模式启动（带 --ui-preview）"
    pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    "${APP_DIR}/Contents/MacOS/${APP_NAME}" --ui-preview &
    echo "    pid=$!"
fi
