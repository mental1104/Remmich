#!/bin/bash
# 固定simctl/xcodebuild桩通过真实CLI验证准备脚本；不含Xcode执行或模拟器成功证据。
# 参数1可指定受测脚本绝对路径，默认同目录test-search-ui.sh；依赖Bash、jq、rg，无Xcode/网络。
# 输出保留独立临时案例、完整argv、退出码及子进程回收证据；只结束本例桩PID，不操作真实模拟器。
set -euo pipefail
script=${1:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-search-ui.sh"}
root=$(mktemp -d "${TMPDIR:-/tmp}/remmich-ui-preparation.XXXXXX")
mkdir -p "$root/bin" "$root/prebuilt/Build/Products"
touch "$root/prebuilt/Build/Products/RemmichSearchUI_fixture.xctestrun"
cat > "$root/bin/xcrun" <<'STUB'
#!/bin/bash
# 仅返回固定设备清单及有限状态/失败；hang使用exec让受测脚本拥有的PID就是被等待进程。
set -euo pipefail
printf 'xcrun %s\n' "$*" >> "$MOCK_CASE/calls"
if [[ "$*" = 'simctl list devices available --json' ]]; then cat "$MOCK_CASE/devices.json"; exit; fi
action=$2
# bootstatus次数独立落盘；exec后的PID仍是受测脚本拥有的请求，双超时可以逐项确认都已回收。
bootstatus_count=0
if [[ -f "$MOCK_CASE/bootstatus.count" ]]; then read -r bootstatus_count < "$MOCK_CASE/bootstatus.count"; fi
if [[ "$action" = bootstatus ]]; then
    bootstatus_count=$((bootstatus_count + 1)); printf '%s\n' "$bootstatus_count" > "$MOCK_CASE/bootstatus.count"
    case "${MOCK_BOOTSTATUS_MODE:-}" in
        timeout-once|timeout-then-fail)
            if [[ "$bootstatus_count" = 1 ]]; then
                printf '%s\n' "$$" >> "$MOCK_CASE/request.pids"; exec sleep 60
            fi
            if [[ "$MOCK_BOOTSTATUS_MODE" = timeout-then-fail ]]; then exit 41; fi
            ;;
        timeout-always) printf '%s\n' "$$" >> "$MOCK_CASE/request.pids"; exec sleep 60 ;;
        native-124) exit 124 ;;
    esac
fi
if [[ "$bootstatus_count" = 1 && "$action" = "${MOCK_RECOVERY_FAILURE:-}" ]]; then exit 37; fi
if [[ "$action" = "${MOCK_FAILURE:-}" ]]; then exit 23; fi
if [[ "$action" = "${MOCK_HANG:-}" ]]; then printf '%s\n' "$$" > "$MOCK_CASE/request.pid"; exec sleep 60; fi
case "$action" in boot|bootstatus|shutdown) printf 'mock %s done\n' "$action" ;; *) exit 98 ;; esac
STUB
cat > "$root/bin/xcodebuild" <<'STUB'
#!/bin/bash
# 只记录真实脚本交给xcodebuild的argv，明确没有编译或执行任何Apple测试。
set -euo pipefail
printf 'xcodebuild %s\n' "$*" >> "$MOCK_CASE/calls"
printf 'mock xcodebuild exit %s\n' "${MOCK_XCODE_STATUS:-0}"
exit "${MOCK_XCODE_STATUS:-0}"
STUB
chmod +x "$root/bin/xcrun" "$root/bin/xcodebuild"
local_phone=11111111-1111-4111-8111-111111111111
ci_phone=22222222-2222-4222-8222-222222222222
unrelated=33333333-3333-4333-8333-333333333333
tablet=44444444-4444-4444-8444-444444444444
count=0

# name/state/ciPhoneState限定当前案例的固定清单，不由待测脚本计算期待行为。
new_case() {
    current="$root/$1"; mkdir -p "$current"
    jq -n --arg local "$local_phone" --arg ci "$ci_phone" --arg other "$unrelated" --arg tablet "$tablet" --arg state "$2" --arg ciState "$3" '
      {devices:{"com.apple.CoreSimulator.SimRuntime.iOS-27-2":[
        {udid:$local,name:"iPhone 15 Pro",isAvailable:true,state:$state},
        {udid:$ci,name:"iPhone 17 Pro Max",isAvailable:true,state:$ciState},
        {udid:$other,name:"iPhone 17",isAvailable:true,state:"Booted"},
        {udid:$tablet,name:"iPad Pro 11-inch (M5)",isAvailable:true,state:$state}]}}' > "$current/devices.json"
    : > "$current/calls"
}

