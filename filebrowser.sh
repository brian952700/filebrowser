#!/usr/bin/env bash

set -Eeuo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly NONE='\033[0m'

readonly SERVICE_NAME='filebrowser'
readonly SERVICE_USER='filebrowser'
readonly SERVICE_GROUP='filebrowser'
readonly BINARY_PATH='/usr/local/bin/filebrowser'
readonly SERVICE_PATH='/etc/systemd/system/filebrowser.service'
readonly STATE_DIR='/var/lib/filebrowser'
readonly DATABASE_PATH="${STATE_DIR}/filebrowser.db"
readonly DEFAULT_ROOT_DIR='/srv/filebrowser'
readonly DEFAULT_ADDRESS='0.0.0.0'
readonly DEFAULT_PORT='9184'
readonly DEFAULT_VERSION='v2.63.23'

# These values can be overridden for a custom personal-server installation.
ROOT_DIR="${FILEBROWSER_ROOT:-${DEFAULT_ROOT_DIR}}"
LISTEN_ADDRESS="${FILEBROWSER_ADDRESS:-${DEFAULT_ADDRESS}}"
LISTEN_PORT="${FILEBROWSER_PORT:-${DEFAULT_PORT}}"
FILEBROWSER_VERSION="${FILEBROWSER_VERSION:-${DEFAULT_VERSION}}"

TEMP_DIR=''

log() {
	printf '%b\n' "${GREEN}[filebrowser]${NONE} $*"
}

warn() {
	printf '%b\n' "${YELLOW}[filebrowser] $*${NONE}" >&2
}

die() {
	printf '%b\n' "${RED}[filebrowser] $*${NONE}" >&2
	exit 1
}

cleanup() {
	if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
		rm -rf -- "${TEMP_DIR}"
	fi
}

trap cleanup EXIT

require_root() {
	[[ "${EUID}" -eq 0 ]] || die '请使用 root 用户运行此脚本。'
}

check_debian_13() {
	[[ -r /etc/os-release ]] || die '无法读取 /etc/os-release，不能确认系统版本。'

	# shellcheck disable=SC1091
	source /etc/os-release
	[[ "${ID:-}" == 'debian' ]] || die "此版本仅支持 Debian 13；当前系统为 ${PRETTY_NAME:-unknown}。"
	[[ "${VERSION_ID:-}" == '13' || "${VERSION_ID:-}" == 13.* ]] || \
		die "此版本仅支持 Debian 13；当前系统为 ${PRETTY_NAME:-unknown}。"
	command -v systemctl >/dev/null 2>&1 || die '系统未安装 systemd/systemctl。'
}

