# 红米 K90（SM8750）移植 iQOO Neo 11 OriginOS 7 技术设计文档与操作手册

> **文档状态**：实包初检版（已核验 K90 `OS4.0.6.0.XPKCNXM` 与 iQOO Neo 11 `PD2520_A_17.1.15.2.W10.V000L1` 实包元数据，待跑 `01-inspect-roms.yml` 补充 `lpdump`/VINTF 细节）  
> **构建与运行架构**：**GitHub Actions（`ubuntu-latest` 云端解包 / 改造 / 编译打包）** + **macOS 本地（Git 维护补丁 + `adb`/`fastboot` 刷机与抓日志）**  
> **目标设备（底包 / Base）**：REDMI K90（代号 `annibale`，`OS4.0.6.0.XPKCNXM` / Android 17，安全补丁 `2026-10-01`，物理 `super` 上限 **`12.50 GiB`**）  
> **源设备（移植包 / Port）**：iQOO Neo 11 标准版（代号 `PD2520` / `PD2520MA`，`PD2520_A_17.1.15.2.W10.V000L1` / Android 17，安全补丁 `2026-11-01`，`vfs-type=erofs`）

---

## 1. 项目概览与软硬件对齐分析

### 1.1 双机硬件与系统对齐矩阵

| 维度 | 红米 K90 (`annibale`) — 底包 | iQOO Neo 11 (`PD2520`) — 源包 | 移植影响评估 |
| :--- | :--- | :--- | :--- |
| **SoC 平台** | 骁龙 8 至尊版（`SM8750` / `sun`） | 骁龙 8 至尊版（`SM8750` / `sun`） | **完全一致**，高通基础架构与 GPU（Adreno 830）同源 |
| **Android 大版本** | Android 17（HyperOS 4） | Android 17（OriginOS 7） | **完全对齐**，VINTF / AIDL HAL 接口代差最小 |
| **屏幕参数** | 6.67" 2K（`1440×3200`）120/144Hz 直屏 | 6.82" 2K（`1440×3168`）144Hz 直屏 | 高度接近，仅需通过 RRO Overlay 修正高度/挖孔/亮度曲线 |
| **生物识别** | 屏下指纹 + 前置人脸 | 3D 超声波指纹 + 前置人脸 | 需保留 K90 原厂指纹 HAL，并适配坐标与触发节点 |
| **电池与快充** | 6500mAh / 120W 有线 + 50W 无线 | 7500mAh / 100W 有线 | 需修改 `power_profile.xml` 电池容量；快充策略由 K90 内核/vendor 主导 |
| **专属异构硬件** | 小米快充/影像/振动框架 | **自研电竞芯片 Q2** | **关键差异**：必须清理/屏蔽 Q2 独显超分超帧服务及强依赖 |
| **分区架构** | Virtual A/B + Dynamic Partitions (`super`) + EROFS | Virtual A/B + Dynamic Partitions + EROFS + **`vgc`/`oem`** | K90 无 `vgc`/`oem` 分区，需合并吸收进系统侧 |

> **核验铁律**：拿到 iQOO Neo 11 包后，第一件事是确认代号为 **`PD2520`（骁龙 8 至尊版）** 且版本为 **`17.x`（Android 17 / OriginOS 7）**，切勿混淆天玑版的 `iQOO Neo 11 至尊版` 或 `16.0.x`（OriginOS 6）。

---

### 1.2 Project Treble 分区治理边界（不可违背的红线）

跨品牌 ROM 移植成败的核心是严格遵守 **系统与底层解耦**：

| 分区类别 | 分区名称 | 处理策略 | 原因说明 |
| :--- | :--- | :--- | :--- |
| **引导与固件底层** | `xbl`、`abl`、`tz`、`hyp`、`aop`、`devcfg`、`dsp`、`modem`、`bluetooth`、`dtbo`、`recovery` 等 | **100% 保留 K90 原厂，严禁触碰** | 触碰易触发硬砖（9008）或基带损毁 |
| **内核与启动镜像** | `boot`、`init_boot`、`vendor_boot` | **保留 K90 原厂**（仅允许做 Root/宽容调试修补） | 绑定 K90 设备树（DTB）、显示/触控/音频/快充驱动 |
| **硬件抽象底层** | `vendor`、`odm`、`vendor_dlkm`、`system_dlkm` | **保留 K90 原厂为主**（仅微调 `vendor/odm` 的 `build.prop` 少量伪装与兼容性项） | 提供 K90 全部硬件 AIDL/HIDL HAL 与内核模块 |
| **校验链分区** | `vbmeta`、`vbmeta_system`（实测 K90 无 `vbmeta_vendor`） | **使用 K90 原厂镜像 + 禁用验证刷入** | 跨厂改动后原签名必然校验失败 |
| **核心系统层** | `system`、`system_ext`、`product` | **替换为 iQOO Neo 11 OriginOS 7**（实测三分区合计 `9.92 GiB`，**需精简压缩以适配 K90 `12.50 GiB` `super` 上限**） | 承载 OriginOS 7 框架、系统应用与 UI |
| **vivo 专属配置分区** | `vgc`、`oem`、`dyn`（实测位于源包 `oem_zip/` 嵌套 ZIP 内） | **解包后合入 `system`（及少量非硬件属性合入 `vendor`）** | K90 无对应物理/逻辑分区，合入可避免配置缺失与联网异常 |
| **小米专属扩展分区** | `mi_ext` | **刷入期移除或置空** | OriginOS 不需要，删除可为 `super` 释放空间 |

---

## 2. GitHub Actions 云端构建架构与前置准备

