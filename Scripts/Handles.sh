#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE/wrt/package" ]; then
	PKG_PATH="$GITHUB_WORKSPACE/wrt/package"
else
	PKG_PATH="$(pwd)"
fi

#预置HomeProxy数据
HP_DIR="$(find "$PKG_PATH" -maxdepth 1 -type d -name '*homeproxy*' -print -quit)"
if [ -n "$HP_DIR" ]; then
	echo " "

	HP_RESOURCES="$HP_DIR/root/etc/homeproxy/resources"
	HP_DASHBOARD="$HP_DIR/root/etc/homeproxy/dashboard"
	HP_IP_SOURCE="https://cdn.jsdelivr.net/gh/Loyalsoldier/surge-rules@release/cncidr.txt"
	HP_GEOSITE_SOURCE="https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set-unstable/geosite-cn.srs"
	HP_IP_VERSION_URL="https://github.com/Loyalsoldier/surge-rules/releases/latest"
	HP_GEOSITE_VERSION_URL="https://github.com/SagerNet/sing-geosite/releases/latest"
	HP_DASHBOARD_SOURCE="https://codeload.github.com/SagerNet/sing-box-dashboard/zip/refs/heads/gh-pages"
	HP_DASHBOARD_VERSION_URL="https://github.com/SagerNet/sing-box-dashboard/commits/gh-pages.atom"
	HP_USER_AGENT="HomeProxy resource preset"

	HP_PREREQUISITES_MISSING=0
	for HP_COMMAND in curl awk; do
		command -v "$HP_COMMAND" > /dev/null 2>&1 || {
			echo "homeproxy resource preset requires $HP_COMMAND!"
			HP_PREREQUISITES_MISSING=1
		}
	done
	HP_PRESET_FAILED=0
	if [ "${HP_PREREQUISITES_MISSING:-0}" -eq 1 ]; then
		HP_PRESET_FAILED=1
	else
		HP_TMP="$(mktemp -d)"
		if [ -z "$HP_TMP" ]; then
			echo "failed to prepare homeproxy resource preset directory!"
			HP_PRESET_FAILED=1
		fi
	fi
	HP_DASHBOARD_STAGE="${HP_DASHBOARD}.new.$$"
	if [ "$HP_PRESET_FAILED" -eq 0 ]; then
		trap 'rm -rf "$HP_TMP" "$HP_DASHBOARD_STAGE"' EXIT INT TERM
	fi

	hp_fetch_release_version() {
		local effective_url version

		effective_url="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
			--retry-delay 1 \
			--connect-timeout 10 --max-time 30 -A "$HP_USER_AGENT" \
			-o /dev/null -w '%{url_effective}' "$1")" || return 1
		version="${effective_url##*/}"
		case "$version" in
		''|*[!0-9]*) return 1 ;;
		esac
		printf '%s\n' "$version"
	}

	hp_download() {
		curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
			--connect-timeout 10 \
			--max-time 60 -A "$HP_USER_AGENT" -o "$2" "$1" && [ -s "$2" ]
	}

	hp_fetch_dashboard_version() {
		local feed version

		feed="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
			--retry-delay 1 --connect-timeout 10 --max-time 30 \
			-A "$HP_USER_AGENT" "$HP_DASHBOARD_VERSION_URL")" || return 1
		version="$(printf '%s\n' "$feed" | awk -F '[<>]' '
			/<updated>/ {
				version = $3
				gsub(/[-:TZ]/, "", version)
				print version
				exit
			}
		')"
		case "$version" in
		??????????????) case "$version" in *[!0-9]*) return 1 ;; esac ;;
		*) return 1 ;;
		esac
		printf '%s\n' "$version"
	}

	hp_replace_file() {
		local source_file="$1" target_file="$2" temporary_file

		temporary_file="${target_file}.tmp.$$"
		cp "$source_file" "$temporary_file" || return 1
		chmod 0644 "$temporary_file" || return 1
		mv -f "$temporary_file" "$target_file"
	}

	hp_update_ip() {
		local version file

		version="$(hp_fetch_release_version "$HP_IP_VERSION_URL")" || return 1
		hp_download "$HP_IP_SOURCE?v=$version" "$HP_TMP/cncidr.txt" || return 1
		awk -F, -v ipv4="$HP_TMP/china_ip4.txt" -v ipv6="$HP_TMP/china_ip6.txt" '
			$1 == "IP-CIDR" { print $2 > ipv4 }
			$1 == "IP-CIDR6" { print $2 > ipv6 }
		' "$HP_TMP/cncidr.txt" || return 1
		[ -s "$HP_TMP/china_ip4.txt" ] && [ -s "$HP_TMP/china_ip6.txt" ] || return 1
		awk '
			BEGIN {
				print "{\"version\":5,\"rules\":[{\"ip_cidr\":["
				first = 1
			}
			NF {
				printf "%s\"%s\"", first ? "" : ",", $0
				first = 0
			}
			END { print "]}]}" }
		' "$HP_TMP/china_ip4.txt" "$HP_TMP/china_ip6.txt" > "$HP_TMP/geoip_cn.json" || return 1
		[ -s "$HP_TMP/geoip_cn.json" ] || return 1
		printf '%s\n' "$version" > "$HP_TMP/china_ip4.ver"
		printf '%s\n' "$version" > "$HP_TMP/china_ip6.ver"
		for file in china_ip4.txt china_ip4.ver china_ip6.txt china_ip6.ver geoip_cn.json; do
			hp_replace_file "$HP_TMP/$file" "$HP_RESOURCES/$file" || return 1
		done
		echo "homeproxy resources: china_ip $version"
	}

	hp_update_geosite() {
		local version

		version="$(hp_fetch_release_version "$HP_GEOSITE_VERSION_URL")" || return 1
		hp_download "$HP_GEOSITE_SOURCE?v=$version" "$HP_TMP/geosite_cn.srs" || return 1
		printf '%s\n' "$version" > "$HP_TMP/geosite_cn.ver"
		hp_replace_file "$HP_TMP/geosite_cn.srs" "$HP_RESOURCES/geosite_cn.srs" || return 1
		hp_replace_file "$HP_TMP/geosite_cn.ver" "$HP_RESOURCES/geosite_cn.ver" || return 1
		echo "homeproxy resources: geosite_cn $version"
	}

	hp_update_dashboard() {
		local version source_dir old_dir

		command -v unzip > /dev/null 2>&1 || return 1
		command -v find > /dev/null 2>&1 || return 1
		version="$(hp_fetch_dashboard_version)" || return 1
		hp_download "$HP_DASHBOARD_SOURCE?v=$version" "$HP_TMP/dashboard.zip" || return 1
		unzip -q "$HP_TMP/dashboard.zip" -d "$HP_TMP/dashboard" || return 1
		source_dir="$(find "$HP_TMP/dashboard" -mindepth 1 -maxdepth 1 -type d -print -quit)"
		[ -n "$source_dir" ] && [ -f "$source_dir/index.html" ] || return 1

		rm -rf "$HP_DASHBOARD_STAGE"
		mkdir -p "$HP_DASHBOARD_STAGE" &&
			cp -a "$source_dir/." "$HP_DASHBOARD_STAGE/" &&
			printf '%s\n' "$version" > "$HP_DASHBOARD_STAGE/dashboard.ver" || return 1
		rm -f "$HP_DASHBOARD_STAGE/.etag"
		chmod -R a+rX "$HP_DASHBOARD_STAGE" || return 1

		old_dir="${HP_DASHBOARD}.old.$$"
		rm -rf "$old_dir"
		{ [ ! -d "$HP_DASHBOARD" ] || mv "$HP_DASHBOARD" "$old_dir"; } || return 1
		if mv "$HP_DASHBOARD_STAGE" "$HP_DASHBOARD"; then
			rm -rf "$old_dir"
			echo "homeproxy dashboard: $version"
			return 0
		fi
		rm -rf "$HP_DASHBOARD"
		[ ! -d "$old_dir" ] || mv "$old_dir" "$HP_DASHBOARD"
		return 1
	}

	if [ "$HP_PRESET_FAILED" -eq 0 ] && ! mkdir -p "$HP_RESOURCES" "$HP_DASHBOARD"; then
		echo "failed to prepare homeproxy resource directories!"
		HP_PRESET_FAILED=1
	fi

	if [ "$HP_PRESET_FAILED" -eq 0 ]; then
		if ! hp_update_ip; then
			echo "failed to update homeproxy IP resources; continuing!"
			HP_PRESET_FAILED=1
		fi

		if ! hp_update_geosite; then
			echo "failed to update homeproxy geosite; continuing!"
			HP_PRESET_FAILED=1
		fi

		if ! hp_update_dashboard; then
			echo "failed to update homeproxy dashboard; continuing!"
			HP_PRESET_FAILED=1
		fi

		rm -rf "$HP_TMP" "$HP_DASHBOARD_STAGE"
		trap - EXIT INT TERM
	fi

	if [ "$HP_PRESET_FAILED" -eq 0 ]; then
		echo "homeproxy data has been updated!"
	else
		echo "homeproxy resource preset completed with errors; continuing other handlers!"
	fi
