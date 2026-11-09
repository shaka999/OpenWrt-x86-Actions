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

### 上游跟随策略（2026-11 起）

#### 为什么跟分支而不跟 tag

`v25.12.2` 是**标签**，停在 2026-09-06；之后上游 `openwrt-25.12` **维护分支**已前进 148 个提交
（内核 6.12.103→112、OpenSSL 3.5.7→3.5.9、musl regcomp 溢出修复、dnsmasq 大 hosts 重载优化等），
钉 tag 永远拿不到这些修复。上游也没有 v25.12.3/4/5 的 ImmortalWrt 自有 tag
（官方 OpenWrt 有 v25.12.3~6，ImmortalWrt 是直接把官方改动 merge 进分支）。

所以 `REPO_BRANCH` 指向 `openwrt-25.12`。

#### 三道闸门，避免「白烧 2.5 小时」

| 闸门 | 机制 | 实测 |
|---|---|---|
| ① SHA 比对 | 读取上次 Release 里的 `upstream.sha`，与 `git ls-remote` 的当前头比对 | `ls-remote` 1.1s |
| ② 路径过滤 | 两次 `--filter=blob:none` 浅 fetch 后 `git diff --name-only`，剔除 arm 板 target 与 WiFi/uboot/固件包 | 576 文件 → 150 相关 |
| ③ 冷却期 | 上游最新提交须静置 `COOLDOWN_HOURS`（默认 6h） | 防止编到半路被 revert |

只用 git 协议，**不消耗 API 配额**（`ls-remote` 与 `fetch` 都走 443 git 通道）。
三道全过才启动编译，单次约 114~157 分钟。

过滤用**黑名单**（fail-open）：未知新路径默认算「相关」，宁可多编一次也不漏掉内核修复。

#### 版本串固定（必做）

分支头的 `include/version.mk` 默认值是 `25.12-SNAPSHOT`，`VERSION_CODE` 走 `getver.sh`。
浅克隆下 `getver.sh` 只能算出 `r0-3682a14`（因为分支把 `version` 文件删了，且 `--depth 1`
没有历史可数），版本串因此毫无信息量。

workflow 的 `Stamp version string` 步骤注入：

```
CONFIG_IMAGEOPT=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_NUMBER="25.12-git-<上游sha前十位>"
CONFIG_VERSION_DIST="ImmortalWrt"
CONFIG_VERSION_FILENAMES=y
```

**`CONFIG_IMAGEOPT` 和 `CONFIG_VERSIONOPT` 两个开关缺一不生效**：
`scripts/package-metadata.pl` 生成 `menuconfig IMAGEOPT / default n`，
`image-config.in` 里 `menuconfig VERSIONOPT` 也是 `default n` 且整块包在 `if VERSIONOPT` 内。
官方 25.12.2 镜像的 `config.buildinfo` 里这两个都是 `=y`。

**刻意不设 `CONFIG_VERSION_REPO`**：分支头内核 6.12.112，而 `releases/25.12.2` 源里的 kmod
是 6.12.103（vermagic `0413601b...` vs `566f115f...`）。钉 25.12.2 会让 opkg 装错 ABI；
默认的 `25.12-SNAPSHOT` 源内核正是 6.12.112，与本构建一致。

#### 手动触发

`workflow_dispatch` 带 `force` 布尔参数：勾上则忽略闸门 ①②③ 直接编译。
非定时触发（`workflow_dispatch` / `repository_dispatch`）本来就一律放行。

定时任务与手动触发共用 `concurrency: openwrt-x86-build`，`cancel-in-progress: false`，
不会互相打断。

## Open-Box（编译期预装）

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
- 版本默认 `latest`：每次构建在线解析上游最新 release（跟随 `/releases/latest` 的 302，
  失败回落镜像，再失败用 `git ls-remote --tags` 枚举），并把**次新版本**作为降级候选，
  避免撞上「刚发版、资产还在传」的窗口。实际装进去的版本会写进 Release 说明。
  如遇上游版本回归，把 workflow 的 `OPENBOX_VERSION` 改成具体 tag（例如 `v0.1.403`）即可锁定。
- **上游只保留最近 10 个 release**，更旧的 tag 连同资产一起删除（`v0.1.236`、`v0.1.300`、
  `v0.1.330`、`v0.1.360`、`v0.1.393` 实测均 404），因此锁死具体版本长期必然失效。

启动顺序经刻意设计：`S98openbox-panel` → `S99openbox`，让内核**等网络完全就绪后再启动**。

### 已选插件（`.config`，**210** 个包）

| 类别 | 内容 |
|---|---|
| 代理 / 网络 | `luci-app-lucky`、`luci-app-upnp`、`miniupnpd-nftables`、`adguardhome` + `luci-app-adguardhome`（见下节） |
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