### 2.1 仓库目录规划（代码/补丁入 Git，大镜像全在云端）

Git 仓库中**严禁提交任何大体积 ROM / `.img` 文件**，仅维护 Workflow、脚本、配置与轻量补丁：

```text
redmiK90/
├── PORTING_GUIDE.md                # 本文档
├── .github/
│   └── workflows/
│       ├── 01-inspect-roms.yml     # 阶段一：云端拉包、解出元数据/VINTF/prop 体检报告（约几 MB）
│       └── 02-build-port.yml       # 阶段二：云端全流程解包、打补丁、重打包并分卷发布
├── config/
│   ├── device_annibale.env         # K90 super 布局参数、分区配额、机型基础信息
│   ├── prop_override.conf          # build.prop 品牌伪装、vgc/oem 合并与禁改白名单规则
│   ├── remove_list.txt             # 待清理服务清单（Vivo3rdAlgoService、Q2 独显等）
│   └── vintf_relax.json            # VINTF optional="false" -> "true" 放宽规则
├── patches/
│   ├── overlays/                   # 为 K90 定制的 RRO Overlay 源码/APK（挖孔、分辨率、亮度、电池）
│   ├── smali/                      # services.jar / Settings.apk 等 Smali 补丁脚本
│   └── sepolicy/                   # 后期 audit2allow 生成的自定义 SELinux 规则
├── scripts/
│   ├── 00_clean_runner_disk.sh     # 释放 GitHub Runner 磁盘空间（腾出 60~80 GB）
│   ├── 01_fetch_and_extract.sh     # 流式/分阶段解包并“边解边删”控盘
│   ├── 02_patch_system.sh          # 合并 vgc/oem、改 prop、清服务、对齐 VINTF/APEX
│   ├── 03_repack_erofs.sh          # 逐分区打包 EROFS、做容量体检与挂载自检
│   └── 04_publish_split.sh         # 按 <1.9 GB 分卷压缩 + 生成 SHA256 发布到 Release/网盘
├── backups/                        # 仅本地留存（加入 .gitignore，严禁 push 隐私/基带备份！）
└── logs/                           # 本地抓机日志（加入 .gitignore）
```

### 2.2 GitHub Actions 云端构建关键约束与破局设计

GitHub Actions 免费托管 Runner（`ubuntu-latest`，4 vCPU / 16 GB RAM）非常契合 Android EROFS 打包，但有 **3 个硬性限制**必须在架构上提前规避：

#### 限制 1：Runner 磁盘空间差异（Public vs Private 非常关键）
- GitHub 官方文档承诺的保底可用空间为 14 GB，但实际分配的 VM 规格按仓库可见性差异极大：
  - **Public 仓库（推荐用于纯脚本构包）**：4 核 16 GB RAM，**150 GB 磁盘，初始约 90 GB 可用**，清理预装工具链后可达 **115~120 GB 可用**，且 **免费无限时长**（注意：不要在公开仓库硬编码个人网盘/敏感链接，全部走 Secrets 或手填）。
  - **Private 仓库（免费版）**：2 核，**75 GB 磁盘，初始仅约 14 GB 可用**，清理预装工具链后约 **45 GB 可用**，每月限 2,000 分钟。
- **破局方案（两招组合，确保哪怕 75 GB 盘也能稳跑）**：
  1. **Job 启动先清盘**：删除 Runner 预装但用不到的 `/usr/share/dotnet`、`/usr/local/lib/android`、`/opt/ghc`、`/usr/local/.ghcup`、冗余 Docker 镜像等，可立即再释放 **25~31 GB**。
  2. **流式/分阶段“边解边删”策略（核心）**：
     - **处理 K90 底包时**：下载 `.tgz` → 仅提取 `images/super.img`、`vbmeta*.img`、`boot.img`、`init_boot.img`、`vendor_boot.img` → **立即删除 `.tgz`** → `simg2img` + `lpdump` + `lpunpack` → **立即删除 `super.img` 与 `super_raw.img`** → 提取底包 `system`/`product`/`system_ext` 中的 VINTF/Overlay/APEX 参考文件后 **立即删除底包系统镜像**，仅保留 K90 `vendor`/`odm`/`vendor_dlkm`/`system_dlkm`。
     - **处理 iQOO Neo 11 源包时**：下载 `.zip` → 若为 `payload.bin` 则用 `payload-dumper-go -p system,system_ext,product,vgc,oem` **只解这 5 个分区** → **立即删除 `.zip` 与 `payload.bin`**。
     - **重打包阶段**：每用 `mkfs.erofs` 打包完一个分区镜像（如 `system.img`），**立即 `rm -rf` 删除对应解包目录**，再打包下一个分区。
     - 通过“边解边删”，全流程峰值磁盘占用可压在 **35~40 GB** 以内。

#### 限制 2：大包输入（0 元免梯子方案：小米官方 CDN + 阿里魔搭 ModelScope 私有数据集）
- **K90 底包（`.tgz`）**：无需上传，Runner 直接通过小米官方 CDN 直链用 `aria2c -x16 -s16` 高速拉取。
- **Neo 11 源包（`.zip`）**：通过 [`scripts/local_upload_ms.sh`](scripts/local_upload_ms.sh) 国内直连上传至 **阿里魔搭 ModelScope 私有数据集**（免费、免梯子、单文件免切片、永久有效），Token 存入 GitHub Secret **`MODELSCOPE_API_TOKEN`**，Runner 端通过轻量 `modelscope-hub` 并行断点拉取（同时兼容 `hf://`、`rclone://` 与普通直链）。