# actual/expected状态必须精确相同；失败报告当前证据目录，禁止把未执行当通过。
expect_status() {
    if [[ "$1" != "$2" ]]; then echo "FAIL $current: status $1, expected $2" >&2; exit 1; fi
}

# device/ciFlag/failure/hang/xcodeStatus/ciPhoneID输入真实脚本；可选bootstatusMode/recoveryFailure只控制桩。
# 每例准备等待上限1秒，实际脚本默认180秒不变；输出状态保留供独立断言检查。
run_case() {
    local result=0
    env PATH="$root/bin:$PATH" MOCK_CASE="$current" MOCK_FAILURE="$3" MOCK_HANG="$4" MOCK_XCODE_STATUS="$5" \
        MOCK_BOOTSTATUS_MODE="${7:-}" MOCK_RECOVERY_FAILURE="${8:-}" \
        GITHUB_ACTIONS="$2" IPHONE_SIMULATOR_ID="$6" REMMICH_UI_BOOT_TIMEOUT_SECONDS=1 \
        bash "$script" "$1" "$current/output" "$root/prebuilt" > "$current/console.log" 2>&1 || result=$?
    printf '%s\n' "$result" > "$current/status"
    actual=$result
}

# 仅统计已经逐项断言完成的案例，保留全部桩日志。
passed() { count=$((count + 1)); echo "PASS $count: ${current##*/}"; }

# pattern在实际argv中必须不存在；显式检查rg状态，不能用set-e豁免的!命令伪造反向断言。
absent() {
    local result=0
    rg -q "$1" "$current/calls" || result=$?
    if [[ "$result" != 1 ]]; then echo "Unexpected call or invalid assertion: $1" >&2; exit 1; fi
}

# pid必须是已回收的本例受控子进程；若仍存在立即失败，不能只打印一个非零状态继续计数。
gone() {
    if kill -0 "$1" 2>/dev/null; then echo "Owned request still running: $1" >&2; exit 1; fi
}

# expected规定完整准备顺序；只收shutdown/boot/bootstatus调用，防止恢复碰到无关UDID或发生第三次启动。
expect_actions() {
    rg '^xcrun simctl (shutdown|boot |bootstatus)' "$current/calls" > "$current/actions"
    printf '%s\n' "$@" > "$current/expected-actions"
    cmp "$current/actions" "$current/expected-actions"
}

# 所有挂起桩的实际PID都必须已经消失；只检查本例记录，不能对无关系统进程发信号。
expect_hangs_reaped() {
    local pid
    while read -r pid; do gone "$pid"; done < "$current/request.pids"
}

new_case local-shutdown Shutdown Booted
run_case phone false '' '' 0 "$ci_phone"; expect_status "$actual" 0
jq -e --arg id "$local_phone" '.udid==$id' "$current/output/device.json" >/dev/null
rg -q "^xcrun simctl boot $local_phone$" "$current/calls"
absent '^xcrun simctl shutdown '; passed

new_case local-booted Booted Booted
run_case phone false '' '' 0 "$ci_phone"; expect_status "$actual" 0
absent '^xcrun simctl boot '
rg -q "^xcrun simctl bootstatus $local_phone -b$" "$current/calls"; passed

new_case local-booting Booting Booted
run_case phone false '' '' 0 "$ci_phone"; expect_status "$actual" 0
absent '^xcrun simctl boot '; passed

new_case ci-phone-reuses-build-id Booted Booted
run_case phone true '' '' 0 "$ci_phone"; expect_status "$actual" 0
jq -e --arg id "$ci_phone" '.udid==$id' "$current/output/device.json" >/dev/null
rg -q "^xcrun simctl bootstatus $ci_phone -b$" "$current/calls"
absent '^xcrun simctl shutdown '; passed

new_case ci-tablet-serial-shutdown Shutdown Booted
run_case tablet true '' '' 0 "$ci_phone"; expect_status "$actual" 0
rg '^xcrun simctl (shutdown|boot |bootstatus)' "$current/calls" > "$current/actions"
printf 'xcrun simctl shutdown %s\nxcrun simctl boot %s\nxcrun simctl bootstatus %s -b\n' "$ci_phone" "$tablet" "$tablet" > "$current/expected-actions"
cmp "$current/actions" "$current/expected-actions"
jq -e --arg id "$tablet" '.udid==$id' "$current/output/device.json" >/dev/null; passed

new_case ci-tablet-already-booted Booted Shutdown
run_case tablet true '' '' 0 "$ci_phone"; expect_status "$actual" 0
absent '^xcrun simctl shutdown |^xcrun simctl boot '; passed

