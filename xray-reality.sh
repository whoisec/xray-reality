#!/bin/sh
# shellcheck shell=bash
# Xray VLESS Reality 单节点管理脚本
# 适配：Debian 10-13、Ubuntu、Arch Linux、Alpine Linux
# 不包含：WARP、BBR、复杂分流、多入站、多用户

# Alpine 默认没有 Bash：首次以 root 执行时自动安装并重新进入 Bash。
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if [ "$(id -u)" -eq 0 ] && command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash >/dev/null || exit 1
        else
            echo "[错误] 本脚本需要 Bash；请先安装 bash。" >&2
            exit 1
        fi
    fi
    exec bash "$0" "$@"
fi

set -Eeuo pipefail
umask 077

readonly SCRIPT_VERSION="2.0.0"
readonly CONFIG_FILE="${XRAY_CONFIG_FILE:-/usr/local/etc/xray/config.json}"
CONFIG_DIR="$(dirname "$CONFIG_FILE")"
readonly CONFIG_DIR
readonly BACKUP_DIR="${XRAY_BACKUP_DIR:-/usr/local/etc/xray/backups}"
readonly XRAY_CORE_BIN="${XRAY_CORE_BIN:-/usr/local/bin/xray-core}"
readonly XRAY_COMMAND="${XRAY_COMMAND:-/usr/local/bin/xray}"
readonly MANAGER_BIN="${XRAY_MANAGER_BIN:-/usr/local/bin/xray-reality}"
readonly SERVICE_NAME="${XRAY_SERVICE_NAME:-xray}"
readonly SERVICE_USER="${XRAY_SERVICE_USER:-xray}"
readonly XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases"

OS_ID=''; OS_VERSION=''; PKG_FAMILY=''; INIT_SYSTEM=''; SERVICE_GROUP=''
RUNTIME_TMP="$(mktemp -d)" || { echo "[错误] 无法创建临时目录。" >&2; exit 1; }
readonly RUNTIME_TMP

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'
    BLUE='\033[34m'; CYAN='\033[36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi

info()    { printf '%b\n' "${BLUE}[信息]${RESET} $*"; }
success() { printf '%b\n' "${GREEN}[成功]${RESET} $*"; }
warn()    { printf '%b\n' "${YELLOW}[提示]${RESET} $*"; }
die()     { printf '%b\n' "${RED}[错误]${RESET} $*" >&2; exit 1; }

cleanup() {
    rm -rf -- "$RUNTIME_TMP" 2>/dev/null || true
}
trap cleanup EXIT

make_temp_dir() {
    local dir
    dir="$(mktemp -d "$RUNTIME_TMP/item.XXXXXX")" || die "无法创建临时目录。"
    printf '%s\n' "$dir"
}

pause() { if [[ -t 0 ]]; then read -r -p "按 Enter 返回菜单..." _ || true; fi; }
confirm() { local answer; read -r -p "${1:-确认继续？} [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]]; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行此操作。"; }

detect_platform() {
    [[ -r /etc/os-release ]] || die "无法识别操作系统：缺少 /etc/os-release"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-unknown}"
    case "$OS_ID" in
        debian|ubuntu) PKG_FAMILY='apt' ;;
        arch|manjaro|endeavouros) PKG_FAMILY='pacman' ;;
        alpine) PKG_FAMILY='apk' ;;
        *)
            case " ${ID_LIKE:-} " in
                *' debian '*) PKG_FAMILY='apt' ;;
                *' arch '*) PKG_FAMILY='pacman' ;;
                *) die "暂不支持当前系统：$OS_ID $OS_VERSION" ;;
            esac
            ;;
    esac
    if command_exists systemctl && [[ -d /run/systemd/system ]]; then
        INIT_SYSTEM='systemd'
    elif command_exists rc-service && command_exists rc-update; then
        INIT_SYSTEM='openrc'
    else
        die "未检测到 systemd 或 OpenRC。"
    fi
}

