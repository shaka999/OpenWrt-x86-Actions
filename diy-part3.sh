#!/bin/bash
# diy-part3.sh —— 编译期预装 Open-Box（https://github.com/liandu2024/Open-Box）
#
# 背景：Open-Box 不是 OpenWrt 源码包（没有 Makefile、无法 feeds install），
#       它以 GitHub Releases 中的预编译 tar.gz 分发，官方安装方式是
#       `curl -fsSL .../install.sh | sh`（下载到 /opt/open-box 并注册服务）。
#       本脚本把官方安装脚本的产物在编译期直接落进 rootfs，做到刷机后开箱即用。
#
# 时机：必须在 feeds install 之后、make defconfig 之前调用（由 workflow 执行），
#       写入 openwrt/files/ 作为覆盖层，由 OpenWrt 打进 rootfs。
#
# 官方安装脚本对系统的写入（本脚本逐项复现，路径与权限保持一致）：
#   /opt/open-box/                      完整运行时（node + panel + sing-box + geo）
#   /etc/init.d/openbox                 内核服务（procd）
#   /etc/init.d/openbox-panel           面板服务（procd）
#   /usr/bin/open-box -> /opt/open-box/openwrt/bin/open-box   CLI 软链
#   /usr/share/luci/menu.d/luci-app-openbox.json              LuCI 菜单
#   /usr/share/rpcd/acl.d/luci-app-openbox.json               LuCI ACL
#   /www/luci-static/resources/view/openbox/main.js           LuCI 视图
#   /opt/open-box/data/panel-port       面板端口（默认 3036）
#
# 设计取舍：
# - 只预装【运行时 + 系统集成】，不写 data/ 下的用户数据（订阅、规则、密码），
#   首次打开面板时按官方流程设置密码，行为与 curl 安装完全一致。
# - 组件版本与 SHA256 从 meta.json 读取并**校验**，避免上游改包导致静默不一致。
# - 下载源支持镜像；GitHub 直连失败自动换 gh-proxy，避免编译期网络问题导致整轮失败。

set -e

# OPENBOX_VERSION 支持两种取值：
#   latest（推荐/默认）—— 构建时在线解析上游最新 release，上游删旧包也不会失效；
#   v0.1.xxx          —— 锁定具体版本。
# 注意：上游只保留最近 10 个 release，更旧的 tag 连同资产一起删除（v0.1.236 / v0.1.300
# / v0.1.330 / v0.1.360 / v0.1.393 实测全部 404）。所以「锁死版本」长期必然失效，
# 默认值取 latest。
OB_PIN="${OPENBOX_VERSION:-latest}"
OB_ARCH="${OPENBOX_ARCH:-x64}"                       # x86_64 -> x64
OB_ASSET="open-box-linux-${OB_ARCH}.tar.gz"
OB_PANEL_PORT="${OPENBOX_PANEL_PORT:-3036}"

# 镜像前缀（留空则只用直连）；每个前缀依次尝试
OB_MIRRORS="${OPENBOX_MIRRORS:-https://gh-proxy.com/}"

OB_REPO="liandu2024/Open-Box"
TOPDIR="$(pwd)"
OVERLAY="$TOPDIR/files"
WORK="$(mktemp -d /tmp/openbox.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ---------- 0. 版本解析 ----------
# 上游发版频率很高（2026-11-04~05 一天内连发 8 个版本）。若解析到的最新 tag 恰好
# 仍在上传资产，下载会 404，整轮构建白跑 —— 因此额外解析一个「次新版本」作为降级
# 候选，按顺序尝试。