new_case local-tablet-does-not-close-other-phone Shutdown Booted
run_case tablet false '' '' 0 "$ci_phone"; expect_status "$actual" 0
absent '^xcrun simctl shutdown '; passed

new_case boot-failure Shutdown Booted
run_case phone false boot '' 0 "$ci_phone"; expect_status "$actual" 23
absent '^xcrun simctl bootstatus |^xcodebuild'; passed

new_case bootstatus-failure Booted Booted
run_case phone false bootstatus '' 0 "$ci_phone"; expect_status "$actual" 23
absent '^xcodebuild'; passed

new_case bootstatus-timeout Booted Booted
run_case phone false '' bootstatus 0 "$ci_phone"; expect_status "$actual" 124
gone "$(cat "$current/request.pid")"
absent '^xcodebuild'
rg -q 'timed out after 1 seconds' "$current/output/xcodebuild.log"; passed

new_case shutdown-failure Shutdown Booted
run_case tablet true shutdown '' 0 "$ci_phone"; expect_status "$actual" 23
absent '^xcrun simctl boot |^xcodebuild'; passed

new_case test-exit-preserved Booted Booted
run_case phone false '' '' 19 "$ci_phone"; expect_status "$actual" 19
rg -q 'Simulator preparation:' "$current/output/xcodebuild.log"
rg -q 'mock xcodebuild exit 19' "$current/output/xcodebuild.log"
rg -q '^-only-testing:| -only-testing:RemmichUITests/SearchAcceptanceUITests ' "$current/calls"; passed

new_case ci-missing-id Booted Booted
run_case tablet true '' '' 0 ''; expect_status "$actual" 2
absent '^xcodebuild|^xcrun simctl shutdown |^xcrun simctl bootstatus '; passed

new_case ci-invalid-id Booted Booted
run_case phone true '' '' 0 "$tablet"
if [[ "$actual" = 0 ]]; then echo 'Invalid CI iPhone must fail' >&2; exit 1; fi
absent '^xcodebuild|^xcrun simctl shutdown |^xcrun simctl bootstatus '; passed

new_case term-cleans-owned-request Booted Booted
env PATH="$root/bin:$PATH" MOCK_CASE="$current" MOCK_HANG=bootstatus GITHUB_ACTIONS=false IPHONE_SIMULATOR_ID="$ci_phone" REMMICH_UI_BOOT_TIMEOUT_SECONDS=30 \
    bash "$script" phone "$current/output" "$root/prebuilt" > "$current/console.log" 2>&1 &
script_pid=$!
for _ in {1..50}; do [[ -s "$current/request.pid" ]] && break; sleep 0.1; done
if [[ ! -s "$current/request.pid" ]]; then kill -TERM "$script_pid"; wait "$script_pid" || true; echo 'Request gate not reached' >&2; exit 1; fi
kill -TERM "$script_pid"
actual=0; wait "$script_pid" || actual=$?
expect_status "$actual" 143
gone "$(cat "$current/request.pid")"
absent '^xcodebuild'; passed

new_case ci-tablet-recovers-first-timeout Shutdown Booted
run_case tablet true '' '' 0 "$ci_phone" timeout-once; expect_status "$actual" 0
expect_actions "xcrun simctl shutdown $ci_phone" "xcrun simctl boot $tablet" "xcrun simctl bootstatus $tablet -b" \
    "xcrun simctl shutdown $tablet" "xcrun simctl boot $tablet" "xcrun simctl bootstatus $tablet -b"
[[ "$(rg -c '^xcodebuild ' "$current/calls")" = 1 ]]
rg -q 'timed out after 1 seconds' "$current/output/xcodebuild.log"
rg -q 'CI tablet bootstatus timed out with exit code 124; restarting selected simulator' "$current/output/xcodebuild.log"
rg -q 'mock xcodebuild exit 0' "$current/output/xcodebuild.log"
expect_hangs_reaped; passed

new_case ci-tablet-two-timeouts-fail Shutdown Booted
run_case tablet true '' '' 0 "$ci_phone" timeout-always; expect_status "$actual" 124
expect_actions "xcrun simctl shutdown $ci_phone" "xcrun simctl boot $tablet" "xcrun simctl bootstatus $tablet -b" \
    "xcrun simctl shutdown $tablet" "xcrun simctl boot $tablet" "xcrun simctl bootstatus $tablet -b"
[[ "$(rg -c 'timed out after 1 seconds' "$current/output/xcodebuild.log")" = 2 ]]
absent '^xcodebuild'; expect_hangs_reaped; passed