### AdGuard Home（2026-11 启用并预置配置）

`.config` 三行已恢复启用（207 → **210** 个包）：

```
CONFIG_PACKAGE_adguardhome=y                      # 本体（0.107.78，pinned feeds）
CONFIG_PACKAGE_luci-app-adguardhome=y             # LuCI 界面
CONFIG_PACKAGE_luci-i18n-adguardhome-zh-cn=y      # 中文包（由 diy-part2.sh 注入译本生成）
```

源码编译，非预编译包：

| 项 | 值 |
|---|---|
| 版本 | `0.107.78`（pinned `packages` commit `84bd8638`；分支头已到 0.107.79） |
| 源码 | `codeload.github.com/AdguardTeam/AdGuardHome/tar.gz/v0.107.78`（实测 200） |
| frontend | `AdGuardHome_frontend.tar.gz`（实测 200） |
| `PKG_BUILD_DEPENDS` | `golang/host` |
| `DEPENDS` | `+ca-bundle`（`ca-bundle` 已因 Open-Box 存在） |
| 二进制体积 | 约 12 MB（官方 apk 12,366,465 B） |

**⚠️ 首次引入 `golang/host` 工具链，构建时间会明显变长。**
当前 `.config` 里没有任何 Go 源码编译包（`lucky` 用上游预编译 tarball，`bandix-plus` 是 Rust，
`docker`/`containerd` 也是预编译），所以 `CONFIG_GOLANG_BUILD_BOOTSTRAP` 取默认 `y`，
要走**完整四段自举**：

```
go1.4-bootstrap  →  go1.17.13  →  go1.20.14  →  go1.22.12  →  go1.26.8(host)  →  AdGuardHome
```

五个 tarball 均已实测可下载（`go.dev/dl/` 全 200）。这段是本轮唯一无法离线验证的部分，
首次构建若卡住，优先看 `build_dir_host/` 与 `dl/go1.*.src.tar.gz`。

### AdGuard Home 接入方式（**已预置，开箱即用**）

出厂就接进 DNS 链路，**AdGuard Home 当 dnsmasq 的上游**：

```
客户端 → dnsmasq:53 → AdGuard Home:5353（过滤 / 查询日志）
       → sing-box:7853（分流 / fakeip）→ 外网
```

路由器实测基线（2026-11-09，改动前）：

```
dnsmasq  : 监听所有接口 53；uci server='127.0.0.1#7853'  noresolv='1'
sing-box : 监听 :::7853（UDP+TCP，Open-Box 的 dns-in inbound）
5353     : 空闲（umdns 未安装、无 avahi）
3000     : 空闲
uid 853  : adguardhome 用户由包脚本创建，与现有无冲突
```

#### 端口为什么是 5353 而不是 53

53 被 dnsmasq 占着，抢不到会让 procd 反复 respawn。所以 `dns.port` 下移到 **5353**
（`files/etc/adguardhome/adguardhome.yaml`）。`bind_hosts` 只绑 `127.0.0.1` ——
唯一消费方是同机的 dnsmasq；不绑 `0.0.0.0` 是为了不和将来的 mDNS（5353 是标准端口）冲突，
也少一个对 LAN 暴露的面。要让局域网设备直查 AdGuard，把 `bind_hosts` 改成 `10.0.0.1`。

#### 三份覆盖层文件

| 文件 | 作用 |
|---|---|
| `files/etc/adguardhome/adguardhome.yaml` | 主配置：`dns.port=5353`、`upstream_dns=127.0.0.1:7853`、`http.address=0.0.0.0:3000`、schema v34 |
| `files/etc/config/adguardhome` | uci：`enabled='1'`（覆盖上游默认 `0`） |
| `files/etc/uci-defaults/97-adguardhome-chain` | 首启：enable 服务、`dnsmasq.server=127.0.0.1#5353`、把 Open-Box 接管状态置为 `plan=none` |

#### ⚠️ 和 Open-Box 的冲突（这是唯一的坑）

Open-Box 的 `openbox_apply_takeover()`（`/opt/open-box/openwrt/initd/openbox`）在
`plan=all` 时会把 `dnsmasq.server` **强制改回** `127.0.0.1#7853`。也就是说刷机后
若 Open-Box 面板部署过，AdGuard 会被踢出链路。

`97-adguardhome-chain` 的解法是把它自己的状态文件写成：

```
/opt/open-box/data/dnsmasq-takeover.txt:
plan=none
```

`plan=none` 是 Open-Box **自己的语义**（init 第 172-175 行注释：「面板明确要求一个都不转发，
原 DNS 原样」），读到这个值它就直接 `return 0`，完全不碰 dnsmasq。