fi

#修改argon主题字体和颜色
if [ -d "$PKG_PATH/luci-theme-argon" ]; then
	echo " "
	if sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" \
		"$PKG_PATH/luci-theme-argon/luci-app-argon-config/root/etc/config/argon"; then
		echo "theme-argon has been fixed!"
	else
		echo "theme-argon fix failed; continuing!"
	fi
fi

#修改aurora菜单式样
if [ -d "$PKG_PATH/luci-app-aurora-config" ]; then
	echo " "
	if find "$PKG_PATH/luci-app-aurora-config/root/usr/share/aurora/" -type f -name '*.template' -exec \
		sed -i "s/nav_type '.*'/nav_type 'dropdown'/g; s/struct_radius_base '.*'/struct_radius_base '0.125rem'/g" {} +; then
		echo "theme-aurora has been fixed!"
	else
		echo "theme-aurora fix failed; continuing!"
	fi
fi

#修改mini-diskmanager菜单位置
if [ -d "$PKG_PATH/luci-app-mini-diskmanager" ]; then
	echo " "
	if sed -i "s/services/system/g" \
		"$PKG_PATH/luci-app-mini-diskmanager/luci-app-mini-diskmanager/root/usr/share/luci/menu.d/luci-app-mini-diskmanager.json"; then
		echo "mini-diskmanager has been fixed!"
	else
		echo "mini-diskmanager fix failed; continuing!"
	fi
