#!/bin/bash
# 在现有macOS/Xcode模拟器执行离线搜索验收；不创建workflow、不下载runtime、不连接图库。
# 输入：phone/tablet或明确模拟器UDID；可选输出目录(必须不存在)、已构建DerivedData目录。
# 第三个参数存在时只执行唯一联合scheme xctestrun，缺失/歧义直接失败，绝不偷偷重新构建。
# 依赖：Xcode、jq；第三参数省略时保留本地构建测试入口。启动等待默认180秒，可用REMMICH_UI_BOOT_TIMEOUT_SECONDS限定1–600秒。
# CI复用select-ci-simulator写入的IPHONE_SIMULATOR_ID；tablet只关闭这个本链iPhone，普通Mac不关闭其他设备。
# 仅CI tablet首次bootstatus等待超时会重启本次选定iPad一次；不重试实际UI测试，也不抹除或重启其他设备。
# 输出：设备/runtime信息、准备及xcodebuild日志和含截图的xcresult；失败保留产物并返回非零。
set -euo pipefail

REMMICH_UI_DEVICE="${1:-phone}"
REMMICH_UI_OUTPUT="${2:-${TMPDIR:-/tmp}/remmich-search-ui-$(date +%Y%m%d-%H%M%S)-$$}"
REMMICH_UI_PREBUILT="${3:-}"
REMMICH_UI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMMICH_UI_BOOT_TIMEOUT_SECONDS="${REMMICH_UI_BOOT_TIMEOUT_SECONDS:-180}"
REMMICH_UI_PREPARE_PID=""
REMMICH_UI_PREPARE_TIMED_OUT=false
if [[ ! "$REMMICH_UI_BOOT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]{0,2}$ ]] || [ "$REMMICH_UI_BOOT_TIMEOUT_SECONDS" -gt 600 ]; then
    echo "Simulator boot timeout must be an integer from 1 to 600 seconds." >&2
    exit 2
fi
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

# 无外部参数，仅处理本脚本实际启动且仍受跟踪的准备命令PID；保留最多3秒退出宽限并回收状态。
# 不向simulator服务、用户的其他设备或任何全局进程发信号。
remmich_ui_stop_preparation() {
    if [ -n "$REMMICH_UI_PREPARE_PID" ]; then
        kill -TERM "$REMMICH_UI_PREPARE_PID" 2>/dev/null || true
        local stop_started=$SECONDS
        while kill -0 "$REMMICH_UI_PREPARE_PID" 2>/dev/null && (( SECONDS - stop_started < 3 )); do
            sleep 1
        done
        if kill -0 "$REMMICH_UI_PREPARE_PID" 2>/dev/null; then
            kill -KILL "$REMMICH_UI_PREPARE_PID" 2>/dev/null || true
        fi
        wait "$REMMICH_UI_PREPARE_PID" 2>/dev/null || true
        REMMICH_UI_PREPARE_PID=""
    fi
}

# 参数为完整准备命令及其独立argv，输出追加到现有证据日志；成功返回0、原失败原样返回、超时返回124。
# 每次重置TIMED_OUT，仅本函数计时到期才置true，不能把simctl自行返回124误判为可恢复超时。
# 用Bash自身计时和单个受控子进程实现，macOS无需GNU timeout或额外安装工具。
remmich_ui_prepare() {
    REMMICH_UI_PREPARE_TIMED_OUT=false
    printf 'Simulator preparation: %s\n' "$*" | tee -a "$REMMICH_UI_OUTPUT/xcodebuild.log"
    "$@" >> "$REMMICH_UI_OUTPUT/xcodebuild.log" 2>&1 &
    REMMICH_UI_PREPARE_PID=$!
    local started=$SECONDS
    while kill -0 "$REMMICH_UI_PREPARE_PID" 2>/dev/null; do
        if (( SECONDS - started >= REMMICH_UI_BOOT_TIMEOUT_SECONDS )); then
            REMMICH_UI_PREPARE_TIMED_OUT=true
            printf 'Simulator preparation timed out after %s seconds.\n' "$REMMICH_UI_BOOT_TIMEOUT_SECONDS" | tee -a "$REMMICH_UI_OUTPUT/xcodebuild.log" >&2
            remmich_ui_stop_preparation
            return 124
        fi
        sleep 1
    done
    local result=0
    wait "$REMMICH_UI_PREPARE_PID" || result=$?
    REMMICH_UI_PREPARE_PID=""
    if [ "$result" -ne 0 ]; then
        printf 'Simulator preparation failed with exit code %s. Native output is in xcodebuild.log.\n' "$result" | tee -a "$REMMICH_UI_OUTPUT/xcodebuild.log" >&2
    fi
    return "$result"
}

trap remmich_ui_stop_preparation EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 只在GitHub明确的job上下文验证此链设备；普通Mac即使残留同名环境变量也不复用/关闭该设备。
if [ "${GITHUB_ACTIONS:-}" = true ] && [[ "$REMMICH_UI_DEVICE" = phone || "$REMMICH_UI_DEVICE" = tablet ]]; then
    if [ -z "${IPHONE_SIMULATOR_ID:-}" ]; then
        echo "CI simulator selection is missing IPHONE_SIMULATOR_ID." >&2
        exit 2
    fi
    REMMICH_UI_CI_PHONE="$(xcrun simctl list devices available --json | jq -er --arg id "$IPHONE_SIMULATOR_ID" '
        [.devices | to_entries[]
          | select(.key | contains("SimRuntime.iOS-"))
          | .key as $runtime
          | select(($runtime | capture("iOS-(?<version>[0-9]+)").version | tonumber) >= 27)
          | .value[] | select(.udid == $id and .isAvailable and (.name | startswith("iPhone")) and (.name | contains("XS") | not))
          | {udid, name, runtime: $runtime, state}]
        | if length == 1 then .[0] else error("CI iPhone is not an available iOS 27+ device") end')"
fi

if [ "$REMMICH_UI_DEVICE" = phone ] && [ "${GITHUB_ACTIONS:-}" = true ]; then
    REMMICH_UI_SELECTION="$REMMICH_UI_CI_PHONE"
    REMMICH_UI_UDID="$IPHONE_SIMULATOR_ID"
fi

case "$REMMICH_UI_DEVICE" in
    phone|tablet)
        if [ "$REMMICH_UI_DEVICE" = phone ] && [ "${GITHUB_ACTIONS:-}" = true ]; then
            : # CI复用构建/逻辑测试的同一iPhone，避免另一套选择算法额外启动不同设备。
        else
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
                  | {udid, name, state, runtime: $runtime, version: $version,
                     rank: (if .name == "iPhone 15 Pro" or .name == "iPad Pro (11-inch) (4th generation)" then 0 else 1 end)}]
                | sort_by(.rank, (.version | map(-.)), .name)
                | if length == 0 then error("No matching available iOS 27+ simulator") else .[0] end')"
            REMMICH_UI_UDID="$(jq -r .udid <<< "$REMMICH_UI_SELECTION")"
        fi
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
              | {udid, name, state, runtime: $runtime}]
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