#### 限制 3：大产物回传（免切片回传魔搭私有库 + 轻量报告走 Artifact）
- **GitHub Releases 单文件硬上限为 2 GB**；Actions Artifacts 在私有库免费额度仅 **500 MB**，不可用于存放 8 GB 的 ROM 镜像。
- **破局方案（分层输出）**：
  1. **诊断报告（< 10 MB）→ GitHub Actions Artifact**：每次构建都上传轻量报告（`k90_super_layout.txt`、VINTF 差异报告、合并后 `build.prop`、`ls -lh` 容量表、构建日志），直接在浏览器点开即可审查，无需下载大包。
  2. **ROM 产物（6~9 GB）→ 自动回传至阿里魔搭私有数据集（免切片、国内满速下载）**：使用同一套 `MODELSCOPE_API_TOKEN` 直接推回私有库，macOS 本地国内直连高速拉取；如需同步发布公开版本，也可选按 `1900M` 切片发布为 GitHub Draft Release。
- **仓库隐私提醒**：调试期镜像可能开启 `ro.debuggable=1`，且可能配置个人网盘链接，建议**使用 Private 仓库**，所有 Token/链接凭证统一走 **GitHub Secrets**（注：免费私有库每月含 2,000 分钟 Actions 额度，单次构建约 15~25 分钟，足够支撑 80+ 次迭代；若希望无限免费时长且不含敏感信息，也可只脱敏配置放 Public 仓库）。

#### 双端工具分工清单
- **GitHub Actions 云端（`ubuntu-latest`，Workflow 自动安装）**：
  - `aria2` / `rclone`、`payload-dumper-go`、`erofs-utils`（`extract.erofs`、`mkfs.erofs`、`dump.erofs`）、AOSP `otatools`（`lpdump`、`lpunpack`、`lpmake`、`simg2img`、`avbtool`）、`brotli`、`magiskboot`、`apktool`、`baksmali`/`smali`、`openjdk-17`、`python3`、`zstd`。
- **macOS 本地（彻底轻量化，不再装 Linux 虚拟机）**：
  - 仅需安装最新版 `android-platform-tools`（`brew install --cask android-platform-tools`），用于 **`adb` 抓日志、`fastboot`/`fastbootd` 刷机与救砖**，以及用 `zstd` 合并云端下载的分卷包（`cat *.part* | tar --zstd -xvf -`）。

### 2.3 手机端前置安全备份（动手前必做）

在刷入任何移植镜像前，请对红米 K90 执行以下操作：

1. **确认 Bootloader 已解锁**：
   ```bash
   fastboot getvar unlocked          # 必须返回 yes
   fastboot getvar current-slot      # 记录当前活跃槽位（如 a）
   fastboot getvar all > backups/k90_fastboot_vars.txt 2>&1
   ```
2. **备份不可再生分区**（在已 Root 的原厂 HyperOS 4 下通过 `adb shell su` 执行）：
   ```bash
   mkdir -p /sdcard/k90_critical_backup
   for part in persist modemst1 modemst2 fsg fsc devinfo; do
     dd if=/dev/block/by-name/${part} of=/sdcard/k90_critical_backup/${part}.img bs=4M
   done
   sha256sum /sdcard/k90_critical_backup/*.img > /sdcard/k90_critical_backup/SHA256SUMS
   ```
   随后用 `adb pull /sdcard/k90_critical_backup backups/` 拉取到电脑，并额外存一份云盘或 U 盘。
3. **验证救砖包可用**：提前将红米 K90 HyperOS 4 官方 `.tgz` 线刷包解压完毕，确认目录中存在 `images/` 和 `flash_all.sh`（macOS/Linux）/ `flash_all.bat`（Windows），并确认电量在 **60% 以上**、使用**原装或可靠数据线**直连电脑主板/雷电口（避免经由不稳定扩展坞）。

---

## 3. 分阶段移植详细步骤（GitHub Actions 云端 + macOS 刷机 SOP）

> **迭代最佳实践（两段式 Workflow）**：  
> - **首次拿到包**：先跑 **`01-inspect-roms.yml`**（只做云端解包与体检，10 分钟内产出 ~10 MB 体检报告 Artifact），下载报告确认真实分区结构、VINTF 差异与 `super` 上限后，再精准填写 `config/` 与 `patches/`。  
> - **正式构包与迭代**：提交补丁到 Git → 触发 **`02-build-port.yml`** → 云端自动打包并分卷发布 → macOS 下载合并并刷机验证。后续仅改单个分区（如只改 `services.jar` 或 RRO Overlay）时，可在 `workflow_dispatch` 中勾选 **`build_mode=fast_single_partition`** 缩短构建耗时。

### 阶段一：底包与源包解包、元数据采集（云端执行）

#### 1.1 流式解包红米 K90 HyperOS 4 线刷包（`.tgz`）
在 Runner 清理磁盘后，用 `aria2c` 下载底包并仅提取所需镜像，**边解边删控盘**：
```bash
# 仅提取 images/ 中的 super 与引导/校验镜像，避免展开无用的大体积固件占用磁盘
tar -xzf /mnt/dl/stock_k90.tgz -C /mnt/work/stock_imgs/ \
  --wildcards '*/images/super.img' '*/images/vbmeta*.img' \
  '*/images/boot.img' '*/images/init_boot.img' '*/images/vendor_boot.img'
rm -f /mnt/dl/stock_k90.tgz

cd /mnt/work/stock_imgs/*/images/
# 1. 将稀疏 super.img 转为 raw 镜像并完整记录原厂动态分区元数据
simg2img super.img super_raw.img
rm -f super.img
lpdump super_raw.img > /mnt/work/k90_super_layout.txt

# 2. 提取所有逻辑分区后立即删除 super_raw.img
mkdir -p /mnt/work/k90_logical
lpunpack super_raw.img /mnt/work/k90_logical/
rm -f super_raw.img
```
**必须重点记录的基线参数**（由 `01-inspect-roms.yml` 自动写入体检报告并同步到 `config/device_annibale.env`）：
- `super` 分区总字节数（`Size`）
- `Metadata max size` 与 `Metadata slot count`
- 分组名（如 `qti_dynamic_partitions_a` / `b`）及组大小上限
- 各逻辑分区原始文件系统类型（通过 `file` 或 `dump.erofs` 确认是否为 EROFS 及压缩算法，如 `lz4hc`）