fi

# 彻底修复 Tailscale：强制首刷自启 & RAX3000M/nftables 兼容
echo "Applying Tailscale FORCE-START fix..."

# 1. 创建所有必备目录
mkdir -p ../files/etc/config
mkdir -p ../files/etc/init.d
mkdir -p ../files/etc/rc.d
mkdir -p ../files/etc/uci-defaults

# 2. 注入 UCI 配置文件 (强制全部设为 1，即默认开启)
cat > ../files/etc/config/tailscale << 'EOF'
config tailscale 'main'
	option enabled '1'
	option port '41641'
	option fw_mode 'nftables'
	option config_path '/etc/tailscale'

config settings
	option service_enabled '1'
	option log_stdout '1'
	option log_stderr '1'
EOF

# 3. 注入强力启动脚本 (解决 sock 丢失和 nftables 报错)
cat > ../files/etc/init.d/tailscale << 'EOF'
#!/bin/sh /etc/rc.common

START=95
USE_PROCD=1
PROGD=/usr/sbin/tailscaled

start_service() {
    config_load tailscale
    local enabled fw_mode port config_path
    
    # 获取配置，即使获取失败也默认给 1 (开启)
    config_get_bool enabled 'main' enabled 1
    config_get fw_mode 'main' fw_mode 'nftables'
    config_get port 'main' port '41641'
    config_get config_path 'main' config_path '/etc/tailscale'

    [ "$enabled" -eq 0 ] && return 0

    # 核心防爆：确保运行时目录绝对存在
    mkdir -p /var/run/tailscale
    mkdir -p "$config_path"

    $PROGD --cleanup
    procd_open_instance
    # 【关键 1】用 `env` 命令在命令行前缀注入环境变量，而不是依赖 procd 的 env。
    # 原因：procd 的 `procd_set_param env` 是「设置整个 env 列表」而非追加
    # （procd.sh 的 _procd_add_table 每次都 json_add_object 一个同名 object，
    #  procd 解析时后者覆盖前者）。曾在同一 instance 内连续调用两次：
    #     procd_set_param env TS_DEBUG_FIREWALL_MODE="$fw_mode"
    #     procd_set_param env TS_NO_LOGS_NO_SUPPORT=true
    # 结果前者被后者整个覆盖，TS_DEBUG_FIREWALL_MODE 丢失 → tailscaled 回落
    # 到默认 iptables 模式；而本固件只有 ip6tables-nft、没有 iptables 命令，
    # 于是启动即崩（procd crash loop）：
    #   wgengine.NewUserspaceEngine(tun "tailscale0") error:
    #     router.Up: setting netfilter mode:
    #     exec: "iptables": executable file not found in $PATH
    # 命令行 env 前缀不受 procd 行为影响，故作为首选方式。
    # 实测确认：手动 TS_DEBUG_FIREWALL_MODE=nftables 启动即得到
    #   router: netfilter running in nftables mode, v6 = true
    procd_set_param command /usr/bin/env \
        TS_DEBUG_FIREWALL_MODE="$fw_mode" \
        TS_NO_LOGS_NO_SUPPORT=true \
        $PROGD \
        --port "$port" \
        --state "$config_path/tailscaled.state" \
        --socket /var/run/tailscale/tailscaled.sock

    # 【关键 2】procd 的 env 也一并设置（双重保险），但必须一次调用传全部变量，
    # 绝不可拆成多次 procd_set_param env（会互相覆盖，见上）。
    procd_set_param env \
        TS_DEBUG_FIREWALL_MODE="$fw_mode" \
        TS_NO_LOGS_NO_SUPPORT=true

    procd_set_param respawn
    procd_close_instance
}