install_dependencies() {
    require_root; detect_platform
    case "$PKG_FAMILY" in
        apt)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y bash curl ca-certificates jq openssl qrencode unzip
            ;;
        pacman)
            pacman -Syu --needed --noconfirm bash curl ca-certificates jq openssl qrencode unzip
            ;;
        apk)
            apk add --no-cache bash curl ca-certificates jq openssl qrencode unzip
            update-ca-certificates >/dev/null 2>&1 || true
            ;;
    esac
}

detect_init_only() {
    [[ -n "$INIT_SYSTEM" ]] && return 0
    if command_exists systemctl && [[ -d /run/systemd/system ]]; then
        INIT_SYSTEM='systemd'
    elif command_exists rc-service && command_exists rc-update; then
        INIT_SYSTEM='openrc'
    else
        return 1
    fi
}

architecture_asset() {
    case "$(uname -m)" in
        x86_64|amd64) printf '64\n' ;;
        i386|i486|i586|i686) printf '32\n' ;;
        aarch64|arm64) printf 'arm64-v8a\n' ;;
        armv7l|armv7*) printf 'arm32-v7a\n' ;;
        armv6l|armv6*) printf 'arm32-v6\n' ;;
        s390x) printf 's390x\n' ;;
        ppc64le) printf 'ppc64le\n' ;;
        riscv64) printf 'riscv64\n' ;;
        *) die "不支持的 CPU 架构：$(uname -m)" ;;
    esac
}

download_xray_archive() {
    local destination="$1" arch version url digest expected actual
    arch="$(architecture_asset)"; version="${XRAY_VERSION:-latest}"
    if [[ "$version" == latest ]]; then
        url="$XRAY_RELEASE_BASE/latest/download/Xray-linux-${arch}.zip"
    else
        [[ "$version" == v* ]] || version="v$version"
        url="$XRAY_RELEASE_BASE/download/${version}/Xray-linux-${arch}.zip"
    fi
    info "下载 Xray Core：$url"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 "$url" -o "$destination"
    digest="${destination}.dgst"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 "${url}.dgst" -o "$digest"
    expected="$(awk -F'= *' '/SHA2-256|256=/{gsub(/[[:space:]]/,"",$2); print tolower($2); exit}' "$digest")"
    actual="$(sha256sum "$destination" | awk '{print tolower($1)}')"
    [[ -n "$expected" && "$actual" == "$expected" ]] || die "Xray 压缩包 SHA256 校验失败。"
}

install_xray_core() {
    local temp archive extracted
    temp="$(make_temp_dir)"; archive="$temp/xray.zip"; extracted="$temp/extracted"
    mkdir -p "$extracted" /usr/local/share/xray
    download_xray_archive "$archive"
    unzip -q "$archive" -d "$extracted"
    [[ -f "$extracted/xray" ]] || die "压缩包内未找到 Xray 可执行文件。"
    chmod 755 "$extracted/xray"
    "$extracted/xray" version >/dev/null 2>&1 || die "下载的 Xray 无法运行，可能与系统架构不兼容。"
    install -m 755 "$extracted/xray" "${XRAY_CORE_BIN}.new"
    mv -f "${XRAY_CORE_BIN}.new" "$XRAY_CORE_BIN"
    [[ -f "$extracted/geoip.dat" ]] && install -m 644 "$extracted/geoip.dat" /usr/local/share/xray/geoip.dat
    [[ -f "$extracted/geosite.dat" ]] && install -m 644 "$extracted/geosite.dat" /usr/local/share/xray/geosite.dat
}