#### 1.2 精准解包 iQOO Neo 11 OriginOS 7 全量包（实测结构）
已核验 `PD2520A_17.1.15.2W10.V000L1-update-full.zip` 的真实内部结构：主分区位于根目录 `payload.bin`，而 `vgc`/`oem`/`dyn` 位于 `oem_zip/` 嵌套包内：
```bash
# 1. 先提取嵌套的 vivo 专属配置包（总计仅 ~6 MB）
unzip /mnt/dl/port_neo11.zip \
  "oem_zip/vgc_V000_PD2520MA.zip" \
  "oem_zip/oem_PD2520_ALL_IN_ONE_02.zip" \
  "oem_zip/dyn_PD2520_NULL.zip" \
  -d /mnt/work/port_oem_zips/

# 2. 从主 payload.bin 仅解出 3 个系统侧分区，跳过全部底层固件与 vendor
payload-dumper-go -p system,system_ext,product \
  -o /mnt/work/port_imgs/ /mnt/dl/port_neo11.zip
rm -f /mnt/dl/port_neo11.zip

# 3. 解出嵌套包内的小型 payload.bin（vgc / oem）与 dyn.new.dat.br
#    其中 oem 取公开全网通配置：oem/PD2520_CN-ZH_FULL_SC_NULL/oem.prop
```

#### 1.3 提取文件系统目录树（务必保留权限与 SELinux 上下文）
```bash
# 示例：使用 extract.erofs 解包并导出 fs_config 与 file_contexts（不同版本工具参数略有差异，届时按实际版本封装到脚本）
extract.erofs -x -i work/port_imgs/system.img -o work/unpack_port/system
# 同时记录文件系统元数据、挂载点、compression flags 与 xattr/contexts 到 work/configs/
```
同样解包：
- 源包：`system`、`system_ext`、`product`、`vgc`、`oem`
- 底包：`vendor`、`odm`（用于微调伪装）、`system`/`system_ext`/`product`（**只读参考**，用于提取 K90 的 Overlay、VINTF、APEX 差异）

---

### 阶段二：底层引导、AVB 与早期调试通道准备

#### 2.1 引导镜像处理（保证宽容调试与抓取早期日志）
1. **保持 K90 原厂内核**：使用 K90 底包中的 `boot.img`、`init_boot.img`、`vendor_boot.img`。
2. **Root 与 SELinux Permissive**：
   - 推荐在 K90 原厂 `init_boot.img`（或 GKI `boot.img`，视 K90 KMI 版本而定）中打入 **KernelSU / Magisk**。
   - **首次点亮调试阶段**：通过修补内核 cmdline 或使用对应 KMI 的宽容内核/模块使系统处于 `SELinux Permissive`，避免尚未整理的数百条跨厂 `avc: denied` 在一屏/二屏阶段直接掐死 `init` 和 `servicemanager`。
3. **开启早期免授权 ADB（仅调试版本启用，日用前务必关闭）**：
   在移植包 `system/system/build.prop`（及 `system/system/etc/prop.default`）末尾追加：
   ```properties
   ro.debuggable=1
   ro.adb.secure=0
   persist.sys.usb.config=mtp,adb
   persist.service.adb.enable=1
   persist.sys.usb.config.extra=none
   ```
   > 作用：只要内核拉起 `adbd`，哪怕卡在开机动画（二屏）甚至黑屏，也能直接在电脑运行 `adb logcat` 与 `adb shell dmesg` 精准定位崩溃点。

#### 2.2 AVB 2.0 禁用策略
- 实测 K90 底包仅包含 **`vbmeta.img`** 与 **`vbmeta_system.img`**（无 `vbmeta_vendor`）。
- 刷入时统一附加 `--disable-verity --disable-verification`，避免修改 `fstab` 破坏 DSU 兼容性。

#### 2.3 检查 K90 `fstab` 与挂载点
- 检查 K90 `vendor/etc/fstab.qcom`（及 `vendor_boot` ramdisk 中的 `fstab`）：
  - 确认 `system`、`system_ext`、`product`、`vendor`、`odm` 的文件系统类型（通常为 `erofs`，部分机型同时兼容 `ext4`）。
  - **推荐全程打包为 `erofs`**，与原厂 `fstab` 100% 匹配且体积更小，避免因 `super` 空间不足或 `fstab` 挂载失败卡一屏。

---

### 阶段三：系统层合并、vivo 属性伪装与依赖对齐（核心改造）

#### 3.1 合并 vivo 专属 `vgc` 与 `oem` 分区
红米 K90 的分区表不含 `vgc` 和 `oem`，必须将源包的这两个分区无损吸收：
1. **属性合并**：
   - 提取 `vgc` 中的 `.vgc.prop`（及子目录 `build.prop`）与 `oem` 中的 `.oem.prop`，过滤掉冲突的只读指纹/分区路径项后，追加合并至 `system/system/build.prop`。
   - 检查 `oem` 下的 `vendor.prop`：仅挑选 vivo 上层服务依赖的非硬件业务属性（如特性开关、区域/网络标识）合并至 K90 `vendor/build.prop`。
