#!/bin/bash
# diy-part2.sh —— 在 feeds install 之后、make defconfig 之前执行

# --- dockerd 构建修复 ---
# moby 的 hack/make/binary-daemon 会从构建机 PATH 复制"嵌套可执行文件"
# (containerd/runc/docker-init/rootlesskit 等) 到构建产物 bundle。
# GitHub Actions 的 ubuntu 镜像偶尔缺少其中某些工具，导致
# `cp: cannot stat ''` 而使 dockerd 编译失败。
# 这些工具仅用于构建期 bundle 完整性，不会装进固件，用空 stub 补上即可。
for _tool in containerd containerd-shim-runc-v2 ctr runc docker-init rootlesskit dockerd-rootless.sh dockerd-rootless-setuptool.sh; do
	if ! command -v "$_tool" >/dev/null 2>&1; then
		printf '#!/bin/sh\nexit 0\n' | sudo tee "/usr/local/bin/$_tool" >/dev/null
		sudo chmod +x "/usr/local/bin/$_tool"
	fi
done

# --- argon 主题：改用 ImmortalWrt 自带的 luci-theme-argon ---
# 主题本体（字体 / 图片 / 图标等静态资源）由 feeds（immortalwrt/luci 的 luci-theme-argon）提供，
# files/ 覆盖层只保留个性化文件：cascade.css、dark.css、5 个 ucode 模板、
# wallpaper rpcd 插件、5 个独有图标 —— 共 15 个。
# 依据：被移除的 24 个 files/ 文件与自带版本逐字节相同（menu-argon.js 仅注释差异，功能等价），
#       重复提供只会造成"自带包 + 覆盖层"两套资源版本漂移。
# 历史：此处原先 sed 摘除 luci-app-argon-config 的 +luci-theme-argon 依赖，
#       以避免 feed 主题静态资源与覆盖层不一致；现已确认两者一致，该 hack 移除。

# --- 中文翻译修补（必须在 feeds install 之后）---
# 时机：feeds install 之后 feeds/<feed>/.../<app> 才存在，且被 package/feeds/<feed>/<app>
#       软链引用；改源目录即对构建生效（diy-part1.sh 跑在 feeds update 之前，那时还不存在）。
#
# ★ 两种包、两种机制，处理方式相反 —— 这是上一轮踩过坑的地方：
#
#   (A) 走 luci.mk 的包（绝大多数）：
#       luci.mk 第 10 行   LUCI_LANGUAGES = $(notdir $(wildcard po/*))
#       luci.mk 第 358 行  仅当 LUCI_LANG.<目录名> 有定义才生成 i18n 包
#       而 LUCI_LANG 语言表里只有 zh_Hans / zh_Hant，**没有 zh-cn**。
#       → po 目录名叫 zh-cn 的包会被整条跳过，luci-i18n-xxx-zh-cn 根本不生成。
#       → 修法：把 po/zh-cn 改名成 po/zh_Hans。
#         （包名仍带 zh-cn —— luci.mk 用别名 LUCI_LC_ALIAS.zh_Hans=zh-cn 转换，
#           所以 .config 里的 luci-i18n-xxx-zh-cn 正好对得上。）
#
#   (B) 自带翻译逻辑的包：luci-app-openclash
#       它 **不 include luci.mk**（只有 rules.mk + package.mk），Makefile 里自己写：
#           Build/Prepare:  $(foreach po,$(wildcard ${CURDIR}/po/zh-cn/*.po), po2lmo ...)
#           install:        $(INSTALL_DATA) $(PKG_BUILD_DIR)/*.*.lmo $(1)/usr/lib/lua/luci/i18n/
#       即：语言目录名 zh-cn 是**硬编码**的，lmo 直接编进**主包**。
#       → 中文一直在主包里正常工作，**不存在** luci-i18n-openclash-zh-cn 这个包。
#       → ★ 绝对不能改它的 po 目录名：wildcard 会落空、lmo 不生成，
#         紧接着 install 的 `*.*.lmo` 找不到文件而报
#         `install: cannot stat ... No such file or directory`，
#         整个构建在 luci-app-openclash 处中断（2026-09-16 那次构建就是这么失败的）。
#
# 定位包的路径（feeds/ 与 package/ 都搜，兼容「feed 根即包 / applications/ 子目录 / luci-app-x/ 子目录」三种布局）
_find_app() {
	find feeds package -maxdepth 4 -type d -name "$1" 2>/dev/null | head -n1
}