new_case ci-tablet-second-status-failure Shutdown Booted
run_case tablet true '' '' 0 "$ci_phone" timeout-then-fail; expect_status "$actual" 41
[[ "$(cat "$current/bootstatus.count")" = 2 ]]
absent '^xcodebuild'; expect_hangs_reaped; passed

new_case ci-tablet-native-124-no-recovery Shutdown Booted
run_case tablet true '' '' 0 "$ci_phone" native-124; expect_status "$actual" 124
expect_actions "xcrun simctl shutdown $ci_phone" "xcrun simctl boot $tablet" "xcrun simctl bootstatus $tablet -b"
absent '^xcodebuild'; passed

new_case ci-tablet-status-error-no-recovery Shutdown Booted
run_case tablet true bootstatus '' 0 "$ci_phone"; expect_status "$actual" 23
expect_actions "xcrun simctl shutdown $ci_phone" "xcrun simctl boot $tablet" "xcrun simctl bootstatus $tablet -b"
absent '^xcodebuild'; passed

new_case ci-phone-two-timeouts-fail Shutdown Booted
run_case phone true '' '' 0 "$ci_phone" timeout-always; expect_status "$actual" 124
expect_actions "xcrun simctl bootstatus $ci_phone -b" "xcrun simctl shutdown $ci_phone" \
    "xcrun simctl boot $ci_phone" "xcrun simctl bootstatus $ci_phone -b"
[[ "$(rg -c 'timed out after 1 seconds' "$current/output/xcodebuild.log")" = 2 ]]
absent '^xcodebuild'; expect_hangs_reaped; passed

new_case local-tablet-timeout-no-recovery Shutdown Booted
run_case tablet false '' '' 0 "$ci_phone" timeout-always; expect_status "$actual" 124
expect_actions "xcrun simctl boot $tablet" "xcrun simctl bootstatus $tablet -b"
absent '^xcodebuild'; expect_hangs_reaped; passed

new_case ci-explicit-tablet-no-recovery Shutdown Booted
run_case "$tablet" true '' '' 0 "$ci_phone" timeout-always; expect_status "$actual" 124
expect_actions "xcrun simctl boot $tablet" "xcrun simctl bootstatus $tablet -b"
absent '^xcodebuild'; expect_hangs_reaped; passed

new_case ci-tablet-boot-error-no-recovery Shutdown Booted
run_case tablet true boot '' 0 "$ci_phone"; expect_status "$actual" 23
expect_actions "xcrun simctl shutdown $ci_phone" "xcrun simctl boot $tablet"
absent '^xcodebuild'; passed

for recovery_failure in shutdown boot; do
    new_case "ci-tablet-recovery-$recovery_failure-fails" Shutdown Booted
    run_case tablet true '' '' 0 "$ci_phone" timeout-once "$recovery_failure"; expect_status "$actual" 37
    [[ "$(cat "$current/bootstatus.count")" = 1 ]]
    if [[ "$recovery_failure" = shutdown ]]; then
        expect_actions "xcrun simctl shutdown $ci_phone" "xcrun simctl boot $tablet" "xcrun simctl bootstatus $tablet -b" "xcrun simctl shutdown $tablet"
    else
        expect_actions "xcrun simctl shutdown $ci_phone" "xcrun simctl boot $tablet" "xcrun simctl bootstatus $tablet -b" \
            "xcrun simctl shutdown $tablet" "xcrun simctl boot $tablet"
    fi
    absent '^xcodebuild'; expect_hangs_reaped; passed
done

new_case ci-tablet-ui-failure-never-retried Shutdown Booted
run_case tablet true '' '' 19 "$ci_phone"; expect_status "$actual" 19
expect_actions "xcrun simctl shutdown $ci_phone" "xcrun simctl boot $tablet" "xcrun simctl bootstatus $tablet -b"
[[ "$(rg -c '^xcodebuild ' "$current/calls")" = 1 ]]; passed

# 与真实phone日志相同的Shutdown→boot→首次status超时；仅当前CI手机可恢复，其他设备不启动/关闭。
new_case ci-phone-recovers-first-timeout Shutdown Shutdown
run_case phone true '' '' 0 "$ci_phone" timeout-once; expect_status "$actual" 0
expect_actions "xcrun simctl boot $ci_phone" "xcrun simctl bootstatus $ci_phone -b" \
    "xcrun simctl shutdown $ci_phone" "xcrun simctl boot $ci_phone" "xcrun simctl bootstatus $ci_phone -b"