2. **文件与路径映射**：
   - 将 `vgc`、`oem` 中的 `etc/`、`overlay/`、`app/`、`priv-app/` 等资源按路径合并到 `system/system/`（或保留独立子目录 `/system/system/vgc`、`/system/system/oem` 并在 `system` 根目录下建立软链接 `/vgc -> /system/vgc`、`/oem -> /system/oem`，同时补齐对应 `file_contexts`），防止 OriginOS 框架按硬编码 `/vgc/...` 或 `/oem/...` 路径读取文件时崩溃或无法联网。

#### 3.2 品牌与设备身份伪装（过 vivo 框架与账号校验）
1. **统一品牌与制造商标识**：
   在 `system/system/build.prop`、K90 `vendor/build.prop`、K90 `odm/etc/build.prop` 中，将品牌与厂商修改为 `vivo`：
   ```properties
   ro.product.brand=vivo
   ro.product.manufacturer=vivo
   ro.product.vendor.brand=vivo
   ro.product.vendor.manufacturer=vivo
   ro.product.odm.brand=vivo
   ro.product.odm.manufacturer=vivo
   ```
   > **严格禁改清单（严禁覆盖 K90 原厂值）**：  
   > `ro.hardware.*`、`ro.board.platform`、`ro.boot.*`、`ro.vendor.qti.*`、音频/相机/传感器/NFC/指纹校准属性、基带与 RIL 属性。
2. **展示信息与系列属性**：
   - 按需设置 `ro.vivo.internet.name`、`ro.vivo.market.name`（如 `REDMI K90`）并核对 `ro.vivo.product.series`。
3. **清理失效的动态 `import`**：
   - 全局检索 `system`、`vendor`、`odm` 所有 `*.prop` 文件中的 `import /.../build.prop` 语句，凡是包含环境变量（如 `${ro.boot.prjname}`、`${ro.boot.hwc}`、`${ro.vivo.*}`）且目标文件在移植环境下不存在的，一律注释删除或静态展开，防止 `init` 属性加载中断。

#### 3.3 清理 iQOO Neo 11 独有硬件强绑定服务
在 `unpack_port/system`、`system_ext`、`product` 中检索并移除/禁用以下 K90 不具备的硬件服务：
1. **影像专有算法服务**：删除 `/system/system/app/Vivo3rdAlgoService`（已知跨厂移植最易导致相册卡死/后台循环崩溃的源头）。
2. **iQOO Q2 独显芯片服务**：检索含 `iris`、`pixelworks`、`memc`、`q2`、`display_ic`、`super_res`、`game_frame` 的 daemon、`init.*.rc` 与 APK 依赖，屏蔽其自启动 `rc` 并移除强 HAL 绑定，防止游戏魔盒或 SurfaceFlinger 回调异常。
3. **冲突的分区校验二进制（按日志决定，不盲改）**：若后续测试确认卡二屏且日志指向 `fs_mgr` 校验拦截，再针对性排查 `init`、`libfs_mgr.so`、`libfs_mgr_binder.so`。

#### 3.4 VINTF 兼容矩阵与 APEX / VNDK 对齐
1. **自动化比对 VINTF**：
   - 对比 **K90 底包** `vendor/etc/vintf/manifest.xml`（+ `manifest/` + `odm/etc/vintf/`）与 **Neo 11 源包** `system/etc/vintf/compatibility_matrix.*.xml`（+ `system_ext/etc/vintf/` + `product/etc/vintf/`）。
   - 找出所有源包声明为 `optional="false"` 但 K90 `vendor` 并未提供的 vivo 私有 HAL（常见如 `vendor.vivo.hardware.*`），将其改为 `optional="true"` 或删除对应条目。
2. **APEX 与共享库检查**：
   - 对比底包与源包 `system_ext/apex/`、`system/apex/` 中的 VNDK / QTI APEX 版本。
   - 保留 K90 `vendor` 正常运行所需的 VNDK / 依赖库，防止 `linker` 报 `CANNOT LINK EXECUTABLE` 导致关键 HAL（音频、相机、指纹、传感器）起不来。

#### 3.5 预置红米 K90 硬件 RRO Overlay
从 K90 底包 `product/overlay/`、`vendor/overlay/` 中提取以下硬件参数，制作专属 RRO Overlay（如 `K90OriginFrameworkResOverlay.apk`、`K90OriginSystemUIOverlay.apk`）放入移植包 `product/overlay/`：
- 屏幕物理尺寸、分辨率（`1440×3200`）、圆角半径、状态栏高度
- 前摄挖孔路径（`config_mainBuiltInDisplayCutout`）
- 自动亮度配置（`display_id_*.xml` 或对应亮度曲线）
- 电池容量配置：同时修正源包 `VivoFrameworksResRRO.apk` 中的 `res/xml/power_profile.xml` -> `battery.capacity` 为 K90 的 `6500` mAh。

---

### 阶段四：云端重打包、自动体检与分卷发布

#### 4.1 逐分区打包为 EROFS 镜像（边打包边清盘）
在 GitHub Actions Ubuntu Runner 中对改动过的每个分区重新生成 EROFS 镜像，**必须完整传入 `fs_config` 与 `file_contexts`**，每打完一个分区立即清理对应解包目录释放空间：