# ① luci-app-onliner —— 属于 (A) 类，仓库里 po 目录是旧式 zh-cn，改名为 zh_Hans
_onliner="$(_find_app luci-app-onliner)"
if [ -n "$_onliner" ]; then
	_po="$_onliner/po"
	if [ -d "$_po/zh-cn" ] && [ ! -d "$_po/zh_Hans" ]; then
		mkdir -p "$_po/zh_Hans"
		mv "$_po/zh-cn"/*.po "$_po/zh_Hans"/ 2>/dev/null
		rmdir "$_po/zh-cn" 2>/dev/null
	fi
fi

# ② luci-app-adguardhome —— 属于 (A) 类，但 po 里只有 lo（老挝语）和空模板，
#    模板 28 条 msgid 一条中文都没有，只能注入自译译本。
#    文件名必须是 adguardhome.po（小写、与 domain 同名）：luci.mk 用
#    `$(basename $(notdir $(po))).$(lang).lmo` 命名产物，前端按 domain 加载，
#    大小写不一致会静默加载不到。
_agh="$(_find_app luci-app-adguardhome)"
if [ -n "$_agh" ]; then
	mkdir -p "$_agh/po/zh_Hans"
	cat > "$_agh/po/zh_Hans/adguardhome.po" <<'AGH_PO_EOF'
msgid ""
msgstr ""
"Project-Id-Version: adguardhome\n"
"Content-Type: text/plain; charset=UTF-8\n"
"Language: zh_Hans\n"
"Plural-Forms: nplurals=1; plural=0;\n"

msgid "AdGuard Home"
msgstr "AdGuard Home"

msgid "Advanced Settings"
msgstr "高级设置"

msgid "Configuration file"
msgstr "配置文件"

msgid "Directory where filters, logs, and statistics are stored."
msgstr "存储过滤器、日志与统计数据的目录。"

msgid "Enable"
msgstr "启用"

msgid "File System Access"
msgstr "文件系统访问"

msgid "General Settings"
msgstr "常规设置"

msgid "Grant permissions for the AdGuard Home LuCI app"
msgstr "为 AdGuard Home 的 LuCI 界面授予权限"

msgid "Group the service runs under."
msgstr "服务运行的用户组。"

msgid "If empty, defaults to"
msgstr "若留空，则默认为"

msgid "Modify at your own risk."
msgstr "修改风险自负。"

msgid "Not running"
msgstr "未运行"

msgid "Parent directory will be owned by the service user."
msgstr "父目录将由服务用户拥有。"

msgid "Path must be absolute."
msgstr "路径必须为绝对路径。"

msgid "Path must not end with a slash."
msgstr "路径不能以斜杠结尾。"

msgid "Read-only access"
msgstr "只读访问"

msgid "Read-write access"
msgstr "读写访问"

msgid "Running"
msgstr "运行中"

msgid "Service Status"
msgstr "服务状态"

msgid "Service group"
msgstr "服务用户组"

msgid "Service user"
msgstr "服务用户"

msgid "User the service runs under."
msgstr "服务运行的用户。"

msgid "Verbose logging"
msgstr "详细日志"

msgid "Version"
msgstr "版本"

msgid "Will be owned by the service user."
msgstr "将由服务用户拥有。"

msgid "Working directory"
msgstr "工作目录"

msgid "unset"
msgstr "未设置"

msgid "unset and 100"
msgstr "未设置（默认 100）"

msgid "unset and matching the number of CPUs"
msgstr "未设置（默认与 CPU 核心数一致）"

msgid "Configuration file must be stored in its own directory, and not in '/etc'."
msgstr "配置文件必须存放在其独立目录中，不能位于 `/etc`。"

msgid "Files and directories that AdGuard Home should have read-only or read-write access to."
msgstr "AdGuard Home 应具有只读或读写访问权限的文件与目录。"

msgid "Go environment variables that tune garbage collector and memory management."
msgstr "用于调优垃圾回收器与内存管理的 Go 环境变量。"
AGH_PO_EOF
fi

# --- 自检：构建日志里直接可见中文就位情况 ---
# 注：luci-app-openclash 已从 .config 移除，此时 find 不到属正常，输出 SKIP 而非 WARN。
#     若日后重新启用 openclash，这段自检会自动恢复为 OK/FAIL 判定。
_oc="$(_find_app luci-app-openclash)"
if [ -n "$_oc" ] && [ -d "$_oc/po/zh-cn" ]; then
	echo "[zh] OK   luci-app-openclash po/zh-cn 保持原样（自带 po2lmo，中文编在主包里）"
elif [ -n "$_oc" ]; then
	echo "[zh] FAIL luci-app-openclash 的 po/zh-cn 不见了 —— 改名会让主包 install 的 *.*.lmo 落空！"
else
	echo "[zh] SKIP luci-app-openclash 未启用（已从 .config 移除），无需处理"
fi
echo "[zh] $( [ -d "$_onliner/po/zh_Hans" ] && echo 'OK  ' || echo 'WARN') luci-app-onliner po/zh_Hans"
# luci-app-adguardhome 已重新启用（.config 里三行已取消注释）。
# _agh 由上面第 73 行统一 find，这里只做自检。
if [ -n "$_agh" ]; then
	echo "[zh] $( [ -f "$_agh/po/zh_Hans/adguardhome.po" ] && echo 'OK  ' || echo 'FAIL') luci-app-adguardhome po/zh_Hans/adguardhome.po"
else
	echo "[zh] SKIP luci-app-adguardhome 未找到（feeds install 是否成功？）"
fi

# ---------- AdGuard Home 接入配置自检 ----------
# 出厂配置由本仓库 files/ 覆盖层提供：
#   files/etc/adguardhome/adguardhome.yaml   DNS 监听 5353，上游 127.0.0.1:7853
#   files/etc/config/adguardhome             enabled=1
#   files/etc/uci-defaults/97-adguardhome-chain  把 dnsmasq 上游改到 5353
# 这里只做校验，确认三份文件都被正确打包进覆盖层。
if [ -f files/etc/adguardhome/adguardhome.yaml ]; then
	if grep -qE '^\s+port: 5353$' files/etc/adguardhome/adguardhome.yaml; then
		echo "[agh] OK   adguardhome.yaml dns.port=5353"
	else
		echo "[agh] FAIL adguardhome.yaml 的 dns.port 不是 5353 —— 会与 dnsmasq 抢 53"
	fi
	if grep -qE '^\s+- 127\.0\.0\.1:7853$' files/etc/adguardhome/adguardhome.yaml; then
		echo "[agh] OK   upstream_dns=127.0.0.1:7853（指向 Open-Box / sing-box）"
	else
		echo "[agh] WARN upstream_dns 未指向 sing-box 的 7853，请人工确认"
	fi
	# 用 -F 固定字符串：bcrypt 哈希形如 $2b$10$...，正则里 $ 是行尾锚点，会漏判
	if grep -qF 'password: $2b$' files/etc/adguardhome/adguardhome.yaml; then
		echo "[agh] OK   admin 密码已预置为 bcrypt 哈希"
	else
		echo "[agh] WARN admin 密码不是 bcrypt 哈希，首次登录会走安装向导"
	fi
else
	echo "[agh] FAIL 缺少 files/etc/adguardhome/adguardhome.yaml"
fi

if [ -f files/etc/config/adguardhome ] && grep -q "option enabled '1'" files/etc/config/adguardhome; then
	echo "[agh] OK   /etc/config/adguardhome enabled=1"
else
	echo "[agh] FAIL /etc/config/adguardhome 未启用或无文件"
fi

if [ -x files/etc/uci-defaults/97-adguardhome-chain ]; then
	echo "[agh] OK   uci-defaults/97-adguardhome-chain 可执行"
else
	echo "[agh] FAIL uci-defaults/97-adguardhome-chain 缺失或不可执行"
fi

# 覆盖层里的可执行文件必须带 x 位：git 的 core.fileMode 在 Windows 上不生效，
# 靠这里统一补。（uci-defaults 由 boot 用 `.` source，严格说不需要 x，
# 但 99-set-zh-lang 同样补过，保持一致便于人工排查。）
chmod +x files/etc/uci-defaults/97-adguardhome-chain 2>/dev/null || true
chmod +x files/etc/uci-defaults/99-set-zh-lang 2>/dev/null || true

chmod +x files/usr/libexec/rpcd/luci.argon_wallpaper 2>/dev/null || true