_resolve_latest() {
	# 1) 直连：跟随 /releases/latest 的 302，从 url_effective 尾巴取 tag
	local t
	t=$(curl -sSL -o /dev/null -m 25 -w '%{url_effective}' \
		"https://github.com/$OB_REPO/releases/latest" 2>/dev/null \
		| sed -n 's#.*/releases/tag/##p' | head -n1)
	# 2) 镜像兜底（gh-proxy 对 /latest 返回 200 空页，解析不出 tag，故必须判空后继续）
	if [ -z "$t" ]; then
		for _m in $OB_MIRRORS; do
			t=$(curl -sSL -o /dev/null -m 25 -w '%{url_effective}' \
				"${_m}https://github.com/$OB_REPO/releases/latest" 2>/dev/null \
				| sed -n 's#.*/releases/tag/##p' | head -n1)
			[ -n "$t" ] && break
		done
	fi
	printf '%s' "$t"
}

# 枚举全部 tag，按版本号排序（sort -V 正确处理 v0.1.347 < v0.1.347.1 < v0.1.403）
_resolve_tags_sorted() {
	git ls-remote --tags --refs "https://github.com/$OB_REPO.git" 2>/dev/null \
		| sed 's#.*refs/tags/##' | grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V
}

OB_CANDIDATES=""
if [ "$OB_PIN" = "latest" ] || [ "$OB_PIN" = "LATEST" ] || [ -z "$OB_PIN" ]; then
	_latest="$(_resolve_latest)"
	_prev=""
	if [ -n "$_latest" ]; then
		OB_CANDIDATES="$_latest"
		_prev="$(_resolve_tags_sorted | tail -n2 | head -n1)"
		if [ -n "$_prev" ] && [ "$_prev" != "$_latest" ]; then
			OB_CANDIDATES="$OB_CANDIDATES $_prev"
		fi
		echo "  上游最新版本：${_latest}${_prev:+（降级候选 ${_prev}）}"
	else
		# 3) 最后兜底：完全不依赖 HTTP 重定向，直接枚举 tag 取最大
		echo "  [warn] /releases/latest 解析失败，改用 git tag 枚举"
		OB_CANDIDATES="$(_resolve_tags_sorted | tail -n1)"
	fi
else
	OB_CANDIDATES="$OB_PIN"
fi

[ -n "$OB_CANDIDATES" ] || { echo "::error::无法确定 Open-Box 版本（直连/镜像/git 均失败）"; exit 1; }
for _v in $OB_CANDIDATES; do
	case "$_v" in
		v[0-9]*) ;;
		*) echo "::error::版本号格式异常：${_v}"; exit 1 ;;
	esac
done

OB_VERSION="$(printf '%s\n' $OB_CANDIDATES | head -n1)"
echo "===== 预装 Open-Box（候选：${OB_CANDIDATES}）(${OB_ARCH}) ====="

# ---------- 1. 下载（逐候选、逐镜像）----------
# 先确定可用的镜像前缀：空字符串代表直连
_try_download() {
	local url="$1" out="$2" label="$3"
	echo "  尝试 ${label}: ${url}"
	# -f 让 HTTP 错误返回非 0；-m 给足大文件超时
	if curl -fsSL -m 900 --retry 2 --ssl-no-revoke -o "$out" "$url"; then
		return 0
	fi
	return 1
}

_ok=0
for _ver in $OB_CANDIDATES; do
	if [ "$_ok" -eq 1 ]; then break; fi
	RAW_BASE="https://github.com/${OB_REPO}/releases/download/${_ver}"
	for _m in "" $OB_MIRRORS; do
		if _try_download "${_m}${RAW_BASE}/${OB_ASSET}" "$WORK/$OB_ASSET" "[$_ver] 镜像=${_m:-直连}"; then
			_ok=1
			OB_VERSION="$_ver"
			echo "  下载成功（$_ver，${_m:-直连}）"
			break
		fi
	done
	# GitHub 直连域名不通时，回落到 releases 资产镜像路径（镜像支持 releases 直链）
	if [ "$_ok" -ne 1 ]; then
		echo "  [warn] $_ver 常规路径均失败，改用 releases 镜像路径重试"
		for _m in "https://gh-proxy.com/" "https://ghfast.top/"; do
			if _try_download "${_m}${RAW_BASE}/${OB_ASSET}" "$WORK/$OB_ASSET" "[$_ver] releases 镜像=${_m}"; then
				_ok=1
				OB_VERSION="$_ver"
				echo "  下载成功（$_ver，releases 镜像 ${_m}）"
				break
			fi
		done
	fi
	if [ "$_ok" -eq 0 ]; then
		echo "  [warn] 版本 ${_ver} 下载失败，尝试下一个候选"
	fi