# 仅tablet的CI阶段关闭本链先前选择的iPhone；未启动就不调用shutdown，普通Mac绝不执行此分支。
if [ "$REMMICH_UI_DEVICE" = tablet ] && [ "${GITHUB_ACTIONS:-}" = true ]; then
    if [ "$(jq -r .state <<< "$REMMICH_UI_CI_PHONE")" != Shutdown ]; then
        remmich_ui_prepare xcrun simctl shutdown "$IPHONE_SIMULATOR_ID"
    fi
fi

# Booted/Booting目标不重复boot，仍必须等bootstatus成功；未知/过渡关闭状态明确失败。
case "$(jq -r .state <<< "$REMMICH_UI_SELECTION")" in
    Shutdown) remmich_ui_prepare xcrun simctl boot "$REMMICH_UI_UDID" ;;
    Booted|Booting) ;;
    *) echo "Selected simulator has an unsupported preparation state." | tee -a "$REMMICH_UI_OUTPUT/xcodebuild.log" >&2; exit 2 ;;
esac
REMMICH_UI_BOOTSTATUS_RESULT=0
remmich_ui_prepare xcrun simctl bootstatus "$REMMICH_UI_UDID" -b || REMMICH_UI_BOOTSTATUS_RESULT=$?
if [ "$REMMICH_UI_BOOTSTATUS_RESULT" -ne 0 ]; then
    if [ "${GITHUB_ACTIONS:-}" = true ] && [ "$REMMICH_UI_DEVICE" = tablet ] && [ "$REMMICH_UI_PREPARE_TIMED_OUT" = true ]; then
        # 首次原生输出和124已保留在追加日志；只恢复本轮明确选中的iPad，第二次不再进入此分支。
        printf 'CI tablet bootstatus timed out with exit code %s; restarting selected simulator %s once.\n' \
            "$REMMICH_UI_BOOTSTATUS_RESULT" "$REMMICH_UI_UDID" | tee -a "$REMMICH_UI_OUTPUT/xcodebuild.log" >&2
        remmich_ui_prepare xcrun simctl shutdown "$REMMICH_UI_UDID"
        remmich_ui_prepare xcrun simctl boot "$REMMICH_UI_UDID"
        remmich_ui_prepare xcrun simctl bootstatus "$REMMICH_UI_UDID" -b
    else
        exit "$REMMICH_UI_BOOTSTATUS_RESULT"
    fi
fi

# 串行执行避免两个UI runner同时旋转模拟器；构建模式保留代码生成和插件安全检查。
xcodebuild "${REMMICH_UI_TEST_ACTION[@]}" \
    -destination "platform=iOS Simulator,id=$REMMICH_UI_UDID" \
    -resultBundlePath "$REMMICH_UI_OUTPUT/SearchUI.xcresult" \
    -only-testing:RemmichUITests/SearchAcceptanceUITests \
    -parallel-testing-enabled NO -jobs "${REMMICH_UI_BUILD_JOBS:-1}" \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee -a "$REMMICH_UI_OUTPUT/xcodebuild.log"
