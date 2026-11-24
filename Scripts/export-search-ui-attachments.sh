#!/usr/bin/env bash
# 从本次PR已有的phone/tablet xcresult导出原始附件，便于无Xcode环境审查PNG与工具生成的manifest。
# 输入：RUNNER_TEMP目录；依赖：runner现有xcrun/xcresulttool、jq。输出：每设备attachments与导出日志。
# 仅处理已有结果，不创建未运行设备的截图；保留原xcresult/log/device.json，不覆盖已导出附件。
# 两设备依次尝试；任何工具、清单或目录冲突错误最终非零退出，失败产物仍供always-upload保存。
set -euo pipefail

REMMICH_ATTACHMENTS_ROOT="${1:?Expected the current runner temporary directory}"
REMMICH_ATTACHMENTS_STATUS=0
for REMMICH_ATTACHMENTS_DEVICE in phone tablet; do
    REMMICH_ATTACHMENTS_DEVICE_ROOT="$REMMICH_ATTACHMENTS_ROOT/RemmichSearchUI-$REMMICH_ATTACHMENTS_DEVICE"
    REMMICH_ATTACHMENTS_RESULT="$REMMICH_ATTACHMENTS_DEVICE_ROOT/SearchUI.xcresult"
    if [ ! -d "$REMMICH_ATTACHMENTS_RESULT" ]; then
        echo "No search UI result bundle for $REMMICH_ATTACHMENTS_DEVICE; nothing to export."
        continue
    fi
    REMMICH_ATTACHMENTS_OUTPUT="$REMMICH_ATTACHMENTS_DEVICE_ROOT/attachments"
    if [ -e "$REMMICH_ATTACHMENTS_OUTPUT" ]; then
        echo "Attachment output already exists: $REMMICH_ATTACHMENTS_OUTPUT" >&2
        REMMICH_ATTACHMENTS_STATUS=1
        continue
    fi
    REMMICH_ATTACHMENTS_LOG="$REMMICH_ATTACHMENTS_DEVICE_ROOT/attachment-export.log"
    # Apple推荐以当前工具help核对接口；记录实际Xcode27自带工具证据，不使用legacy对象解析或失败附件过滤。
    if {
        xcrun xcresulttool version &&
            xcrun xcresulttool help export attachments &&
            xcrun xcresulttool export attachments \
                --path "$REMMICH_ATTACHMENTS_RESULT" --output-path "$REMMICH_ATTACHMENTS_OUTPUT"
    } > "$REMMICH_ATTACHMENTS_LOG" 2>&1; then
        # manifest必须由xcresulttool真实输出；仅验证JSON语法，不伪造空清单或假设未来字段结构。
        if [ -f "$REMMICH_ATTACHMENTS_OUTPUT/manifest.json" ] &&
            jq -s -e 'length == 1' "$REMMICH_ATTACHMENTS_OUTPUT/manifest.json" >> "$REMMICH_ATTACHMENTS_LOG" 2>&1; then
            echo "Exported search UI attachments for $REMMICH_ATTACHMENTS_DEVICE to $REMMICH_ATTACHMENTS_OUTPUT"
        else
            echo "Missing or invalid xcresulttool attachment manifest for $REMMICH_ATTACHMENTS_DEVICE." >&2
            REMMICH_ATTACHMENTS_STATUS=1
        fi
    else
        echo "Search UI attachment export failed for $REMMICH_ATTACHMENTS_DEVICE." >&2
        REMMICH_ATTACHMENTS_STATUS=1
    fi
    cat "$REMMICH_ATTACHMENTS_LOG"
done
exit "$REMMICH_ATTACHMENTS_STATUS"