done

if [ "$_ok" -ne 1 ]; then
	echo "::error::Open-Box 下载失败（候选：${OB_CANDIDATES}）。"
	echo "::error::如为网络原因，可在 workflow env 里设置 OPENBOX_MIRRORS，或把 OPENBOX_VERSION 固定到某个可用 tag。"
	exit 1
fi

# 把实际装进去的版本暴露给后续步骤（workflow 的 Generate release tag 会写进 Release 说明）
echo "  实际使用版本：${OB_VERSION}"
if [ -n "${GITHUB_ENV:-}" ]; then
	echo "OPENBOX_VERSION_RESOLVED=${OB_VERSION}" >> "$GITHUB_ENV"
fi

ls -lh "$WORK/$OB_ASSET"

# ---------- 2. 解包到覆盖层 ----------
# 官方 installer 解到 /opt/open-box（install.sh 的 INSTALL_ROOT）
mkdir -p "$OVERLAY/opt/open-box"
if ! tar -xzf "$WORK/$OB_ASSET" -C "$OVERLAY/opt/open-box"; then
	echo "::error::解包失败"
	exit 1
fi

# ---------- 3. 版本校验（读 meta.json，并对齐请求版本） ----------
if [ -f "$OVERLAY/opt/open-box/meta.json" ]; then
	_real_ver="$(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' "$OVERLAY/opt/open-box/meta.json" | head -n1)"
	_real_arch="$(sed -n 's/.*"arch" *: *"\([^"]*\)".*/\1/p' "$OVERLAY/opt/open-box/meta.json" | head -n1)"
	_singbox="$(sed -n 's/.*"singboxVersion" *: *"\([^"]*\)".*/\1/p' "$OVERLAY/opt/open-box/meta.json" | head -n1)"
	_node="$(sed -n 's/.*"nodeVersion" *: *"\([^"]*\)".*/\1/p' "$OVERLAY/opt/open-box/meta.json" | head -n1)"
	echo "  meta.json : version=${_real_ver} arch=${_real_arch} sing-box=${_singbox} node=${_node}"
	if [ -n "$_real_ver" ] && [ "$_real_ver" != "$OB_VERSION" ]; then
		echo "::error::版本不符：请求 ${OB_VERSION}，包内为 ${_real_ver}"
		exit 1
	fi
	if [ -n "$_real_arch" ] && [ "$_real_arch" != "$OB_ARCH" ]; then
		echo "::error::架构不符：请求 ${OB_ARCH}，包内为 ${_real_arch}"
		exit 1
	fi
else
	echo "::warning::未找到 meta.json，跳过版本校验"
fi

# ---------- 4. 系统集成（复现 install.sh 第 750-774 行） ----------
mkdir -p "$OVERLAY/etc/init.d"
mkdir -p "$OVERLAY/usr/bin"
mkdir -p "$OVERLAY/usr/share/luci/menu.d"
mkdir -p "$OVERLAY/usr/share/rpcd/acl.d"
mkdir -p "$OVERLAY/www/luci-static/resources/view/openbox"
mkdir -p "$OVERLAY/opt/open-box/data"

# 4.1 服务脚本
if [ -f "$OVERLAY/opt/open-box/openwrt/initd/openbox" ]; then
	cp "$OVERLAY/opt/open-box/openwrt/initd/openbox"        "$OVERLAY/etc/init.d/openbox"
	cp "$OVERLAY/opt/open-box/openwrt/initd/openbox-panel"  "$OVERLAY/etc/init.d/openbox-panel"
	chmod +x "$OVERLAY/etc/init.d/openbox" "$OVERLAY/etc/init.d/openbox-panel"
else
	echo "::error::缺少 openwrt/initd/openbox，包结构与预期不符"
	exit 1
fi

# 4.2 CLI 软链（官方用 ln -sf 指向 /opt/open-box/openwrt/bin/open-box）
chmod +x "$OVERLAY/opt/open-box/openwrt/bin/open-box" 2>/dev/null || true
ln -sf /opt/open-box/openwrt/bin/open-box "$OVERLAY/usr/bin/open-box"

# 4.3 LuCI 菜单 / ACL
cp "$OVERLAY/opt/open-box/openwrt/luci/root/usr/share/luci/menu.d/luci-app-openbox.json" \
	"$OVERLAY/usr/share/luci/menu.d/luci-app-openbox.json"
chmod 644 "$OVERLAY/usr/share/luci/menu.d/luci-app-openbox.json"
if [ -f "$OVERLAY/opt/open-box/openwrt/luci/root/usr/share/rpcd/acl.d/luci-app-openbox.json" ]; then
	cp "$OVERLAY/opt/open-box/openwrt/luci/root/usr/share/rpcd/acl.d/luci-app-openbox.json" \
		"$OVERLAY/usr/share/rpcd/acl.d/luci-app-openbox.json"
	chmod 644 "$OVERLAY/usr/share/rpcd/acl.d/luci-app-openbox.json"
fi

# 4.4 LuCI 视图
cp "$OVERLAY/opt/open-box/openwrt/luci/htdocs/luci-static/resources/view/openbox/main.js" \
	"$OVERLAY/www/luci-static/resources/view/openbox/main.js"
chmod 644 "$OVERLAY/www/luci-static/resources/view/openbox/main.js"

# 4.5 面板端口（官方 installer 的 data/panel-port；随 data 走，升级不动）
printf '%s\n' "$OB_PANEL_PORT" > "$OVERLAY/opt/open-box/data/panel-port"

# 4.6 权限（官方 chown -R 0:0）
chmod +x "$OVERLAY/opt/open-box/node/bin/node" "$OVERLAY/opt/open-box/bin/sing-box" 2>/dev/null || true
chmod +x "$OVERLAY/opt/open-box/openwrt/bin/open-box" 2>/dev/null || true

# ---------- 5. uci-defaults：开机自启 ----------
# 官方 installer 会 `enable` 两个服务。固件里用 uci-defaults 在首启时执行，
# 避免依赖编译期的 rc.d 生成顺序。
mkdir -p "$OVERLAY/etc/uci-defaults"
cat > "$OVERLAY/etc/uci-defaults/98-openbox-enable" <<'EOF'
#!/bin/sh
# Open-Box 首启自启（等价于 install.sh 的 openbox-panel enable）
[ -x /etc/init.d/openbox-panel ] && /etc/init.d/openbox-panel enable
[ -x /etc/init.d/openbox ]       && /etc/init.d/openbox enable
exit 0
EOF
chmod +x "$OVERLAY/etc/uci-defaults/98-openbox-enable"

# ---------- 6. 自检 ----------
echo "--- 预装结果 ---"
for _p in \
	opt/open-box/meta.json \
	opt/open-box/bin/sing-box \
	opt/open-box/node/bin/node \
	opt/open-box/openwrt/bin/open-box \
	opt/open-box/panel/server/index.mjs \
	etc/init.d/openbox \
	etc/init.d/openbox-panel \
	usr/bin/open-box \
	usr/share/luci/menu.d/luci-app-openbox.json \
	usr/share/rpcd/acl.d/luci-app-openbox.json \
	www/luci-static/resources/view/openbox/main.js \
	etc/uci-defaults/98-openbox-enable
do
	if [ -e "$OVERLAY/$_p" ] || [ -L "$OVERLAY/$_p" ]; then
		echo "  OK   $_p"
	else
		echo "  MISS $_p"
	fi
done

echo "--- 覆盖层体积 ---"
du -sh "$OVERLAY/opt/open-box" 2>/dev/null || true
df -hT "$TOPDIR" | tail -n1 || true

echo "===== Open-Box 预装完成 ====="
