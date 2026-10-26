#!/bin/bash

set -u

AONE_CORP="${AONE_CORP:?需要设置 AONE_CORP}"
AONE_USER="${AONE_USER:?需要设置 AONE_USER}"
AONE_PASS="${AONE_PASS:?需要设置 AONE_PASS}"
SMS_SCRIPT="${SMS_SCRIPT:?需要设置 SMS_SCRIPT（验证码脚本路径）}"
AONE_HOME="${AONE_HOME:-/data/aone}"
MARKER="$AONE_HOME/.configured"
# 自动登录时间段（容器本地时间，格式 HH:MM:SS-HH:MM:SS，分/秒可省略如 8-22、8:30-22:00）。
# 仅当检测到下线且当前时间落在该范围内才自动拉起登录。默认 00:00:00-23:59:59（全天）。
AUTO_LOGIN_TIME_RANGE="${AUTO_LOGIN_TIME_RANGE:-00:00:00-23:59:59}"

if [ ! -x "$SMS_SCRIPT" ]; then
    echo "[entrypoint] 错误: SMS_SCRIPT=$SMS_SCRIPT 不存在或不可执行" >&2
    exit 65
fi

mkdir -p "$AONE_HOME"
cd "$AONE_HOME"

log() { echo "[entrypoint] $(date '+%F %T') $*"; }

# ---------- 1. 首次初始化 ----------
if [ ! -f "$MARKER" ]; then
    log "首次运行，执行 AOne --config 初始化..."
    if config.exp "$AONE_CORP" "$AONE_USER" "$AONE_PASS"; then
        touch "$MARKER"
        log "初始化完成"
    else
        rc=$?
        log "初始化失败 (rc=$rc)，退出"
        exit "$rc"
    fi
else
    log "已存在初始化标记，跳过 --config"
fi

# ---------- 2. 启动 AOne 守护进程 ctEAO ----------
# AOne CLI 只是客户端，真正干活的是 ctEAO 守护进程
# （物理机上由 aone-client.service 拉起，命令: ctEAO /subclient）
if ! pgrep -x ctEAO >/dev/null; then
    log "启动 ctEAO 守护进程..."
    /usr/local/aone/bin/ctEAO /subclient >/var/log/cteao.log 2>&1 &
    CTEAO_PID=$!
    sleep 3
    if ! kill -0 "$CTEAO_PID" 2>/dev/null; then
        log "ctEAO 启动失败，日志如下:"
        cat /var/log/cteao.log
        exit 10
    fi
    log "ctEAO 已启动 (pid=$CTEAO_PID)"
else
    log "ctEAO 已在运行"
fi

