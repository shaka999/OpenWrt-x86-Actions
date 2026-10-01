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

OB_VERSION="${OPENBOX_VERSION:-v0.1.236}"
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

echo "===== 预装 Open-Box ${OB_VERSION} (${OB_ARCH}) ====="

# ---------- 1. 下载 ----------
RAW_BASE="https://github.com/${OB_REPO}/releases/download/${OB_VERSION}"
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
for _m in "" $OB_MIRRORS; do
	if _try_download "${_m}${RAW_BASE}/${OB_ASSET}" "$WORK/$OB_ASSET" "镜像=${_m:-直连}"; then
		_ok=1
		echo "  下载成功（${_m:-直连}）"
		break
	fi
done
# GitHub 直连域名不通时，回落到 releases 资产镜像路径（gh-proxy 支持 releases 直链）
if [ "$_ok" -ne 1 ]; then
	echo "  [warn] 常规路径均失败，改用 releases 镜像路径重试"
	for _m in "https://gh-proxy.com/" "https://ghfast.top/"; do
		if curl -fsSL -m 900 --retry 2 --ssl-no-revoke \
			-o "$WORK/$OB_ASSET" "${_m}https://github.com/${OB_REPO}/releases/download/${OB_VERSION}/${OB_ASSET}"; then
			_ok=1
			echo "  下载成功（releases 镜像 ${_m}）"
			break
		fi
	done
fi

if [ "$_ok" -ne 1 ]; then
	echo "::error::Open-Box 下载失败（版本 ${OB_VERSION}）。"
	echo "::error::如为网络原因，可在 workflow env 里设置 OPENBOX_MIRRORS 或 OPENBOX_VERSION。"
	exit 1
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