jq -e --arg id "$ci_phone" '.udid==$id' "$current/output/device.json" >/dev/null
[[ "$(rg -c '^xcodebuild ' "$current/calls")" = 1 ]]
rg -q 'timed out after 1 seconds' "$current/output/xcodebuild.log"
rg -q 'CI phone bootstatus timed out with exit code 124; restarting selected simulator' "$current/output/xcodebuild.log"
rg -q 'mock xcodebuild exit 0' "$current/output/xcodebuild.log"
expect_hangs_reaped; passed

# 恢复后的第二次原生错误必须原样暴露，不能再启动第三轮或把准备失败记为UI失败。
new_case ci-phone-second-status-failure Booted Booted
run_case phone true '' '' 0 "$ci_phone" timeout-then-fail; expect_status "$actual" 41
expect_actions "xcrun simctl bootstatus $ci_phone -b" "xcrun simctl shutdown $ci_phone" \
    "xcrun simctl boot $ci_phone" "xcrun simctl bootstatus $ci_phone -b"
[[ "$(cat "$current/bootstatus.count")" = 2 ]]
absent '^xcodebuild'; expect_hangs_reaped; passed

# simctl自行返回124不是脚本等待超时；两种非超时错误都不得关闭/重启目标。
new_case ci-phone-native-124-no-recovery Booted Booted
run_case phone true '' '' 0 "$ci_phone" native-124; expect_status "$actual" 124
expect_actions "xcrun simctl bootstatus $ci_phone -b"
absent '^xcodebuild'; passed

new_case ci-phone-status-error-no-recovery Booted Booted
run_case phone true bootstatus '' 0 "$ci_phone"; expect_status "$actual" 23
expect_actions "xcrun simctl bootstatus $ci_phone -b"
absent '^xcodebuild'; passed

# 普通Mac和显式UUID即使首次等待超时，也不能取得CI命名设备才有的一次自动恢复权限。
new_case local-phone-timeout-no-recovery Shutdown Booted
run_case phone false '' '' 0 "$ci_phone" timeout-once; expect_status "$actual" 124
expect_actions "xcrun simctl boot $local_phone" "xcrun simctl bootstatus $local_phone -b"
absent '^xcodebuild'; expect_hangs_reaped; passed

new_case ci-explicit-phone-timeout-no-recovery Booted Booted
run_case "$ci_phone" true '' '' 0 "$ci_phone" timeout-once; expect_status "$actual" 124
expect_actions "xcrun simctl bootstatus $ci_phone -b"
absent '^xcodebuild'; expect_hangs_reaped; passed

# 初始boot失败发生在status前，不满足恢复条件；保留原错误且不启动实际UI测试。
new_case ci-phone-boot-error-no-recovery Shutdown Shutdown
run_case phone true boot '' 0 "$ci_phone"; expect_status "$actual" 23
expect_actions "xcrun simctl boot $ci_phone"
absent '^xcodebuild'; passed

# 恢复shutdown/boot任一步失败即退出，实际失败码和首次超时的子进程回收都要成立。
for recovery_failure in shutdown boot; do
    new_case "ci-phone-recovery-$recovery_failure-fails" Booted Booted
    run_case phone true '' '' 0 "$ci_phone" timeout-once "$recovery_failure"; expect_status "$actual" 37
    [[ "$(cat "$current/bootstatus.count")" = 1 ]]
    if [[ "$recovery_failure" = shutdown ]]; then
        expect_actions "xcrun simctl bootstatus $ci_phone -b" "xcrun simctl shutdown $ci_phone"
    else
        expect_actions "xcrun simctl bootstatus $ci_phone -b" "xcrun simctl shutdown $ci_phone" "xcrun simctl boot $ci_phone"
    fi
    absent '^xcodebuild'; expect_hangs_reaped; passed
done

# 准备恢复成功后实际UI仍可能失败；只能执行一次xcodebuild，原19必须保留而不再重试测试。
new_case ci-phone-ui-failure-after-recovery-never-retried Booted Booted
run_case phone true '' '' 19 "$ci_phone" timeout-once; expect_status "$actual" 19
expect_actions "xcrun simctl bootstatus $ci_phone -b" "xcrun simctl shutdown $ci_phone" \
    "xcrun simctl boot $ci_phone" "xcrun simctl bootstatus $ci_phone -b"
[[ "$(rg -c '^xcodebuild ' "$current/calls")" = 1 ]]
rg -q 'mock xcodebuild exit 19' "$current/output/xcodebuild.log"
expect_hangs_reaped; passed

printf 'PASS: %s real-script mock cases. Evidence: %s\n' "$count" "$root"