stop_service() {
    $PROGD --cleanup
    rm -rf /var/run/tailscale
}
EOF
chmod +x ../files/etc/init.d/tailscale

# 4. 第一道保险：创建常规自启软链接
ln -sf ../init.d/tailscale ../files/etc/rc.d/S95tailscale

# 5. 第二道保险（终极杀器）：首次开机强制执行脚本
# 该脚本只在刚刷完固件第一次开机时运行一次，运行后系统会自动将其删除
cat > ../files/etc/uci-defaults/99-force-tailscale << 'EOF'
#!/bin/sh
# 强制激活服务并立即启动
/etc/init.d/tailscale enable
/etc/init.d/tailscale start
exit 0
EOF
chmod +x ../files/etc/uci-defaults/99-force-tailscale

# 6. 解决核心包 Makefile 冲突 (清空原生启动脚本，防止覆盖我们的补丁)
TS_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/tailscale/Makefile")
if [ -f "$TS_FILE" ]; then
	sed -i '/\/files/d' $TS_FILE
fi

echo "Tailscale FORCE-START fix applied successfully!"

#修复Rust编译失败
RUST_FILE="$(find "$FEEDS_PACKAGES" -maxdepth 3 -type f -wholename '*/rust/Makefile' -print -quit 2>/dev/null)"
if [ -f "$RUST_FILE" ]; then
	echo " "

	if sed -i 's/ci-llvm=true/ci-llvm=false/g' "$RUST_FILE"; then
		echo "rust has been fixed!"
	else
		echo "rust fix failed; continuing!"
	fi
fi

# =================================================================
# Golang 工具链处理（按源码分支区分，两套源码需求相反！）
# =================================================================
# 24.10-6.6: 原生 golang 版本偏旧，需从 openwrt/packages master 拉新版覆盖。
# 25.12    : **不能替换**。25.12 原生已提供 golang1.26（=Go 1.26.8），
#            而 master 分支的包名是 golang1.27。替换后：
#              1) 25.12 其它包引用的 golang1.26/host 全部失效
#                 （实测 5 处 WARNING: 'golang/host' does not exist）
#              2) apk 体系下重新注册失败
#                 （实测 WARNING: 'golang1.27/host' does not exist）
#              3) 最终回落到宿主机 go 1.25.8 + GOTOOLCHAIN=local
#            实测后果（tailscale 编译失败）：
#              go: go.mod requires go >= 1.26.3
#                  (running go 1.25.8; GOTOOLCHAIN=local)
#            见 CI run 38512637758 的 CPE-25.12 job。
# =================================================================

# 通过 PKG_PATH 推导 feeds 目录的绝对路径
FEEDS_DIR="$(dirname "$PKG_PATH")/feeds"

