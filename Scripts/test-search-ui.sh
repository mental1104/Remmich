#!/bin/bash
# 在现有macOS/Xcode模拟器执行离线搜索验收；不创建workflow、不下载runtime、不连接图库。
# 输入：phone/tablet或明确模拟器UDID；可选输出目录(必须不存在)、已构建DerivedData目录。
# 第三个参数存在时只执行唯一联合scheme xctestrun，缺失/歧义直接失败，绝不偷偷重新构建。
# 依赖：Xcode、jq；第三参数省略时保留本地构建测试入口。
# 输出：设备/runtime信息、xcodebuild日志和含截图的xcresult；失败保留产物并返回非零。
set -euo pipefail

REMMICH_UI_DEVICE="${1:-phone}"
REMMICH_UI_OUTPUT="${2:-${TMPDIR:-/tmp}/remmich-search-ui-$(date +%Y%m%d-%H%M%S)-$$}"
REMMICH_UI_PREBUILT="${3:-}"
REMMICH_UI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for REMMICH_UI_COMMAND in xcodebuild xcrun jq; do
    if ! command -v "$REMMICH_UI_COMMAND" >/dev/null; then
        echo "Required command not found: $REMMICH_UI_COMMAND" >&2
        exit 127
    fi
done
if [ -e "$REMMICH_UI_OUTPUT" ]; then
    echo "Output directory already exists: $REMMICH_UI_OUTPUT" >&2
    exit 2
fi

case "$REMMICH_UI_DEVICE" in
    phone|tablet)
        # 优先指定用户机型；若runtime不提供该设备，明确记录实际可用替代型号，绝不声称是真机验收。
        REMMICH_UI_SELECTION="$(xcrun simctl list devices available --json | jq -er --arg family "$REMMICH_UI_DEVICE" '
            [.devices | to_entries[]
              | select(.key | contains("SimRuntime.iOS-"))
              | .key as $runtime
              | ($runtime | capture("iOS-(?<version>[0-9]+(?:-[0-9]+)*)").version
                 | split("-") | map(tonumber)) as $version
              | select($version[0] >= 27)
              | .value[]
              | select(.isAvailable and (.name | contains("XS") | not))
              | select(if $family == "phone" then (.name | startswith("iPhone")) else (.name | startswith("iPad Pro") and contains("11-inch")) end)
              | {udid, name, runtime: $runtime, version: $version,
                 rank: (if .name == "iPhone 15 Pro" or .name == "iPad Pro (11-inch) (4th generation)" then 0 else 1 end)}]
            | sort_by(.rank, (.version | map(-.)), .name)
            | if length == 0 then error("No matching available iOS 27+ simulator") else .[0] end')"
        REMMICH_UI_UDID="$(jq -r .udid <<< "$REMMICH_UI_SELECTION")"
        ;;
    *)
        # 显式UDID仍交给simctl验证存在/可用；不隐式创建或抹除设备。
        REMMICH_UI_SELECTION="$(xcrun simctl list devices available --json | jq -er --arg id "$REMMICH_UI_DEVICE" '
            [.devices | to_entries[]
              | select(.key | contains("SimRuntime.iOS-"))
              | .key as $runtime
              | select(($runtime | capture("iOS-(?<version>[0-9]+)").version | tonumber) >= 27)
              | .value[]
              | select(.udid == $id and .isAvailable and (.name | contains("XS") | not))
              | {udid, name, runtime: $runtime}]
            | if length == 1 then .[0] else error("Simulator UDID not found or unavailable") end')"
        REMMICH_UI_UDID="$REMMICH_UI_DEVICE"
        ;;
esac

mkdir -p "$REMMICH_UI_OUTPUT"
printf '%s\n' "$REMMICH_UI_SELECTION" | tee "$REMMICH_UI_OUTPUT/device.json"
cd "$REMMICH_UI_ROOT"
if [ -n "$REMMICH_UI_PREBUILT" ]; then
    # 单个联合清单同时指向AppLogic/UI产品；不回退到其他scheme或任意find首项。
    shopt -s nullglob
    REMMICH_UI_MANIFESTS=("$REMMICH_UI_PREBUILT"/Build/Products/RemmichSearchUI_*.xctestrun)
    if [ "${#REMMICH_UI_MANIFESTS[@]}" -ne 1 ]; then
        echo "Expected exactly one prebuilt RemmichSearchUI xctestrun manifest." >&2
        exit 2
    fi
    REMMICH_UI_TEST_ACTION=(test-without-building -xctestrun "${REMMICH_UI_MANIFESTS[0]}")
else
    REMMICH_UI_TEST_ACTION=(test -project Remmich.xcodeproj -scheme RemmichSearchUI -configuration Debug
        -derivedDataPath "$REMMICH_UI_OUTPUT/DerivedData")
fi

# 串行执行避免两个UI runner同时旋转模拟器；构建模式保留代码生成和插件安全检查。
xcodebuild "${REMMICH_UI_TEST_ACTION[@]}" \
    -destination "platform=iOS Simulator,id=$REMMICH_UI_UDID" \
    -resultBundlePath "$REMMICH_UI_OUTPUT/SearchUI.xcresult" \
    -only-testing:RemmichUITests/SearchAcceptanceUITests \
    -parallel-testing-enabled NO -jobs "${REMMICH_UI_BUILD_JOBS:-1}" \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$REMMICH_UI_OUTPUT/xcodebuild.log"