```bash
# 示例（具体压缩参数与挂载点将在 01-inspect-roms 体检后与原厂完全对齐）
mkfs.erofs -zlz4hc,9 \
  --mount-point=/system \
  --fs-config-file=/mnt/work/configs/system_fs_config \
  --file-contexts=/mnt/work/configs/system_file_contexts \
  /mnt/out/system.img /mnt/work/unpack_port/system
rm -rf /mnt/work/unpack_port/system
```
同理依次生成并清理：`system_ext.img`、`product.img`、`vendor.img`、`odm.img`（`vendor_dlkm.img`、`system_dlkm.img` 直接复用 K90 原厂镜像）。

#### 4.2 云端 CI 自动体检门禁（不通过则直接终止发布）
Workflow 自动执行以下 3 项硬校验，任何一项失败立即报错红灯，避免把坏包刷进真机：
1. **容量门禁**：计算 `system + system_ext + product + vendor + odm + vendor_dlkm + system_dlkm` 总字节数，校验严格小于 K90 `qti_dynamic_partitions_a` 上限（并预留至少 50~100 MB 余量）。
2. **镜像可读与结构校验**：在 Runner 上执行 `dump.erofs` / `sudo mount -o ro,loop` 验证每个 `out/*.img` 可正常挂载，且关键文件 `/system/bin/init`、`/system/build.prop`、`/vgc`、`/oem` 存在、权限与 SELinux 上下文完整。
3. **关键属性审计**：脚本自动断言 `brand/manufacturer=vivo` 已生效，且 K90 `vendor` 中的硬件/基带关键属性未被污染，输出 `build_report.md` 作为 Actions Artifact 留档。

#### 4.3 分卷发布与 macOS 本地还原
由于 GitHub Release 单文件上限为 2 GB，Workflow 自动打包切片并发布：
```bash
# 1. 云端打包分卷（zstd 高速压缩 + 每卷 1900 MB）
tar -C /mnt/out -cf - . | zstd -T0 -6 | split -b 1900M - /mnt/release/k90_originos7_v1.tar.zst.part
sha256sum /mnt/release/k90_originos7_v1.tar.zst.part* > /mnt/release/SHA256SUMS.txt

# 2. 通过 gh release create 上传至 Draft Release（或 rclone copy 推送至私有网盘）
```
在 **macOS 本地** 下载所有分卷后，校验并解压即可进入刷机：
```bash
shasum -a 256 -c SHA256SUMS.txt
mkdir -p out && cat k90_originos7_v1.tar.zst.part* | zstd -d | tar -xf - -C out/
```

---

### 阶段五：灰度验证（DSU 优先）与正式刷入

#### 5.1 阶段 5A：DSU 无损试跑（强烈推荐首次验证使用）
在正式覆写 K90 `super` 分区之前，优先在原厂 HyperOS 4 上通过 **DSU Sideloader** 加载测试：
1. 将需要测试的 `system.img`（及对应动态系统镜像）按**仅存储（Store，不压缩）**模式打包。
2. 通过 DSU Sideloader 安装并重启进入动态系统。
3. **本阶段验收目标**：能跳过一屏、进入 OriginOS 7 开机动画、电脑能连上 `adb logcat`，最好能点亮进入向导/桌面。
4. 若不开机，**直接强制重启即可毫发无损回到原厂 HyperOS 4**。

#### 5.2 阶段 5B：正式刷入（`fastbootd` 散包模式 — 调试迭代最快捷）
> **安全技巧**：若想保留另一槽位作为“热备回退系统”，先确认当前槽位（假设为 `a`），确保 `b` 槽有完整可启动的原厂 HyperOS 4（或只在实验槽操作）。

```bash
# 1. 进入 fastbootd 模式（注意：是 fastbootd，不是普通 bootloader）
adb reboot fastboot

# 2. 按需清理小米专属分区腾出 super 空间（假设当前刷入 a 槽）
fastboot delete-logical-partition mi_ext_a

# 3. 刷入移植系统分区与微调后的底层分区
fastboot flash system_a out/system.img
fastboot flash system_ext_a out/system_ext.img
fastboot flash product_a out/product.img
fastboot flash vendor_a out/vendor.img
fastboot flash odm_a out/odm.img

# 4. 刷入禁用 AVB 的 vbmeta 链（实测 K90 仅含 vbmeta 与 vbmeta_system，Workflow 已一并打入 out/）
fastboot --disable-verity --disable-verification flash vbmeta out/vbmeta.img
fastboot --disable-verity --disable-verification flash vbmeta_system out/vbmeta_system.img

# 5. 首次跨厂刷入必须格式化 userdata（解除原 HyperOS FBE 加密冲突）
fastboot -w
fastboot reboot
```

#### 5.3 阶段 5C：整包 `super.img` 合成（稳定后封包发布用）
稳定后使用 `lpmake` 严格按 `k90_super_layout.txt` 参数合成整包 `super.img`（稀疏格式 `--sparse`），在 Bootloader 模式下 `fastboot flash super out/super.img` 一次写入。

---

## 4. 常见问题与排障修复手册

### 4.1 排障标准取证命令
每次开机失败或功能异常，第一时间收集以下 4 份日志保存到 `logs/`：
```bash
# 1. 全局错误与崩溃栈
adb logcat -b all -d > logs/logcat_full.txt
adb logcat -b all *:E | grep -E "FATAL|AndroidRuntime|linker|VINTF|ServiceManager|vivo"

# 2. 内核与 init / SELinux 拦截日志
adb shell dmesg > logs/dmesg.txt
adb shell dmesg | grep -E "avc: denied|init:|fs_mgr|panic"

# 3. 原生进程崩溃墓碑
adb pull /data/tombstones logs/tombstones/

# 4. 硬件服务状态检查
adb shell lshal
adb shell dumpsys display | head -n 80
```

### 4.2 故障分类排查与修复矩阵