if [[ "${WRT_BRANCH}" == *"25.12"* ]]; then
	echo "25.12 detected: skipping Golang replacement (native golang1.26 = Go 1.26.8 is sufficient)."
else
	echo "Fetching latest Golang from openwrt/packages master branch..."

	# 确保旧的残留彻底清理干净
	rm -rf "$FEEDS_DIR/packages/lang/golang"
	rm -rf "$(dirname "$PKG_PATH")/tmp/openwrt-packages-go"

	# 浅克隆官方最新的 master 主分支到临时目录
	git clone --depth=1 https://github.com/openwrt/packages.git "$(dirname "$PKG_PATH")/tmp/openwrt-packages-go"

	# 移动新版 golang 到 feeds 目录，并清理临时目录
	if [ -d "$(dirname "$PKG_PATH")/tmp/openwrt-packages-go/lang/golang" ]; then
		mv "$(dirname "$PKG_PATH")/tmp/openwrt-packages-go/lang/golang" "$FEEDS_DIR/packages/lang/golang"
		echo "Golang source code replaced successfully."
	else
		echo "Error: Failed to fetch golang from upstream master!"
	fi
	rm -rf "$(dirname "$PKG_PATH")/tmp/openwrt-packages-go"

	# 重新向系统安装刷新 feeds 关联，确保依赖识别
	"$(dirname "$PKG_PATH")/scripts/feeds" install -a golang

	echo "Golang upgrade patch processed!"
fi

# --- 通用兜底：解除 GOTOOLCHAIN 锁死（GOTOOLCHAIN=local -> auto）---
# golang-package.mk 中 GO_PKG_BUILD_VARS 硬编码 GOTOOLCHAIN=local，
# 使 go 无法自动下载满足 go.mod 要求的 toolchain，只能报错。
# 改为 auto 后，若上游 go.mod 要求高于当前 go，会自动拉取匹配版本。
GOTOOLCHAIN_FILE="$FEEDS_DIR/packages/lang/golang/golang-package.mk"
if [ -f "$GOTOOLCHAIN_FILE" ]; then
	if grep -q 'GOTOOLCHAIN=local' "$GOTOOLCHAIN_FILE"; then
		sed -i 's/GOTOOLCHAIN=local/GOTOOLCHAIN=auto/g' "$GOTOOLCHAIN_FILE"
		echo "GOTOOLCHAIN unlocked (local -> auto) in golang-package.mk"
	else
		echo "GOTOOLCHAIN already auto or not found in golang-package.mk; skip"
	fi
	# 兜底：同目录其它文件若也含该变量一并处理（幂等）
	find "$FEEDS_DIR/packages/lang/golang" -type f -name '*.mk' -exec \
		sed -i 's/GOTOOLCHAIN=local/GOTOOLCHAIN=auto/g' {} + 2>/dev/null || true
else
	echo "warning: $GOTOOLCHAIN_FILE not found; GOTOOLCHAIN not patched"
fi

# 修复广和通 QMI 驱动 (qmi_wwan_f.c) 适配 Linux 6.6 内核
# 1. 自动定位 MTK SDK / OpenWrt 源码根目录
WRT_PATH=""
if [ -d "/mnt/build_wrt/package" ]; then
    WRT_PATH="/mnt/build_wrt"
elif [ -d "package" ]; then
    WRT_PATH="."
elif [ -d "openwrt/package" ]; then
    WRT_PATH="openwrt"
fi

if [ -n "$WRT_PATH" ]; then
    echo "========================================="
    echo "Located OpenWrt Source Root at: $WRT_PATH"
    echo "========================================="
    cd "$WRT_PATH" || exit 1
fi

# 2. 批量修复 5G 模块驱动 (Fibocom / Quectel / SIMCom) 适配 Kernel 6.6 API
if [ -d "package" ]; then
    echo "Patching all QMI WWAN drivers (qmi_wwan*.c) for Kernel 6.6..."
    find package/ -type f -name "qmi_wwan*.c" -exec sed -i 's/u64_stats_fetch_begin_irq/u64_stats_fetch_begin/g' {} + 2>/dev/null || true
    find package/ -type f -name "qmi_wwan*.c" -exec sed -i 's/u64_stats_fetch_retry_irq/u64_stats_fetch_retry/g' {} + 2>/dev/null || true
fi

echo "5G has been fixed!"