validate_settings() {
	[[ "${ROOT_DIR}" == /* ]] || die 'FILEBROWSER_ROOT 必须是绝对路径。'
	[[ "${ROOT_DIR}" != '/' ]] || die '出于安全考虑，FILEBROWSER_ROOT 不能设置为系统根目录 /。'
	[[ "${ROOT_DIR}" =~ ^/[A-Za-z0-9._/-]+$ ]] || \
		die 'FILEBROWSER_ROOT 只能包含英文字母、数字、点、下划线、连字符和斜杠。'
	[[ "${LISTEN_ADDRESS}" =~ ^[A-Za-z0-9._:-]+$ ]] || die 'FILEBROWSER_ADDRESS 包含不安全字符。'
	[[ "${LISTEN_PORT}" =~ ^[0-9]+$ ]] || die 'FILEBROWSER_PORT 必须是数字。'
	((LISTEN_PORT >= 1 && LISTEN_PORT <= 65535)) || die 'FILEBROWSER_PORT 必须在 1 到 65535 之间。'
	[[ "${FILEBROWSER_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
		die 'FILEBROWSER_VERSION 必须使用 vX.Y.Z 格式。'
}

detect_architecture() {
	local deb_arch
	deb_arch="$(dpkg --print-architecture)"

	case "${deb_arch}" in
	amd64)
		printf 'amd64'
		;;
	arm64)
		printf 'arm64'
		;;
	armhf)
		printf 'armv7'
		;;
	riscv64)
		printf 'riscv64'
		;;
	*)
		die "File Browser 没有适用于 Debian 13 ${deb_arch} 的官方二进制文件。"
		;;
	esac
}

install_dependencies() {
	log '安装下载与校验工具……'
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl tar
}

download_and_verify() {
	local arch="$1"
	local version="$2"
	local asset="linux-${arch}-filebrowser.tar.gz"
	local version_number="${version#v}"
	local release_url="https://github.com/filebrowser/filebrowser/releases/download/${version}"
	local archive checksums expected actual

	TEMP_DIR="$(mktemp -d)"
	archive="${TEMP_DIR}/${asset}"
	checksums="${TEMP_DIR}/checksums.txt"

	log "下载 File Browser ${version} (${arch})……"
	curl --fail --silent --show-error --location --output "${archive}" "${release_url}/${asset}"
	curl --fail --silent --show-error --location --output "${checksums}" \
		"${release_url}/filebrowser_${version_number}_checksums.txt"

	expected="$(awk -v filename="${asset}" '$2 == filename { print $1 }' "${checksums}")"
	[[ "${expected}" =~ ^[0-9a-fA-F]{64}$ ]] || die "发布校验文件中找不到 ${asset}。"
	actual="$(sha256sum "${archive}" | awk '{print $1}')"
	[[ "${actual}" == "${expected}" ]] || die '下载文件的 SHA-256 校验失败，已中止安装。'

	mkdir -p "${TEMP_DIR}/extracted"
	tar --extract --gzip --file "${archive}" --directory "${TEMP_DIR}/extracted" filebrowser
	[[ -f "${TEMP_DIR}/extracted/filebrowser" ]] || die '压缩包中没有找到 filebrowser 程序。'
}

create_service_account() {
	if ! getent group "${SERVICE_GROUP}" >/dev/null; then
		groupadd --system "${SERVICE_GROUP}"
	fi

	if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
		useradd --system \
			--gid "${SERVICE_GROUP}" \
			--home-dir "${STATE_DIR}" \
			--shell /usr/sbin/nologin \
			"${SERVICE_USER}"
	fi
}

prepare_directories() {
	install -d -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" -m 0750 "${STATE_DIR}"

	if [[ ! -e "${ROOT_DIR}" ]]; then
		install -d -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" -m 0750 "${ROOT_DIR}"
	else
		[[ -d "${ROOT_DIR}" ]] || die "文件根目录不是目录：${ROOT_DIR}"
		if ! runuser -u "${SERVICE_USER}" -- test -r "${ROOT_DIR}"; then
			die "用户 ${SERVICE_USER} 无法读取 ${ROOT_DIR}，请先调整目录权限。"
		fi
		if ! runuser -u "${SERVICE_USER}" -- test -w "${ROOT_DIR}"; then
			warn "用户 ${SERVICE_USER} 无法写入 ${ROOT_DIR}；网页端将只能浏览和下载文件。"
		fi
	fi

	# Migrate the database created by the old installer without overwriting a newer database.
	if [[ -f /etc/filebrowser/database.db && ! -e "${DATABASE_PATH}" ]]; then
		log '迁移旧版数据库到 /var/lib/filebrowser……'
		cp --preserve=mode,timestamps /etc/filebrowser/database.db "${DATABASE_PATH}"
		chown "${SERVICE_USER}:${SERVICE_GROUP}" "${DATABASE_PATH}"
	fi
}

remove_legacy_service() {
	local legacy_service='/lib/systemd/system/filebrowser.service'
	if [[ -f "${legacy_service}" ]] && grep -q '/usr/bin/filebrowser -c /etc/filebrowser/filebrowser.json' "${legacy_service}"; then
		log '移除旧版 systemd 服务文件和旧二进制文件……'
		rm -f -- "${legacy_service}" /usr/bin/filebrowser
	fi
}

write_service() {
	cat >"${SERVICE_PATH}" <<EOF
[Unit]
Description=File Browser
Documentation=https://github.com/filebrowser/filebrowser
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
UMask=0077
WorkingDirectory=${STATE_DIR}
ExecStart=${BINARY_PATH} --address ${LISTEN_ADDRESS} --port ${LISTEN_PORT} --database ${DATABASE_PATH} --root ${ROOT_DIR}
Restart=on-failure
RestartSec=5s

# Basic hardening for a personal server.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
ReadWritePaths=${STATE_DIR} ${ROOT_DIR}

[Install]
WantedBy=multi-user.target
EOF
	chmod 0644 "${SERVICE_PATH}"
}

show_access_information() {
	local ip
	ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
	[[ -n "${ip}" ]] || ip='<服务器IP>'

	printf '\n%b\n' "${GREEN}File Browser 安装完成。${NONE}"
	printf '访问地址：http://%s:%s/\n' "${ip}" "${LISTEN_PORT}"
	printf '文件目录：%s\n' "${ROOT_DIR}"
	printf '数据库：%s\n' "${DATABASE_PATH}"
	printf '\n首次启动会为 admin 生成随机密码，请立即执行：\n'
	printf '  journalctl -u filebrowser --no-pager | grep -i password\n\n'
	warn '默认使用 HTTP。请只在可信内网访问，公网访问时应配置 HTTPS 反向代理和防火墙。'
}

install_filebrowser() {
	local arch version

	require_root
	check_debian_13
	validate_settings
	install_dependencies

	arch="$(detect_architecture)"
	version="${FILEBROWSER_VERSION}"
	download_and_verify "${arch}" "${version}"

	log '安装程序和 systemd 服务……'
	systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
	create_service_account
	prepare_directories
	install -o root -g root -m 0755 "${TEMP_DIR}/extracted/filebrowser" "${BINARY_PATH}"
	remove_legacy_service
	write_service
	systemctl daemon-reload
	systemctl enable --now "${SERVICE_NAME}.service"

	if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
		journalctl -u "${SERVICE_NAME}.service" -n 30 --no-pager >&2 || true
		die 'File Browser 服务启动失败，请查看上面的日志。'
	fi

	show_access_information
}

uninstall_filebrowser() {
	require_root

	log '停止并移除 File Browser 服务……'
	systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
	rm -f -- "${SERVICE_PATH}" "${BINARY_PATH}"
	systemctl daemon-reload
	systemctl reset-failed "${SERVICE_NAME}.service" >/dev/null 2>&1 || true

	printf '%b\n' "${GREEN}程序已卸载。数据库 ${DATABASE_PATH} 和文件目录 ${ROOT_DIR} 已保留。${NONE}"
}

purge_filebrowser() {
	uninstall_filebrowser

	log '删除 File Browser 数据库和服务账号……'
	rm -rf -- "${STATE_DIR}"
	if id "${SERVICE_USER}" >/dev/null 2>&1; then
		userdel "${SERVICE_USER}"
	fi
	if getent group "${SERVICE_GROUP}" >/dev/null; then
		groupdel "${SERVICE_GROUP}" >/dev/null 2>&1 || true
	fi

	warn "个人文件目录 ${ROOT_DIR} 未删除。"
}

show_help() {
	cat <<'EOF'
用法：
  ./filebrowser.sh install      安装或升级 File Browser
  ./filebrowser.sh uninstall    卸载程序，保留数据库和个人文件
  ./filebrowser.sh purge        卸载并删除数据库，保留个人文件

可选环境变量：
  FILEBROWSER_ROOT       文件根目录，默认 /srv/filebrowser
  FILEBROWSER_ADDRESS    监听地址，默认 0.0.0.0
  FILEBROWSER_PORT       监听端口，默认 9184
  FILEBROWSER_VERSION    上游版本，默认 v2.63.23

示例：
  FILEBROWSER_ROOT=/mnt/storage FILEBROWSER_PORT=8080 ./filebrowser.sh install
EOF
}

interactive_menu() {
	printf '\nFile Browser for Debian 13\n\n'
	printf '  1. 安装或升级\n'
	printf '  2. 卸载（保留数据）\n'
	printf '  3. 彻底卸载数据库（保留个人文件）\n\n'
	read -r -p '请选择 [1-3]：' choice
	case "${choice}" in
	1) install_filebrowser ;;
	2) uninstall_filebrowser ;;
	3) purge_filebrowser ;;
	*) die '输入错误。' ;;
	esac
}

case "${1:-}" in
install)
	install_filebrowser
	;;
uninstall)
	uninstall_filebrowser
	;;
purge)
	purge_filebrowser
	;;
-h | --help | help)
	show_help
	;;
'')
	interactive_menu
	;;
*)
	show_help >&2
	exit 2
	;;
esac