# ---------- 3. 启动 mihomo ----------
if [ -d /etc/mihomo ] && ls /etc/mihomo/*.yaml >/dev/null 2>&1; then
    log "启动 mihomo..."
    mihomo -d /etc/mihomo >/var/log/mihomo.log 2>&1 &
    MIHOMO_PID=$!
    sleep 2
    if ! kill -0 "$MIHOMO_PID" 2>/dev/null; then
        log "mihomo 启动失败，日志如下:"
        cat /var/log/mihomo.log
        exit 20
    fi
    log "mihomo 已启动 (pid=$MIHOMO_PID)"
else
    log "警告: 未检测到 /etc/mihomo 配置，跳过 mihomo 启动"
fi

# ---------- 4. 登录 + 守护循环 ----------
# AOne --login 是 CLI：首次登录输出"登录成功"后 CLI 会退出，隧道由 ctEAO 维持。
# 会话约 8 小时后失效，表现为 `AOne --status` 输出"用户已下线..."。
# 因此每 60s 检查一次：ctEAO 死了 -> 重启；状态为已下线/无会话 -> 执行 login.exp。
# 将 "H[:MM[:SS]]" 解析为自 0 点起的秒数并打印；格式非法时返回 1
_parse_hms() {
    local t h m s rest
    t="${1//[[:space:]]/}"
    h="${t%%:*}"
    rest="${t#*:}"
    if [ "$t" = "$h" ]; then
        m=0; s=0
    else
        m="${rest%%:*}"
        if [ "$rest" = "$m" ]; then
            s=0
        else
            s="${rest#*:}"
        fi
    fi
    case "$h" in ''|*[!0-9]*) return 1 ;; esac
    case "$m" in ''|*[!0-9]*) return 1 ;; esac
    case "$s" in ''|*[!0-9]*) return 1 ;; esac
    h=$((10#$h)); m=$((10#$m)); s=$((10#$s))
    { [ "$h" -ge 0 ] && [ "$h" -le 23 ]; } || return 1
    { [ "$m" -ge 0 ] && [ "$m" -le 59 ]; } || return 1
    { [ "$s" -ge 0 ] && [ "$s" -le 59 ]; } || return 1
    echo $((h * 3600 + m * 60 + s))
}

# 当前时间是否落在 AUTO_LOGIN_TIME_RANGE 内。0=在范围内（允许登录）；1=不在范围内（跳过）。
# 配置为空或非法时一律视为不限制（返回 0），避免因配置错误而永不登录。
in_login_window() {
    local range start end now
    range="${AUTO_LOGIN_TIME_RANGE//[[:space:]]/}"
    [ -z "$range" ] && return 0
    start=$(_parse_hms "${range%%-*}") || { log "自动登录时间段配置非法: '$AUTO_LOGIN_TIME_RANGE'，视为不限制"; return 0; }
    end=$(_parse_hms "${range#*-}")    || { log "自动登录时间段配置非法: '$AUTO_LOGIN_TIME_RANGE'，视为不限制"; return 0; }
    now=$((10#$(date +%H) * 3600 + 10#$(date +%M) * 60 + 10#$(date +%S)))
    if [ "$start" -le "$end" ]; then
        # 同日区间，如 8:00-22:00
        { [ "$now" -ge "$start" ] && [ "$now" -le "$end" ]; } && return 0
    else
        # 跨午夜区间，如 22:00-06:00
        { [ "$now" -ge "$start" ] || [ "$now" -le "$end" ]; } && return 0
    fi
    return 1
}

check_session() {
    # 返回 0 = 在线；1 = 已下线或状态未知（需登录）
    # status 实测输出: 在线="用户已上线..."  下线="用户已下线..."
    local out
    out=$(timeout 20 AOne --status 2>&1 || true)
    if echo "$out" | grep -q "已下线"; then
        log "状态: 已下线"
        return 1
    fi
    if echo "$out" | grep -q "已上线"; then
        return 0
    fi
    log "状态未知: $out"
    # 未登录过时 status 会提示先 config/login，视为无会话
    return 1
}

attempt=0
while :; do
    attempt=$((attempt + 1))
    log "=== 第 $attempt 轮检查 ==="

    # ctEAO 守护进程存活检查
    if ! grep -lq "^/usr/local/aone/bin/ctEAO" /proc/[0-9]*/cmdline 2>/dev/null; then
        log "ctEAO 未运行，重启..."
        /usr/local/aone/bin/ctEAO /subclient >>/var/log/cteao.log 2>&1 &
        sleep 3
    fi

    if check_session; then
        log "AOne 会话有效，隧道运行中"
    elif ! in_login_window; then
        log "会话无效，但当前时间不在自动登录时间段 ($AUTO_LOGIN_TIME_RANGE) 内，跳过本次自动登录"
    else
        log "会话无效，执行登录..."
        login.exp "$SMS_SCRIPT"
        rc=$?
        case $rc in
            0|11)
                log "登录流程完成，隧道应由 ctEAO 维持"
                ;;
            2)
                log "图形验证码识别错误，稍后重试"
                sleep 2
                continue
                ;;
            3)
                log "短信验证码问题，10s 后重试"
                sleep 10
                continue
                ;;
            *)
                log "登录异常 (rc=$rc)，15s 后重试"
                sleep 15
                continue
                ;;
        esac
    fi

    # 每 60s 复查一次状态（约 8 小时掉线会在此被捕获并自动重登）
    sleep 60
done