| 现象 | 常见根因 | 排查与修复方案 |
| :--- | :--- | :--- |
| **1. 卡一屏（REDMI Logo）或秒重启进 Fastboot** | AVB 未关闭；`super`/逻辑分区损坏；`fstab` 文件系统不匹配；内核/ramdisk 损坏 | 重新确认 `vbmeta`/`vbmeta_system` 已带 `--disable-verity --disable-verification` 刷入；核对打包格式（EROFS）与 `fstab` 一致；恢复原厂 `boot`/`init_boot`/`vendor_boot`；查看 TWRP `/sys/fs/pstore/console-ramoops*` 内核日志。 |
| **2. 卡二屏（OriginOS 开机动画无限循环）** | VINTF 强依赖缺失；SELinux Enforcing 拦截；`system_server` 抛 `FATAL EXCEPTION`；未执行 `fastboot -w` 导致 FBE 加密冲突 | 1) 确认已执行 `fastboot -w`；<br>2) 确认处于 SELinux Permissive；<br>3) 通过 `adb logcat` 查第一个 `FATAL` 或 `linker` 报错，补齐缺失库或修改 VINTF `optional="true"`；<br>4) 若日志指向挂载/校验失败，排查 `init` / `libfs_mgr*.so`。 |
| **3. 进系统后偶发软重启（尤其横竖屏/息屏亮屏）** | `LogicalDisplayMapper` 对屏幕方向或双屏/刷新率状态判断异常 | 抓取软重启前 `logcat` 堆栈，使用 `baksmali` 反编译 `services.jar`，定位 `LogicalDisplayMapper` 异常分支打补丁（如安全返回或修正显示配置）。 |
| **4. 无法联网 / 部分 App（微信、银行）断网** | `vgc` / `oem` 区域网络属性未完整合并或冲突 | 检查 `.vgc.prop` 和 `.oem.prop` 是否完整写入 `system/build.prop`；核对 `/vgc`、`/oem` 路径映射与权限。 |
| **5. vivo 账号无法登录 / 提示设备异常** | 品牌/厂商属性未伪装彻底 | 确认 `system`、`vendor`、`odm` 的 `brand` 与 `manufacturer` 均为 `vivo`，并检查 `ro.vivo.product.series`。 |
| **6. 挖孔错位 / 自动亮度失灵 / 刷新率异常** | 缺少 K90 显示 RRO Overlay 或 Q2 独显服务残留 | 补全 K90 `display_id_*.xml`、挖孔/圆角/状态栏 RRO；检查并移除残留的 Q2 独显刷新率接管服务。 |
| **7. 屏下指纹图标错位 / 无法录入 / 无高亮** | 指纹坐标配置不符；小米与 vivo 屏幕局部高亮（LHBM）节点路径不同 | 用 RRO 校准指纹图标 X/Y 坐标；检查 K90 指纹 AIDL HAL 是否正常运行（`lshal`）；追踪 `SystemUI` / `services.jar` 触发高亮的 sysfs/ioctl 路径并做桥接适配。 |
| **8. 相机黑屏闪退 / 相册打开卡死** | `Vivo3rdAlgoService` 冲突；vivo 原厂相机强依赖私有 Camera HAL | 确认已删除 `Vivo3rdAlgoService` 修复相册；相机初期先装 **GCam** 或移植小米相机验证 K90 原厂 Camera HAL 正常，再逐步排查 vivo 相机适配。 |
| **9. 线性马达不震动或震感异常** | `services.jar` 中 `VibratorController` 调用 vivo 私有波形 ID 失败 | 反编译 `services.jar`，定位 `VibratorController` 效果 ID 映射逻辑，将非法私有波形 ID 回退为标准 Android 波形（如清零回退通用效果）。 |
| **10. 关于本机 CPU/电池容量显示错误** | `Settings.apk` 硬件读取映射表不含目标值；`power_profile.xml` 沿用 Neo 11 数值 | 反编译 `Settings.apk` 修正 `getCpuInfo` 返回值；反编译 `VivoFrameworksResRRO.apk` 将 `battery.capacity` 改为 K90 实测容量。 |
| **11. 通话无声 / 蓝牙音频异常 / NFC 刷卡失败** | 上层服务与 K90 `vendor` 音频/NFC HAL 接口不匹配 | 严守 K90 原厂 `vendor/etc/audio*`、`acdbdata`、`libnfc-nci.conf` 不被污染；通过 `logcat` 查 `AudioFlinger` / `NfcService` 报错并对齐对应配置或补齐系统侧兼容库。 |
| **12. 最终收敛：SELinux 恢复 Enforcing** | 日用阶段需要恢复安全上下文并通过金融类 App 检测 | 保持 Permissive 完整遍历全部功能 1~2 天 → 导出全部 `avc: denied` → 用 `audit2allow` 生成最小权限 `sepolicy` 补丁 → 切回 Enforcing 并复测所有功能，同时关闭 `ro.debuggable=1` 和 `ro.adb.secure=0`。 |

---

## 5. 全场景回退与救砖预案（有备无患）

### 5.1 绝对不可触碰的 4 条防砖红线
1. **绝不刷入 iQOO 的任何底层固件**（`xbl`、`abl`、`tz`、`modem`、`boot`、`dtbo`、`super` 之外的所有分区）。
2. **绝不在非官方系统状态下执行 `flash_all_and_lock` / 回锁 Bootloader**（100% 触发验证失败变砖）。
3. **绝不擦除或覆写基带/校准分区**（`modemst1`、`modemst2`、`fsg`、`persist`）。
4. **刷入前务必确认电量 > 60% 且数据线连接稳固**，刷 `super` 过程中切勿拔线。