**但如果之后在 Open-Box 面板里点「部署」且 DNS 模式是 `dnsmasq`，它会重写这个文件为
`plan=all` 或 `plan=domains`，AdGuard 就再次被绕过。** 两种处理：

1. 面板里把 DNS 模式改成 `off`（代码里 `dns.mode` 的合法值之一是 `"off"`，
   此时 `dnsForward='none'`，不接管）；
2. 或者重新执行一次链路修复：
   ```sh
   printf 'plan=none\n' > /opt/open-box/data/dnsmasq-takeover.txt
   uci delete dhcp.@dnsmasq[0].server
   uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
   uci set dhcp.@dnsmasq[0].noresolv='1'
   uci commit dhcp && /etc/init.d/dnsmasq restart
   ```

#### 不能开 `use_private_ptr_resolvers`

若把 PTR 交给 `127.0.0.1:53`（dnsmasq），而 dnsmasq 的上游正是 AdGuard 的 5353，
私有地址反查会形成 `53 → 5353 → 53` 死循环。配置里显式设为 `false`。

#### 登录

- 地址：`http://10.0.0.1:3000`（LAN zone `input=ACCEPT`，无需额外防火墙规则）
- 用户名：`admin`
- 密码：`9DUwEmciHXhfBP`（bcrypt cost=10，已写入 yaml；**登录后请立即改**）

#### 关于 filters 为什么是空的

`filters: []` —— 出厂不带任何订阅列表。首次进面板勾选需要的即可
（AdGuard 内置推荐列表含 AdGuard DNS filter / OISD 等）。
空列表 + `filtering_enabled: true` 是合法的，只是暂时没有规则生效。

#### 恢复成「不经过 AdGuard」

```sh
uci delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#7853'
uci commit dhcp && /etc/init.d/dnsmasq restart
/etc/init.d/adguardhome stop && /etc/init.d/adguardhome disable
```

### files/ 覆盖层（18 个文件：主题 15 + AdGuard 3）

```
files/etc/config/network                                    676 B
files/etc/uci-defaults/99-set-zh-lang                       150 B   默认中文界面
files/usr/libexec/rpcd/luci.argon_wallpaper                3942 B   壁纸 rpcd 插件
files/usr/share/ucode/luci/template/themes/argon/*.ut   5 个模板
files/www/luci-static/argon/css/cascade.css              101551 B   定制样式
files/www/luci-static/argon/css/dark.css                  23553 B
files/www/luci-static/argon/icon/*.png/xml               5 个图标
files/etc/adguardhome/adguardhome.yaml                3131 B   见「AdGuard Home 接入方式」
files/etc/config/adguardhome                           425 B   enabled='1'
files/etc/uci-defaults/97-adguardhome-chain           3561 B   首启接 DNS 链路
```

> 主题本体（字体 / 图片 / 图标等静态资源）由 feeds 的 `luci-theme-argon` 提供，
> 覆盖层只保留个性化文件 —— 已确认被移除的 24 个文件与自带版本逐字节相同。

### `diy-part2.sh` 里的关键修补

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

**2026-11 启用 AdGuard Home 后的预估变化**（尚未实测，首次构建后回填）：

| 项 | 变化 | 说明 |
|---|---|---|
| `dl` | +约 0.6 G | 5 个 Go 源码 tarball（含 1.4 bootstrap）+ AdGuardHome 源码 + frontend |
| `build_dir` | +约 3~5 G | `build_dir_host/` 里四段 Go 工具链全量编译产物 |
| `staging_dir` | +约 0.5 G | host Go 的 bin/pkg/src 装进 `staging_dir_host` |
| rootfs | +约 12 MB | AdGuardHome 二进制（官方 apk 12,366,465 B） |
| 构建耗时 | **+30~50 分钟** | Go 自举链是纯串行，且 runner 是多核但 Go 编译阶段并行度有限 |

> ⚠️ `build_dir_host` 的 Go 自举是本轮最大的磁盘与时间不确定项。
> 若 `MIN_FREE_GB=30` 或 `GUARD_MIN_MB=3072` 触发，先看是不是 Go 这一段吃掉了余量。

---

## 文件说明

| 路径 | 用途 |
|---|---|
| `.config` | 编译配置（210 个包） |
| `diy-part1.sh` | feeds update **之前**执行：添加第三方 feed、引入 onliner |
| `diy-part2.sh` | feeds install **之后**执行：dockerd 修复、中文翻译修补 |
| `diy-part3.sh` | **Open-Box 编译期预装**：下载预编译包并写入 `files/` 覆盖层 |
| `feeds.conf.default` | feeds 定义（commit 锁定） |
| `files/` | 覆盖到固件的个性化文件（argon 主题等） |
| `.github/workflows/openwrt-x86.yml` | 构建流程 |

---

## 许可证

MIT
