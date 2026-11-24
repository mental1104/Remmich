#!/usr/bin/env bash
# 为当前 CI 主机选择已安装的 iPhone 模拟器，避免依赖固定机型名称。
# 输入：无参数，依赖 Xcode simctl、jq 和 GITHUB_ENV；最低运行时为测试目标的 iOS 27。
# 输出：诊断信息及后续步骤使用的模拟器 UUID/destination；不启动设备，不下载运行时。
# 无可用设备或工具失败时非零退出，禁止以跳过测试代替失败。
set -euo pipefail

# 优先选择最新的可用 iOS；UUID 仅限当前 job，不能跨 runner 复用。
simulator_id=$(xcrun simctl list devices available --json | jq -r '
  [.devices | to_entries[]
   | select(.key | contains(".iOS-"))
   | (.key | split("iOS-")[1] | split("-") | map(tonumber)) as $version
   | select($version[0] >= 27)
   | .value[]
   | select(.isAvailable == true and (.name | startswith("iPhone")))
   | {version: $version, udid: .udid}]
  | sort_by(.version, .udid) | last | .udid // empty')

if [[ -z "$simulator_id" ]]; then
  echo "No available iPhone simulator with iOS 27 or later."
  xcrun simctl list devices available
  exit 1
fi

echo "Selected iPhone simulator: $simulator_id"
printf 'IPHONE_SIMULATOR_ID=%s\nIPHONE_DESTINATION=platform=iOS Simulator,id=%s\n' \
  "$simulator_id" "$simulator_id" >> "${GITHUB_ENV:?GITHUB_ENV is required}"