---

### 5.2 分级回退方案（按轻重程度排序）

#### 场景 A：DSU 试跑失败（黑屏 / 卡动画 / 无限重启）
- **严重度**：极低（零破坏）
- **回退步骤**：
  1. 长按 **电源键 10~15 秒** 强制重启，手机会自动退出 DSU 并回到原厂 HyperOS 4。
  2. 进入系统后，在通知栏或 DSU Sideloader 中点击「丢弃（Discard）」清理临时镜像即可。

#### 场景 B：保留了另一完整 A/B 槽位，新槽位刷入后不开机
- **严重度**：低（10 秒秒回）
- **前提**：原厂系统在 `b` 槽完好，仅向 `a` 槽刷入了移植系统（且尚未破坏 `b` 槽和公共元数据）。
- **回退步骤**：
  1. 长按 **电源键 + 音量下键** 进入 Fastboot（Bootloader）模式。
  2. 切换回未改动槽位并重启：
     ```bash
     fastboot set_active b
     fastboot reboot
     ```
  *(注：若在测试阶段已经执行过 `fastboot -w`，切回原槽后可能需要重新激活设置，但系统本身完好)*。

#### 场景 C：正式刷入后卡 Logo / 无限重启 / 放弃移植（标准全量回退）
- **严重度**：中（最可靠的标准救砖方式）
- **回退步骤**：
  1. 长按 **电源键 + 音量下键** 强制进入 Fastboot 模式（确认屏幕出现 `FASTBOOT` 字样）。
  2. 执行 `fastboot devices` 确认电脑已识别设备。
  3. 进入提前解压好的红米 K90 官方 HyperOS 4 线刷包目录，执行 **不锁 BL 的完整刷机脚本**：
     - macOS / Linux：`bash flash_all.sh`
     - Windows：双击运行 `flash_all.bat`（或 MiFlash 底部务必勾选 **「全部删除 / clean all」**，**绝对不要勾选 `clean all and lock`**）。
  4. 等待脚本自动刷完所有分区并重启，约 3~5 分钟即可恢复到纯净官方 HyperOS 4。

#### 场景 D：`fastbootd` 无法进入或动态分区表（`super`）被改乱
- **严重度**：中高
- **表现**：执行 `fastboot reboot fastboot` 卡死或进不去蓝/橙字 `fastbootd`，无法刷写单个逻辑分区。
- **回退步骤**：
  1. 强制重启进入普通 **Bootloader（Fastboot）** 模式。
  2. 先单刷 K90 原厂的引导与校验镜像，再整刷原厂 `super.img` 重建干净的动态分区表：
     ```bash
     fastboot flash boot_a images/boot.img
     fastboot flash boot_b images/boot.img
     fastboot flash init_boot_a images/init_boot.img
     fastboot flash init_boot_b images/init_boot.img
     fastboot flash vendor_boot_a images/vendor_boot.img
     fastboot flash vendor_boot_b images/vendor_boot.img
     fastboot flash recovery_a images/recovery.img
     fastboot flash recovery_b images/recovery.img
     fastboot flash vbmeta_a images/vbmeta.img
     fastboot flash vbmeta_b images/vbmeta.img
     fastboot flash vbmeta_system_a images/vbmeta_system.img
     fastboot flash vbmeta_system_b images/vbmeta_system.img
     fastboot flash super images/super.img
     fastboot -w
     fastboot reboot
     ```
  3. 或直接按 **场景 C** 执行完整 `flash_all.sh`。

#### 场景 E：回退后基带未知 / 传感器失灵 / 指纹校准丢失
- **严重度**：高
- **前提**：已按第 2.3 节提前备份 `persist`、`modemst1`、`modemst2`、`fsg`。
- **回退步骤**：
  1. 先刷回官方 HyperOS 4 并获取临时 Root（或进入适配版 TWRP）。
  2. 核对备份文件 `SHA256SUMS` 无误后，仅将异常对应分区通过 `dd` 写回（如传感器/指纹校准异常优先恢复 `persist`，基带异常恢复 `modemst1`/`modemst2`/`fsg`），重启验证。

#### 场景 F：黑砖 / 无法进入 Fastboot（触发 Qualcomm EDL 9008）
- **发生条件**：只要严格遵守 5.1 红线（不刷错 `xbl`/`abl`/`tz`、不回锁 BL、刷机不断电），**本移植流程几乎不可能触发 9008**。
- **兜底处理**：若因意外断电或误刷底层导致无法进 Fastboot、电脑识别为 `Qualcomm HS-USB QDLoader 9008`，需使用小米授权账号/官方售后或对应 SM8750 救砖渠道刷回官方固件。

---

## 6. 实包接入检查单（下一步衔接）

当你准备好两个 ROM 的云端下载地址（直链或网盘方式）后，告诉我以下信息，我即可直接为你生成 `.github/workflows/01-inspect-roms.yml`、`02-build-port.yml` 以及全套 `scripts/` 脚本：

- [ ] **K90 HyperOS 4 线刷包下载方式**（官方 `.tgz` 直链，或网盘 + `rclone` 路径）
- [ ] **iQOO Neo 11 OriginOS 7 全量包下载方式**（官方/网盘 `.zip` 直链，或 `rclone` 路径）
- [ ] **产物回传方式偏好**（GitHub Draft Release 1.9 GB 分卷 / `rclone` 回传指定网盘 / 两者都要）
- [ ] **手机实机备份完成确认**（macOS 已装最新版 `platform-tools`、BL 已解、`backups/k90_fastboot_vars.txt` 与不可再生分区已备份）