ensure_service_user() {
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        if [[ "$PKG_FAMILY" == apk ]]; then
            adduser -S -D -H -s /sbin/nologin "$SERVICE_USER"
        else
            local nologin='/usr/sbin/nologin'; [[ -x "$nologin" ]] || nologin='/usr/bin/nologin'
            useradd --system --no-create-home --home-dir /nonexistent --shell "$nologin" "$SERVICE_USER"
        fi
    fi
    SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
    install -d -m 755 "$CONFIG_DIR" /usr/local/share/xray
    install -d -m 700 "$BACKUP_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 750 /var/log/xray
    touch /var/log/xray/access.log /var/log/xray/error.log /var/log/xray/service.log
    chown "$SERVICE_USER:$SERVICE_GROUP" /var/log/xray/*.log
    chmod 600 /var/log/xray/*.log
}

install_manager_command() {
    local source_path source_dir source_name
    source_path="${BASH_SOURCE[0]}"
    source_dir="$(cd -P "$(dirname "$source_path")" 2>/dev/null && pwd)" || source_dir=''
    source_name="$(basename "$source_path")"
    [[ -n "$source_dir" ]] && source_path="$source_dir/$source_name"
    if [[ -f "$source_path" && "$source_path" != /dev/fd/* && "$source_path" != /proc/*/fd/* ]]; then
        [[ "$source_path" == "$MANAGER_BIN" ]] || install -m 755 "$source_path" "$MANAGER_BIN"
        chmod 755 "$MANAGER_BIN"
    elif [[ ! -x "$MANAGER_BIN" ]]; then
        die "无法持久化管理脚本；请先将脚本保存到本地文件再运行。"
    fi
    cat >"$XRAY_COMMAND" <<EOF
#!/bin/sh
# XRAY_REALITY_MENU_WRAPPER
if [ "\$#" -eq 0 ]; then
    exec "$MANAGER_BIN"
fi
if [ ! -x "$XRAY_CORE_BIN" ]; then
    echo "Xray Core 尚未安装，请直接运行 xray 并选择安装。" >&2
    exit 127
fi
exec "$XRAY_CORE_BIN" "\$@"
EOF
    chmod 755 "$XRAY_COMMAND"
}

install_service_definition() {
    detect_init_only || die "无法安装服务：未检测到 systemd 或 OpenRC。"
    if [[ "$INIT_SYSTEM" == systemd ]]; then
        cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray VLESS Reality Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$XRAY_CORE_BIN run -config $CONFIG_FILE
Restart=on-failure
RestartSec=3s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 /etc/systemd/system/xray.service
        systemctl daemon-reload
    else
        cat >/etc/init.d/xray <<EOF
#!/sbin/openrc-run
name="Xray VLESS Reality"
description="Xray VLESS Reality Service"
command="$XRAY_CORE_BIN"
command_args="run -config $CONFIG_FILE"
command_user="$SERVICE_USER:$SERVICE_GROUP"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
output_log="/var/log/xray/service.log"
error_log="/var/log/xray/error.log"

depend() {
    need net
    after firewall
}
EOF
        chmod 755 /etc/init.d/xray
    fi
}

service_is_active() {
    detect_init_only || return 1
    if [[ "$INIT_SYSTEM" == systemd ]]; then systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null
    else rc-service "$SERVICE_NAME" status >/dev/null 2>&1; fi
}

service_is_enabled() {
    detect_init_only || return 1
    if [[ "$INIT_SYSTEM" == systemd ]]; then systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null
    else rc-update show default 2>/dev/null | grep -Eq "^[[:space:]]*${SERVICE_NAME}[[:space:]]"; fi
}

service_enable_start() {
    if [[ "$INIT_SYSTEM" == systemd ]]; then
        systemctl enable --now "$SERVICE_NAME"
    else
        rc-update add "$SERVICE_NAME" default >/dev/null
        if service_is_active; then rc-service "$SERVICE_NAME" restart; else rc-service "$SERVICE_NAME" start; fi
    fi
}

service_control() {
    local action="$1"
    detect_init_only || die "未检测到服务管理器。"
    case "$action" in start|stop|restart) ;; *) die "未知服务操作：$action" ;; esac
    if [[ "$INIT_SYSTEM" == systemd ]]; then systemctl "$action" "$SERVICE_NAME"
    else rc-service "$SERVICE_NAME" "$action"; fi
}

service_disable_stop() {
    detect_init_only || return 0
    if [[ "$INIT_SYSTEM" == systemd ]]; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    else
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
    fi
}

service_logs() {
    local lines="${1:-100}"; [[ "$lines" =~ ^[0-9]+$ ]] || lines=100
    detect_init_only || die "未检测到服务管理器。"
    if [[ "$INIT_SYSTEM" == systemd ]]; then journalctl -u "$SERVICE_NAME" --no-pager -n "$lines"
    else tail -n "$lines" /var/log/xray/service.log /var/log/xray/error.log 2>/dev/null || true; fi
}

set_config_permissions() {
    local file="$1"
    [[ -n "$SERVICE_GROUP" ]] || SERVICE_GROUP="$(id -gn "$SERVICE_USER" 2>/dev/null || printf '%s' "$SERVICE_USER")"
    chown "$SERVICE_USER:$SERVICE_GROUP" "$file"; chmod 600 "$file"
}

require_config() { [[ -s "$CONFIG_FILE" ]] || die "未找到配置：$CONFIG_FILE，请先安装。"; }
is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
is_valid_domain() { [[ ${#1} -le 253 ]] && [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }

validate_xray_config() {
    local file="$1" output=''
    jq empty "$file" >/dev/null 2>&1 || { jq empty "$file" >&2 || true; return 1; }
    [[ -x "$XRAY_CORE_BIN" ]] || return 1
    if output="$($XRAY_CORE_BIN run -test -config "$file" 2>&1)"; then return 0; fi
    if output="$($XRAY_CORE_BIN -test -config "$file" 2>&1)"; then return 0; fi
    printf '%s\n' "$output" >&2; return 1
}

ensure_supported_config() {
    require_config
    jq empty "$CONFIG_FILE" >/dev/null 2>&1 || die "配置不是标准 JSON：$CONFIG_FILE"
    local inbounds clients
    inbounds="$(jq '[.inbounds[]? | select(.protocol=="vless" and .streamSettings.security=="reality")] | length' "$CONFIG_FILE")"
    clients="$(jq '[.inbounds[] | select(.protocol=="vless" and .streamSettings.security=="reality")][0].settings.clients | length' "$CONFIG_FILE")"
    [[ "$inbounds" == 1 && "$clients" == 1 ]] || die "只支持单入站、单链接配置。"
}

get_value() {
    local base='[.inbounds[] | select(.protocol=="vless" and .streamSettings.security=="reality")][0]'
    case "$1" in
        port) jq -r "$base.port" "$CONFIG_FILE" ;;
        listen) jq -r "$base.listen // \"0.0.0.0\"" "$CONFIG_FILE" ;;
        sni) jq -r "$base.streamSettings.realitySettings.serverNames[0]" "$CONFIG_FILE" ;;
        private_key) jq -r "$base.streamSettings.realitySettings.privateKey" "$CONFIG_FILE" ;;
        short_id) jq -r "$base.streamSettings.realitySettings.shortIds[0] // \"\"" "$CONFIG_FILE" ;;
        uuid) jq -r "$base.settings.clients[0].id" "$CONFIG_FILE" ;;
        name) jq -r "$base.settings.clients[0].email // \"default\"" "$CONFIG_FILE" ;;
        *) return 1 ;;
    esac
}

new_uuid() {
    local value; value="$($XRAY_CORE_BIN uuid 2>/dev/null | tr -d '\r\n')"
    [[ "$value" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Xray 生成 UUID 失败。"; printf '%s\n' "$value"
}
new_short_id() { openssl rand -hex 8; }

generate_key_pair() {
    local output private_key public_key
    output="$($XRAY_CORE_BIN x25519 2>&1)" || die "Xray 生成 Reality 密钥失败：$output"
    private_key="$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$output" | tr -d '\r ')"
    public_key="$(awk -F': *' 'tolower($1) ~ /(public|password)/ {print $2; exit}' <<<"$output" | tr -d '\r ')"
    [[ -n "$private_key" && -n "$public_key" ]] || die "无法解析 xray x25519 输出：$output"
    printf '%s\t%s\n' "$private_key" "$public_key"
}

public_key_from_private() {
    local output public_key
    output="$($XRAY_CORE_BIN x25519 -i "$1" 2>&1)" || die "无法计算 Reality 公钥：$output"
    public_key="$(awk -F': *' 'tolower($1) ~ /(public|password)/ {print $2; exit}' <<<"$output" | tr -d '\r ')"
    [[ -n "$public_key" ]] || die "无法解析 Reality 公钥。"; printf '%s\n' "$public_key"
}

create_backup() {
    require_config; mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    local backup; backup="$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S)-$$.json"
    cp -p "$CONFIG_FILE" "$backup"; chown root:root "$backup"; chmod 600 "$backup"; printf '%s\n' "$backup"
}

apply_candidate() {
    local candidate="$1" backup
    require_root; validate_xray_config "$candidate" || die "新配置验证失败，未修改现有配置。"
    backup="$(create_backup)"; set_config_permissions "$candidate"; mv -f "$candidate" "$CONFIG_FILE"
    if service_control restart && service_is_active; then success "配置已生效；备份：$backup"; return 0; fi
    warn "Xray 启动失败，正在自动回滚。"
    cp -p "$backup" "$CONFIG_FILE"; set_config_permissions "$CONFIG_FILE"
    service_control restart >/dev/null 2>&1 || true; die "修改已回滚，请查看日志。"
}

edit_config_with_jq() {
    local filter="$1" temp candidate; shift; ensure_supported_config
    temp="$(make_temp_dir)"; candidate="$temp/config.json"
    jq "$@" "$filter" "$CONFIG_FILE" >"$candidate" || die "生成新配置失败。"; apply_candidate "$candidate"
}

write_initial_config() {
    local listen="$1" port="$2" sni="$3" uuid="$4" name="$5" private_key="$6" short_id="$7" temp candidate
    temp="$(make_temp_dir)"; candidate="$temp/config.json"
    jq -n --arg listen "$listen" --argjson port "$port" --arg sni "$sni" --arg uuid "$uuid" \
        --arg name "$name" --arg privateKey "$private_key" --arg shortId "$short_id" \
        '{log:{access:"/var/log/xray/access.log",error:"/var/log/xray/error.log",loglevel:"warning"},inbounds:[{tag:"vless-reality",listen:$listen,port:$port,protocol:"vless",settings:{clients:[{id:$uuid,email:$name,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$privateKey,shortIds:[$shortId]}},sniffing:{enabled:true,destOverride:["http","tls","quic"]}}],outbounds:[{protocol:"freedom",tag:"direct"}]}' >"$candidate"
    validate_xray_config "$candidate" || die "初始配置验证失败。"
    [[ -s "$CONFIG_FILE" ]] && create_backup >/dev/null
    set_config_permissions "$candidate"; mv -f "$candidate" "$CONFIG_FILE"
}

install_action() {
    require_root; printf '%b\n' "${BOLD}安装 Xray VLESS Reality${RESET}"
    if [[ -s "$CONFIG_FILE" ]]; then warn "已存在配置：$CONFIG_FILE"; confirm "覆盖并重新安装？" || return 0; fi
    install_dependencies; ensure_service_user; install_xray_core
    local family listen port sni name uuid keys private_key public_key short_id
    read -r -p "监听协议 IPv4/IPv6 [4]: " family; family="${family:-4}"
    case "$family" in 4) listen='0.0.0.0' ;; 6) listen='::' ;; *) die "只能输入 4 或 6。" ;; esac
    read -r -p "监听端口 [14169]: " port; port="${port:-14169}"; is_valid_port "$port" || die "端口无效：$port"
    read -r -p "Reality SNI [learn.microsoft.com]: " sni; sni="${sni:-learn.microsoft.com}"; is_valid_domain "$sni" || die "域名无效：$sni"
    read -r -p "节点名称 [default]: " name; name="${name:-default}"
    [[ -n "$name" && ${#name} -le 64 && "$name" != *$'\n'* ]] || die "节点名称无效。"
    uuid="$(new_uuid)"; keys="$(generate_key_pair)"; IFS=$'\t' read -r private_key public_key <<<"$keys"; short_id="$(new_short_id)"
    write_initial_config "$listen" "$port" "$sni" "$uuid" "$name" "$private_key" "$short_id"
    install_manager_command; install_service_definition; service_enable_start
    service_is_active || die "Xray 服务启动失败，请查看日志。"
    success "安装完成；管理命令：xray"; show_node_action
}

detect_public_ip() {
    local family="${1:-4}" ip=''
    if [[ "$family" == 6 ]]; then
        ip="$(curl -6fsS --max-time 6 https://api64.ipify.org 2>/dev/null || true)"; [[ -n "$ip" ]] || ip="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
    else
        ip="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"; [[ -n "$ip" ]] || ip="$(curl -6fsS --max-time 6 https://api64.ipify.org 2>/dev/null || true)"
    fi
    printf '%s\n' "$ip"
}
urlencode() { jq -nr --arg value "$1" '$value|@uri'; }
format_host() { if [[ "$1" == *:* && "$1" != \[*\] ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi; }

build_vless_url() {
    local host; host="$(format_host "$3")"
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
        "$1" "$host" "$4" "$(urlencode "$5")" "$(urlencode "$6")" "$(urlencode "$7")" "$(urlencode "VLESS-REALITY-$2")"
}

show_node_action() {
    ensure_supported_config
    local listen family host port sni private_key public_key short_id uuid name url
    listen="$(get_value listen)"; family=4; [[ "$listen" == *:* ]] && family=6
    host="${XRAY_PUBLIC_IP:-$(detect_public_ip "$family")}"; [[ -n "$host" ]] || read -r -p "请输入服务器公网 IP 或域名: " host
    [[ -n "$host" ]] || die "服务器地址不能为空。"
    port="$(get_value port)"; sni="$(get_value sni)"; private_key="$(get_value private_key)"
    public_key="$(public_key_from_private "$private_key")"; short_id="$(get_value short_id)"; uuid="$(get_value uuid)"; name="$(get_value name)"
    url="$(build_vless_url "$uuid" "$name" "$host" "$port" "$sni" "$public_key" "$short_id")"
    printf '\n%b\n' "${BOLD}节点信息${RESET}"
    printf '%s\n' "服务器：$host" "端口：$port" "SNI：$sni" "UUID：$uuid" "PublicKey：$public_key" "ShortID：$short_id" '' "$url"
    if command_exists qrencode && [[ -t 1 ]]; then qrencode -t ANSIUTF8 "$url" 2>/dev/null || qrencode -t UTF8 "$url" 2>/dev/null || true; fi
}

status_action() {
    local status enabled version='未安装' port='-' sni='-' platform init
    detect_init_only || true; init="${INIT_SYSTEM:-未知}"
    if service_is_active; then status="${GREEN}运行中${RESET}"; else status="${RED}未运行${RESET}"; fi
    if service_is_enabled; then enabled="${GREEN}已启用${RESET}"; else enabled="${YELLOW}未启用${RESET}"; fi
    [[ -x "$XRAY_CORE_BIN" ]] && version="$($XRAY_CORE_BIN version 2>/dev/null | head -n1 || true)"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        platform="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-${ID:-Linux}}")"
    else
        platform='Linux'
    fi
    if [[ -s "$CONFIG_FILE" ]] && command_exists jq && jq empty "$CONFIG_FILE" >/dev/null 2>&1; then port="$(get_value port 2>/dev/null || printf '-')"; sni="$(get_value sni 2>/dev/null || printf '-')"; fi
    printf '%b\n' "Xray 状态 : $status" "开机启动  : $enabled"
    printf '%s\n' "系统/服务 : $platform / $init" "Xray 版本 : $version" "监听端口  : $port" "Reality SNI: $sni" "管理命令  : xray"
}

change_port_action() {
    require_root; ensure_supported_config
    local old new; old="$(get_value port)"; read -r -p "新端口 [当前 $old]: " new; new="${new:-$old}"
    is_valid_port "$new" || die "端口无效：$new"; [[ "$new" != "$old" ]] || { info "端口未变化。"; return; }
    # shellcheck disable=SC2016
    edit_config_with_jq '.inbounds |= map(if .protocol=="vless" and .streamSettings.security=="reality" then .port=$port else . end)' --argjson port "$new"
    warn "请确认系统防火墙和云安全组已放行 TCP/$new。"
}

change_sni_action() {
    require_root; ensure_supported_config
    local old new; old="$(get_value sni)"; read -r -p "新 SNI [当前 $old]: " new; new="${new:-$old}"
    is_valid_domain "$new" || die "域名无效：$new"; [[ "$new" != "$old" ]] || { info "SNI 未变化。"; return; }
    # shellcheck disable=SC2016
    edit_config_with_jq '.inbounds |= map(if .protocol=="vless" and .streamSettings.security=="reality" then .streamSettings.realitySettings.serverNames=[$sni] | .streamSettings.realitySettings.dest=($sni+":443") else . end)' --arg sni "$new"
}

reset_node_action() {
    require_root; ensure_supported_config; warn "重置后旧链接会立即失效。"; confirm "确认重置节点凭据？" || return
    local uuid keys private_key public_key short_id
    uuid="$(new_uuid)"; keys="$(generate_key_pair)"; IFS=$'\t' read -r private_key public_key <<<"$keys"; short_id="$(new_short_id)"
    # shellcheck disable=SC2016
    edit_config_with_jq '.inbounds |= map(if .protocol=="vless" and .streamSettings.security=="reality" then .settings.clients[0].id=$uuid | .streamSettings.realitySettings.privateKey=$privateKey | .streamSettings.realitySettings.shortIds=[$shortId] else . end)' --arg uuid "$uuid" --arg privateKey "$private_key" --arg shortId "$short_id"
    success "节点凭据已重置。"; show_node_action
}

check_config_action() {
    ensure_supported_config
    if validate_xray_config "$CONFIG_FILE"; then success "配置检查通过。"; else die "配置检查失败。"; fi
}
backup_action() { require_root; ensure_supported_config; local backup; backup="$(create_backup)"; success "备份完成：$backup"; }

restore_action() {
    require_root
    local files=() file choice candidate temp current i
    shopt -s nullglob; for file in "$BACKUP_DIR"/config-*.json; do files+=("$file"); done; shopt -u nullglob
    ((${#files[@]})) || die "没有可用备份。"
    mapfile -t files < <(printf '%s\n' "${files[@]}" | sort -r)
    for i in "${!files[@]}"; do printf '%2d. %s\n' "$((i+1))" "${files[$i]}"; done
    read -r -p "选择要恢复的备份: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || ! ((10#$choice >= 1 && 10#$choice <= ${#files[@]})); then die "选择无效。"; fi
    temp="$(make_temp_dir)"; candidate="$temp/config.json"; cp -p "${files[$((10#$choice-1))]}" "$candidate"
    validate_xray_config "$candidate" || die "备份配置验证失败。"
    current="$(create_backup)"; set_config_permissions "$candidate"; mv -f "$candidate" "$CONFIG_FILE"
    if service_control restart && service_is_active; then success "恢复完成；恢复前配置：$current"; return; fi
    cp -p "$current" "$CONFIG_FILE"; set_config_permissions "$CONFIG_FILE"; service_control restart >/dev/null 2>&1 || true; die "恢复失败，已回滚。"
}

update_action() {
    require_root; install_dependencies
    local temp old_core=''; temp="$(make_temp_dir)"
    if [[ -x "$XRAY_CORE_BIN" ]]; then old_core="$temp/xray-core.old"; cp -p "$XRAY_CORE_BIN" "$old_core"; fi
    install_xray_core; install_manager_command
    if [[ -s "$CONFIG_FILE" ]]; then
        validate_xray_config "$CONFIG_FILE" || { [[ -n "$old_core" ]] && cp -p "$old_core" "$XRAY_CORE_BIN"; die "更新后配置验证失败，已恢复旧版本。"; }
        if ! service_control restart || ! service_is_active; then
            [[ -n "$old_core" ]] && cp -p "$old_core" "$XRAY_CORE_BIN"; service_control restart >/dev/null 2>&1 || true; die "更新后服务启动失败，已恢复旧版本。"
        fi
    fi
    success "更新完成：$($XRAY_CORE_BIN version | head -n1)"
}

uninstall_action() {
    require_root; warn "此操作将卸载 Xray Core 并删除当前配置。"
    local answer backup=''; read -r -p "请输入 UNINSTALL 确认: " answer; [[ "$answer" == UNINSTALL ]] || { info "已取消。"; return; }
    if [[ -s "$CONFIG_FILE" ]]; then backup="/root/xray-reality-config-before-uninstall-$(date +%Y%m%d-%H%M%S).json"; cp -p "$CONFIG_FILE" "$backup"; chown root:root "$backup"; chmod 600 "$backup"; fi
    detect_init_only || true; service_disable_stop
    rm -f /etc/systemd/system/xray.service /etc/init.d/xray "$XRAY_CORE_BIN"
    if [[ "$INIT_SYSTEM" == systemd ]]; then systemctl daemon-reload || true; fi
    rm -rf "$CONFIG_DIR" /usr/local/share/xray /var/log/xray
    install_manager_command
    [[ -n "$backup" ]] && warn "卸载前配置：$backup"; success "Xray Core 已卸载；运行 xray 可重新安装。"
}

node_settings_menu() {
    while true; do
        clear 2>/dev/null || true; printf '%b\n' "${BOLD}节点设置${RESET}"
        cat <<'EOF'
1. 修改监听端口
2. 修改 Reality SNI
3. 重置节点凭据
4. 检查配置
5. 备份配置
6. 恢复配置
0. 返回
EOF
        local choice; read -r -p "请选择: " choice
        case "$choice" in
            1) change_port_action; pause ;; 2) change_sni_action; pause ;; 3) reset_node_action; pause ;;
            4) check_config_action; pause ;; 5) backup_action; pause ;; 6) restore_action; pause ;;
            0) return ;; *) warn "无效选项。"; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        printf '%b\n' "${CYAN}${BOLD}========== Xray VLESS Reality 管理脚本 v${SCRIPT_VERSION} ==========${RESET}"
        status_action
        cat <<'EOF'

 1. 安装 / 重新安装
 2. 查看节点链接和二维码
 3. 节点设置
 4. 重启 Xray
 5. 查看状态
 6. 查看日志
 7. 更新 Xray
 8. 卸载 Xray
 0. 退出
EOF
        local choice; read -r -p "请选择: " choice
        case "$choice" in
            1) install_action; pause ;; 2) show_node_action; pause ;; 3) node_settings_menu ;;
            4) require_root; service_control restart; pause ;; 5) status_action; pause ;; 6) service_logs 100; pause ;;
            7) update_action; pause ;; 8) uninstall_action; pause ;; 0) exit 0 ;; *) warn "无效选项。"; sleep 1 ;;
        esac
    done
}

usage() {
    cat <<EOF
Xray VLESS Reality 管理脚本 v$SCRIPT_VERSION

用法：
  xray                         打开管理菜单
  xray install                 安装/重新安装
  xray status                  查看状态
  xray show                    查看节点和二维码
  xray change-port             修改端口
  xray change-sni              修改 SNI
  xray reset-node              重置节点凭据
  xray check                   检查配置
  xray backup                  备份配置
  xray restore                 恢复配置
  xray start|stop|restart      管理服务
  xray logs [行数]             查看日志
  xray update                  更新 Xray
  xray uninstall               卸载 Xray

其他 Xray Core 参数会直接转发，例如：xray version
EOF
}

main() {
    local command="${1:-menu}"
    case "$command" in
        menu) main_menu ;; install) install_action ;; status) status_action ;; show) show_node_action ;;
        change-port) change_port_action ;; change-sni) change_sni_action ;; reset-node) reset_node_action ;;
        check) check_config_action ;; backup) backup_action ;; restore) restore_action ;;
        start|stop|restart) require_root; service_control "$command" ;; logs) service_logs "${2:-100}" ;;
        update) update_action ;; uninstall) uninstall_action ;; -h|--help|help) usage ;; *) usage >&2; exit 2 ;;
    esac
}

main "$@"
