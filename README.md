# OpenWrt x86_64 云编译（ImmortalWrt + Open-Box）

使用 GitHub Actions 在线编译 **ImmortalWrt x86_64** 固件。全部个性化定制集中在本仓库，
并集成 [Open-Box](https://github.com/liandu2024/Open-Box)（一体化透明代理）。

> 本仓库由私有库 `OpenWrt-Actions` 迁移而来，配置与定制**逐字节一致**（已做 git blob SHA 校验）。

---

## 快速开始

1. 进入 **Actions** → 左侧选择 **OpenWrt-x86 Builder** → **Run workflow**
2. 分支选 `main`，点击运行
3. 约 **2 小时**后，到 **Releases** 下载固件

产物为 x86_64 generic 系列：

| 文件 | 说明 |
|---|---|
| `...-squashfs-combined-efi.img.gz` | **推荐**，UEFI 启动 + 只读根 + 可写 overlay |
| `...-squashfs-combined.img.gz` | BIOS 启动版本 |
| `...-ext4-combined-efi.img.gz` | ext4 根分区版本 |
| `...-rootfs.tar.gz` | 仅根文件系统（容器 / LXC 用） |
| `...-kernel.bin` | 内核 |
| `.manifest` | 完整包清单 |

刷机后：

- **LuCI**：`http://<路由器IP>` — 默认简体中文、argon 主题
- **Open-Box 面板**：`http://<路由器IP>:3036` — 首次访问设置面板密码

---

## 定制内容

### 上游与 feeds

| 项 | 值 |
|---|---|
| 源码 | `immortalwrt/immortalwrt` @ `v25.12.2`（tag 锁定） |
| feeds | `packages` / `luci` / `routing` 按 **commit 锁定**（与 ImmortalWrt 官方发版配法一致） |
| 第三方 feed | `lucky`、`istore`、`bandix` + `bandixcore`、`partexp`（见 `diy-part1.sh`） |
| 额外引入 | `luci-app-onliner`（xuanranran fork，含中文） |

### Open-Box（编译期预装）

[Open-Box](https://github.com/liandu2024/Open-Box) 是 OpenWrt 上的一体化透明代理方案，
自带 sing-box 内核、Node 运行时与完整 GeoSite / GeoIP 数据。

**它没有 Makefile，无法用 `feeds install` + `CONFIG_PACKAGE_xxx=y` 集成** ——
官方以 GitHub Releases 的预编译 tar.gz 分发（x64 完整包约 76 MB，解压后约 194 MB）。

`diy-part3.sh` 把官方 installer 的产物在**编译期**直接落进 `openwrt/files/` 覆盖层：

```
/opt/open-box/                       完整运行时（sing-box + node + panel + geo）
/etc/init.d/openbox                  sing-box 内核服务（procd，START=99）
/etc/init.d/openbox-panel            面板服务（procd，START=98）
/usr/bin/open-box -> /opt/open-box/openwrt/bin/open-box
/usr/share/luci/menu.d/luci-app-openbox.json
/usr/share/rpcd/acl.d/luci-app-openbox.json
/www/luci-static/resources/view/openbox/main.js
/etc/uci-defaults/98-openbox-enable  首启自启（等价官方 installer 的 enable）
/opt/open-box/data/panel-port        面板端口（3036）
```

设计要点：

- 只预装**运行时与系统集成**，不写 `data/` 下的用户数据（订阅 / 规则 / 密码），
  首次打开面板时按官方流程设置密码，行为与 `curl | sh` 安装一致。
- 下载支持**镜像回落**（GitHub 直连失败自动换 gh-proxy / ghfast）。
- 读取包内 `meta.json` **校验 version 与 arch**，防止上游改包导致静默不一致。
- 版本通过 workflow 的 `OPENBOX_VERSION` 控制（当前 `v0.1.236`）。

启动顺序经刻意设计：`S98openbox-panel` → `S99openbox`，让内核**等网络完全就绪后再启动**。

### 已选插件（`.config`，**207** 个包）

| 类别 | 内容 |
|---|---|
| 代理 / 网络 | `luci-app-lucky`、`luci-app-upnp`、`miniupnpd-nftables` |
| 容器 | `docker` + `dockerd` + `docker-compose` + `luci-app-dockerman` |
| 存储 | `luci-app-diskman`、`parted`、`resize2fs`、`btrfs-progs`、`f2fs-tools`、`exfat-*` |
| 文件管理 | `luci-app-filemanager`、`nano`、`vim` |
| 工具 | `luci-app-vlmcsd`、`luci-app-timewol`、`luci-app-autoreboot`、`luci-app-partexp`、`luci-app-bandix-plus`、`luci-app-onliner`、`luci-app-store` |
| 主题 | `luci-theme-argon` + `luci-app-argon-config` |
| 中文 | 全套 `luci-i18n-*-zh-cn`，`CONFIG_LUCI_LANG_zh_Hans=y` |
| 内核 | BBR、fullcone、tproxy、ipvs、`kmod-nft-*`、`kmod-ipt-*` 等 |
| Open-Box 依赖 | `kmod-tun`、`kmod-nft-queue`、`kmod-nft-nat`、`kmod-veth`、`ip-full`、`ca-bundle`（**显式声明**，避免依赖变动导致刷机后起不来） |

**已移除的插件**（原配置项以注释保留，取消注释即可恢复）：

- `luci-app-openclash`（及自动带入的 `ruby` / `ruby-yaml` / `unzip` / `ca-bundle`）
- `adguardhome` + `luci-app-adguardhome` + `luci-i18n-adguardhome-zh-cn`

### argon 主题覆盖层（`files/`，16 个文件）

```
files/etc/config/network                                    676 B
files/etc/uci-defaults/99-set-zh-lang                       150 B   默认中文界面
files/usr/libexec/rpcd/luci.argon_wallpaper                3942 B   壁纸 rpcd 插件
files/usr/share/ucode/luci/template/themes/argon/*.ut   5 个模板
files/www/luci-static/argon/css/cascade.css              101551 B   定制样式
files/www/luci-static/argon/css/dark.css                  23553 B
files/www/luci-static/argon/icon/*.png/xml               5 个图标
```

> 主题本体（字体 / 图片 / 图标等静态资源）由 feeds 的 `luci-theme-argon` 提供，
> 覆盖层只保留个性化文件 —— 已确认被移除的 24 个文件与自带版本逐字节相同。

### `diy-part2.sh` 里的两处关键修补

**① dockerd 构建修复**

moby 的 `hack/make/binary-daemon` 会从构建机 PATH 复制嵌套可执行文件
（containerd / runc / docker-init / rootlesskit 等）到 bundle，GitHub 镜像偶尔缺失，
导致 `cp: cannot stat ''` 编译失败。脚本用空 stub 补齐这 8 个工具。

**② 中文翻译修补 —— 两类包，处理方式相反**

| 类型 | 判定 | 处理 |
|---|---|---|
| **(A)** 走 `luci.mk` 的包 | `LUCI_LANGUAGES` 只认 `zh_Hans` / `zh_Hant`，`po/zh-cn` 会被整条跳过 | 目录改名 `po/zh-cn` → `po/zh_Hans` |
| **(B)** 自带翻译逻辑的包 | `luci-app-openclash` 不 include `luci.mk`，`zh-cn` **硬编码**在 Makefile 里，lmo 编进主包 | **绝对不能改名**，否则 `*.*.lmo` 落空导致构建中断 |

脚本对 `luci-app-onliner`、`luci-app-adguardhome`（注入自译译本）执行 (A)，
对 `luci-app-openclash` 执行 (B) 并做存在性自检。

**两类逻辑都按「包是否存在」动态判断** —— 包被移除时输出 `SKIP`，重新启用后自动恢复
`OK` / `FAIL` 判定，无需改动脚本。

---

## 构建流程与磁盘策略

| 步骤 | 作用 |
|---|---|
| `Free Disk Space` | 释放 runner 预装内容 |
| `Preinstall Open-Box` | feeds install 之后、`make defconfig` **之前**解包 Open-Box 到 `files/` 覆盖层 |
| `Pre-build space check` | 清理残缺的 `tmp/` 中间文件；断言可用 ≥ **30 G** |
| `Purge ccache leftovers` | 兜底删除 `.ccache`（ccache 已停用） |
| `Clean Go module cache` | 避免跨构建污染 |
| `Disk rehearsal` | 编译前跑 180 s，量化磁盘消耗速率 |
| `Compile the firmware` | 含**磁盘守护**：每 60 s 检查，可用 < 3 G 立即中止，防止 runner 崩溃 |
| `Show build error tail` | 失败时输出 `df -hT` / `du -sh` 诊断 |

> `Preinstall Open-Box` 必须在 `make defconfig` 之前 —— 写入 `files/` 的覆盖层
> 只有经过 `defconfig` 才会被打进 rootfs。

### ccache：已停用

`.config` 中 `CONFIG_CCACHE` 以注释保留，取消注释即可恢复。原因：

- GitHub Actions 缓存每仓库限额 **10 GB**，而 ccache 需 5～15 GB，**跨 run 存不下**；
- 轮内复用收益小于其占用的数 GB 磁盘，而磁盘正是本项目瓶颈。

### 磁盘实测

`Disk rehearsal` 与编译期守护的实测数据（一次成功构建）：

```
dl            2.6 G
build_dir      35 G     ← 主要消耗
staging_dir   3.4 G
Open-Box 预装  0.19 G
────────────────────────
编译起始可用 44.6 G，全程峰值消耗约 41 G
```

**成功构建耗时约 114 分钟**（`Compile the firmware` 为主）。

历史上曾因 `tee` 全量落盘 + 无上限 ccache 把 72 G 分区写满，导致 runner 进程崩溃
（连 `_diag` 日志都写不进去，日志永久丢失）。现已通过以下措施解决：

1. **移除 `tee`** —— make 输出直接进 step 日志（由 GitHub 托管，不占工作盘）；
2. **停用 ccache** —— 不再有无限膨胀的缓存目录；
3. **编译期磁盘守护** —— 主动中止而非让 runner 崩溃，保住日志可查。

> 遗留风险：`build_dir` 的 35 G 距 72 G 上限仍有约 9 G 余量，**余量偏紧**。
> 若后续增加大包，建议改为「分段编译 + 打包前清理中间产物」。

---

## 文件说明

| 路径 | 用途 |
|---|---|
| `.config` | 编译配置（207 个包） |
| `diy-part1.sh` | feeds update **之前**执行：添加第三方 feed、引入 onliner |
| `diy-part2.sh` | feeds install **之后**执行：dockerd 修复、中文翻译修补 |
| `diy-part3.sh` | **Open-Box 编译期预装**：下载预编译包并写入 `files/` 覆盖层 |
| `feeds.conf.default` | feeds 定义（commit 锁定） |
| `files/` | 覆盖到固件的个性化文件（argon 主题等） |
| `.github/workflows/openwrt-x86.yml` | 构建流程 |

---

## 许可证

MIT
