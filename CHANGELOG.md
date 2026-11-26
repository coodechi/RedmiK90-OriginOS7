# Changelog — 红米 K90 (annibale) 移植 iQOO Neo 11 (PD2520) OriginOS 7

本文件按时间顺序记录本项目**每一步的实际执行操作、实测数据、变更内容**，以及**尚未补充/待执行的后续步骤清单**，确保全流程可追溯、可复现、可回退。

---

## [Unreleased] — 实包核验与工程初始化

### 2026-11-26

#### Step 1：移植方案预设计与 GitHub Actions 云端架构定型
- **操作内容**：
  - 调研并核对目标机 **REDMI K90（`annibale` / SM8750 / Android 17 HyperOS 4）** 与源机 **iQOO Neo 11 标准版（`PD2520` / `V2520A` / SM8750 / Android 17 OriginOS 7）** 的硬件与系统对齐情况，排除跨芯片的天玑版 `iQOO Neo 11 至尊版` 与跨代 `iQOO Neo 12`。
  - 创建技术设计文档 [`PORTING_GUIDE.md`](PORTING_GUIDE.md)，涵盖分区红线、6 阶段移植 SOP、排障矩阵与 A~F 六级回退救砖预案。
  - 按用户要求将构建方式重构为 **GitHub Actions 云端解包/打补丁/EROFS 打包 + macOS 本地仅负责 Git 与 `adb`/`fastboot` 刷机调试**，并针对 Runner 磁盘差异（Public 150 GB vs Private 75 GB）、单文件 2 GB 限制设计了“清盘 + 边解边删 + 1900 MB 分卷发布”策略。

#### Step 2：本地环境与双端实包无损体检（不解压大镜像）
- **实包到位确认**：
  - 底包（K90）：`annibale_images_OS4.0.6.0.XPKCNXM_20261026.0000.00_17.0_cn_8129267a3b.tgz`（12 GB）
  - 源包（Neo 11）：`PD2520A_17.1.15.2W10.V000L1-update-full.zip`（10 GB）
- **本地工具检查结果**：
  - 已具备：`git`（`/usr/bin/git`）、`adb` 与 `fastboot`（`/Users/zayzhang/Library/Android/sdk/platform-tools/`）、`tar`、`python3`。
  - 未安装：`gh`、`zstd`、`rclone`、`docker`；当前目录尚未初始化 Git 仓库。
- **底包（红米 K90 HyperOS 4）实测参数**（通过 `tar -tvzf` 与提取极小元数据文件核验）：
  - 包内根目录：`annibale_images_OS4.0.6.0.XPKCNXM_17.0/`
  - 设备与版本：`device=annibale`、`build_number=OS4.0.6.0.XPKCNXM`、安全补丁 `2026-10-01`、防回滚 `anti_version=1`
  - **`super` 分区物理上限**（来自 `rawprogram0.xml`）：`3,276,800 × 4096` = **`13,421,772,800 bytes`（严格 `12.50 GiB`）**，包内稀疏 `super.img` 大小为 `11,553,565,264 bytes`（~10.76 GiB）
  - **AVB 分区核实**（来自 `flash_all.sh`）：仅含 **`vbmeta_ab`**（`vbmeta.img`）与 **`vbmeta_system_ab`**（`vbmeta_system.img`），**不存在 `vbmeta_vendor` 分区**
  - **引导镜像核实**：`boot.img`（96 MB）、`init_boot.img`（8 MB）、`vendor_boot.img`（96 MB）、`recovery.img`（100 MB）、`dtbo.img`（18 MB）
  - **救砖脚本核实**：包内自带 `flash_all.sh`（默认不锁 BL 并激活 `a` 槽；严禁使用 `flash_all_lock.sh`）
- **源包（iQOO Neo 11 OriginOS 7）实测参数**（通过 ZIP 中央目录与流式解析 `payload.bin` manifest 核验）：
  - 设备与版本：`pre-device=PD2520`、`hardware-device=PD2520MA`、`post-version=PD2520_A_17.1.15.2.W10.V000L1`、`post-sdk-level=37`（Android 17）、安全补丁 `2026-11-01`、`vfs-type=erofs`
  - **Treble Vendor Freeze 核实**（来自 `care_map.pb`）：`system`/`product`/`system_ext` 为 Android 17，`vendor`/`odm`/`vendor_dlkm`/`system_dlkm` 为 Android 15 Vendor Freeze，与 SM8750 底包架构一致
  - **主 `payload.bin` 关键分区体积**：
    - `system`：`10,026,364,928 bytes`（**9,561.89 MiB**）
    - `product`：`408,100,864 bytes`（**389.20 MiB**）
    - `system_ext`：`215,228,416 bytes`（**205.26 MiB**）
    - 系统侧三分区合计：**`10,156.35 MiB`（~9.92 GiB）**
  - **vivo 专属配置分区核实**（位于 `oem_zip/` 嵌套包，不在主 `payload.bin` 内）：
    - `oem_zip/vgc_V000_PD2520MA.zip`（含 `vgc.prop` + 353 KB `payload.bin`）
    - `oem_zip/oem_PD2520_ALL_IN_ONE_02.zip`（含 `oem.prop` + `oem/PD2520_CN-ZH_FULL_SC_NULL/oem.prop` + 4.16 MB `payload.bin`）
    - `oem_zip/dyn_PD2520_NULL.zip`（含 `dyn.prop` + `dyn.new.dat.br`）
- **⚠️ 实包核验发现的关键变更点（已同步修正设计文档）**：
  1. **`super` 分区容量红线预警**：K90 物理 `super` 总上限为 `12.50 GiB`，而 Neo 11 系统三分区原样已占 `9.92 GiB`，加上 K90 `vendor`/`odm`/`dlkm` 后极易逼近或超出上限 → **必须在打包脚本中加入 OriginOS `system` 精简（Debloat）与高压缩 EROFS 参数**。
  2. **AVB 刷写命令修正**：移除不存在的 `vbmeta_vendor`，仅对 `vbmeta` 与 `vbmeta_system` 执行 `--disable-verity --disable-verification`。
  3. **vivo `vgc`/`oem`/`dyn` 解包路径修正**：脚本需从 `oem_zip/` 嵌套包中解出 `vgc_V000_PD2520MA.zip`、`oem_PD2520_ALL_IN_ONE_02.zip`（取公开版 `PD2520_CN-ZH_FULL_SC_NULL`）与 `dyn_PD2520_NULL.zip`，再解内部小型 `payload.bin`。

#### Step 3：仓库安全防护与文档同步
- 新增 [`.gitignore`](.gitignore)：屏蔽 `*.tgz`、`*.zip`、`*.img`、`backups/`、`logs/`、`work/`、`out/`，防止误将 22 GB ROM 或手机基带隐私推送到 GitHub。
- 更新 [`PORTING_GUIDE.md`](PORTING_GUIDE.md)：回填上述 K90 与 Neo 11 实测参数、容量精简策略与修正后的 AVB 命令。
- 新增 [`CHANGELOG.md`](CHANGELOG.md)（本文件）。

#### Step 4：搭建阶段一 GitHub Actions 云端体检流水线（适配 123 网盘）
- **背景**：用户已将 K90 底包与 iQOO Neo 11 源包上传至 123 网盘，下一步先在云端零占本地盘完成精细体检（获取 K90 `super` 精确 `lpdump`、VINTF 差异与 Neo 11 `system` 大体积可精简目录清单），再按实测数据生成阶段二正式打包脚本。
- **新增文件**：
  - [`.github/workflows/01-inspect-roms.yml`](.github/workflows/01-inspect-roms.yml)：支持 `rclone`（123 网盘 WebDAV，凭证走 `RCLONE_CONF` Secret）与 `url`（123 直链 / 官方直链，`aria2c` 16 线程下载）两种拉包模式，自动产出 `< 10 MB` 体检 Artifact 与可视化 Job Summary。
  - [`scripts/00_clean_runner_disk.sh`](scripts/00_clean_runner_disk.sh)：自动清理 Runner 预装冗余工具链（`.NET`/Android SDK/GHC/CodeQL/Docker 镜像），动态挑选剩余空间最大的目录作为 `WORK_ROOT`。
  - [`scripts/01_fetch_rom.sh`](scripts/01_fetch_rom.sh)：统一封装 `rclone` / `aria2c` 拉包，并内置 `< 100 MB` 体积门禁，防止误下载 123 网盘 HTML 分享页或鉴权报错页。
  - [`scripts/lp_tools.py`](scripts/lp_tools.py)：零外部依赖的纯 Python Android `liblp` 工具，完成 K90 `super_raw.img` 的 `lpdump` 与 `lpunpack`。
  - [`scripts/02_inspect_roms.sh`](scripts/02_inspect_roms.sh)：采用“边解边删 + Linux 内核只读 `mount -t erofs -o ro,loop`（零额外解压占盘）”策略，采集 K90 与 Neo 11 的全量 `build.prop`、`fstab`、VINTF XML、`oem_zip/` 嵌套配置、Overlay/APEX 列表、Q2 独显与 `Vivo3rdAlgoService` 路径、`system` 空间占用 Top 120 清单。
  - [`scripts/vintf_diff.py`](scripts/vintf_diff.py)：自动比对 K90 `vendor`/`odm` VINTF 清单与 Neo 11 系统兼容矩阵，筛出所有 `optional="false"` 但 K90 缺失的 HAL。

#### Step 5：切换至零成本“组合 B”传输方案（小米官方 CDN + Hugging Face 私有 Dataset）
- **背景**：123 云盘 WebDAV 与大文件直链均需付费会员，用户确认采用 0 元免费方案 **组合 B**：
  - 红米 K90 底包（`.tgz`）：GitHub Actions 直接通过小米官方 CDN 直链拉取（免上传、千兆直连）。
  - iQOO Neo 11 源包（10 GB `.zip`）及后续成品包：使用 **Hugging Face 私有 Dataset 仓库**（单文件上限 50 GB、免切片、永久有效，私有 Token 存 GitHub Secret `HF_TOKEN`）。
- **代码变更**：
  - 升级 [`scripts/01_fetch_rom.sh`](scripts/01_fetch_rom.sh)：支持**按单包自动识别协议**（`hf://`、HF 网页 resolve 链接、`http(s)://` `aria2c` 直链、`rclone://`），通过官方 `huggingface_hub` 原生处理私有认证与 Xet/LFS 高速下载，规避 S3 302 重定向认证头冲突。
  - 更新 [`.github/workflows/01-inspect-roms.yml`](.github/workflows/01-inspect-roms.yml) 与 [`scripts/02_inspect_roms.sh`](scripts/02_inspect_roms.sh)：默认 K90 底包指向小米官方 CDN 直链，接入 `HF_TOKEN` Secret 拉取 Neo 11 源包，移除多余的全局模式开关。
  - 新增 [`scripts/local_upload_hf.sh`](scripts/local_upload_hf.sh)：macOS 本地一键上传助手，自动创建私有 Dataset 并以分片断点续传上传 10 GB 的 `PD2520A_17.1.15.2W10.V000L1-update-full.zip`（避免浏览器传 10 GB 断流）。

#### Step 6：切换至阿里魔搭 ModelScope 私有数据集（绕开 Hugging Face 风控、国内直连免梯子）
- **背景**：访问 Hugging Face 触发了 AWS WAF 出口 IP 风控拦截，用户决定切换为 **阿里魔搭社区（ModelScope）私有数据集 + 小米官方 CDN 直链**，国内直连无需梯子、单文件免切片、永久免费。
- **代码变更**：
  - 升级 [`scripts/01_fetch_rom.sh`](scripts/01_fetch_rom.sh)：新增 `ms://<魔搭用户名>/<数据集名>/<文件路径>` 与 `modelscope.cn/datasets/...` 链接原生支持（基于轻量官方 SDK `modelscope-hub`，内置 HTTP Range 断点续传、分片并行下载与 SHA256 校验），同时向下兼容 `hf://`、`https://` 与 `rclone://`。
  - 更新 [`.github/workflows/01-inspect-roms.yml`](.github/workflows/01-inspect-roms.yml)：云端安装轻量 `modelscope-hub`（无 PyTorch 体积负担），接入 GitHub Secret **`MODELSCOPE_API_TOKEN`**，源包默认示例更新为 `ms://`。
  - 新增 [`scripts/local_upload_ms.sh`](scripts/local_upload_ms.sh)：针对本机 macOS 系统 Python 3.9.6 做了自动版本检测与兼容处理（Python ≥ 3.10 走 `modelscope-hub`，Python 3.9 自动走 `modelscope` HubApi + 阿里云 PyPI 镜像加速安装）。

#### Step 7：修复魔搭上传 10 GB 单文件 `ConnectionResetError(54)`（自动 2 GB 分片上传与云端流式合并）
- **问题根因**：排查本地 `modelscope/hub/api.py`（`_upload_blob`）发现，Python 3.9 版 SDK 使用单次 HTTP `PUT` 推送整个 10.7 GB 文件（未走分片上传），触发魔搭底层阿里云 OSS 单次 PUT 5 GB 硬上限或网关断连，导致 `ConnectionResetError(54, 'Connection reset by peer')`。
- **修复方案**：
  - 升级 [`scripts/local_upload_ms.sh`](scripts/local_upload_ms.sh)：对 `> 3.5 GB` 的大文件自动按 **2000 MB（2 GB）切片**并计算每片及整体 SHA256，逐片上传至 `parts/`（内置 5 次重试 + 魔搭服务端 SHA256 秒传去重，中断重跑可断点续传），最后上传 `.parts.json` 清单并自动清理本地临时切片。
  - 升级 [`scripts/01_fetch_rom.sh`](scripts/01_fetch_rom.sh)：云端拉取自动识别 `.parts.json` 清单，按片下载 → 校验单片 SHA256 → 流式追加合并后**立即删除临时分片**（零额外峰值占盘）→ 校验整包 SHA256。
  - 更新 [`.github/workflows/01-inspect-roms.yml`](.github/workflows/01-inspect-roms.yml) 默认示例指向 `.parts.json`。
  - 安全加固：在 [`.gitignore`](.gitignore) 中追加屏蔽 `upload.sh`、`*.local.sh`、`.env*`，防止本地含 Token 的启动脚本被误提交到 GitHub。

#### Step 8：首次云端体检跑通 K90 `super` 拆包并修复只读挂载权限退出问题
- **首次云端运行实测成果**（Public 仓库 Runner 实测 145 GB 盘 / 104 GB 剩余空间，小米 CDN + `lp_tools.py` + 内核 EROFS 挂载全数一次通过）：
  - 红米 K90 `OS4.0.6.0.XPKCNXM` `super` 逻辑分区精确体积实测：
    - `odm_a`：**3,164.62 MiB**（小米将绝大部分底层硬件/相机/固件放在 `odm_a`）
    - `vendor_a`：**708.27 MiB**
    - `vendor_dlkm_a`：**53.32 MiB**
    - `system_dlkm_a`：**14.59 MiB**
    - 原厂 `product_a`（5,238.69 MiB）、`system_a`（932.01 MiB）、`system_ext_a`（778.64 MiB）、`mi_ext_a`（162.89 MiB）、`mi_product_a`（0.33 MiB）
  - **关键容量结论**：K90 必须保留的底层 4 分区合计 **`3,940.80 MiB`（~3.85 GiB）**，留给 OriginOS 7 三分区（`system`+`product`+`system_ext`）的实际安全上限约 **`8,850 MiB`（~8.64 GiB）**；而 Neo 11 原包三分区为 `10,156.35 MiB`（~9.92 GiB），**确认后续必须精简 ≥ 1.4~1.8 GiB 预装非核心内容**。
- **问题修复**：[`scripts/02_inspect_roms.sh`](scripts/02_inspect_roms.sh) 在挂载 `k90_vendor` 后以非 root 权限执行 `find`，触发 EROFS 内 `0700 root` 目录返回码 1 并被 `set -euo pipefail` 中断；已统一改为 `sudo find`/`sudo cat`/`sudo cp`，对所有管道（含 `head` 的 SIGPIPE）加容错保护，并在上传 Artifact 前自动 `chown`/`chmod` 与增加 `trap` 清理挂载。

#### Step 9：优化魔搭跨洋拉包并发提速（6 路并行）并新增 GitHub Release 内网极速源支持
- **现象**：美国 GitHub Actions Runner 串行单分片拉取国内魔搭 OSS 速度仅约 `1.3~1.8 MB/s`，6 片串行耗时约 100+ 分钟，存在超过原 `90` 分钟超时上限的风险。
- **优化**：
  - 升级 [`scripts/01_fetch_rom.sh`](scripts/01_fetch_rom.sh)：
    - 魔搭 `.parts.json` 改为 **`ThreadPoolExecutor(max_workers=6)` 6 路并发拉取**，充分利用跨洋多 TCP 并发带宽将总耗时压至约 15~25 分钟；
    - 新增 **`gh-release://<owner>/<repo>/<tag>/<asset>`** 协议支持（自动兼容 `.parts.json` 分卷并行下载与 SHA256 校验），便于后续把源包转存到 GitHub 私有 Release 实现 **~20 秒内网秒拉**。
  - 将 [`.github/workflows/01-inspect-roms.yml`](.github/workflows/01-inspect-roms.yml) 的 `timeout-minutes` 提高至 `180`，并注入 `STORAGE_GH_TOKEN` / `GITHUB_TOKEN`。

#### Step 10：阶段一云端双包深度体检完成，实测结论全面落盘
- **执行结果**：`01 - Inspect K90 & Neo 11 ROMs` 全流程成功，已将完整体检报告 `k90-neo11-inspection-report`（235 份清单/VINTF/Prop/fstab/空间数据）拉回本地分析。
- **核心兼容性结论（高度乐观）**：
  1. **Treble / VINTF / SEPolicy 完美对齐**：K90 `vendor`/`odm` 为 `target-level="202404"`（Android 15 GRF / SDK 35，`sepolicy=202404`）；Neo 11 `system` 完整内置 `compatibility_matrix.202404.xml` 与 `system-sdk 29~37`，且 K90 `vendor/compatibility_matrix.xml` 要求的 3 项框架 HAL Neo 11 全部原生提供；Android 17 VINTF v9.0 矩阵默认省略 `optional`（全可缺省），不会因缺失 vivo 私有 HAL 硬阻断开机。
  2. **底层硬件 HAL 高度一致**：同为 `SM8750`（`sun`），K90 原厂已提供全套标准 AIDL HAL（`biometrics.fingerprint` v4 高通 QFP 超声波、`biometrics.face` v4、`camera.provider` v2 `vendor_qti/0`、`graphics.composer3` v3、`audio.core`/`effect`、`vibrator` `qcom-haptics`、`radio.*`、`wifi`/`bluetooth`/`sensors`/`gnss`），甚至 **两机 NFC 芯片型号完全一致（均为 NXP `SN220` / `SN220T`）**；且两机均内置 **`tango` 32 位二进制转译器**，64-bit-only `vendor` 下 32 位应用可原生兼容。
  3. **EROFS 格式完全一致**：双机全部分区均为 `4096B` 块、`lz4_0padding`、`sb_csum mtime xattr_filter`（Linux 5.4+ 兼容），打包直接用 `mkfs.erofs -zlz4hc,9` 即可原生挂载。
  4. **K90 实测屏幕与超声波指纹几何参数**：
     - 屏幕分辨率与密度：`1156×2510`、`480 dpi`（`persist.sys.miui_resolution=1156,2510,480`，与 Neo 11 默认 `ro.sf.lcd_density=480` 一致）；
     - 屏下超声波指纹坐标：`X_Y=504,1831`，`size=148×148`，`us.target=495,1814,660,1995`；
     - 显示配置文件：`/vendor/etc/displayconfig/` 下 4 份随底包保留，另需把 K90 `/product/etc/displayconfig/display_id_4630947238302509459.xml` 迁入移植 `product`。
- **提前捕获的 5 个关键踩坑点（将在阶段二构建脚本中逐一处理）**：
  1. **容量问题彻底有解**：Neo 11 `/system/custom/app` 独占 **`2,262 MiB`**（`/system/custom/priv-app` 另占 `190 MiB`），仅清理 `/system/custom/app` 预装第三方包即可立省 **~2.26 GiB**，叠加清空无用的 `mi_ext_a`（省 `163 MiB`），最终 `super` 总占用约 **`11.3~11.6 GiB` < `12.49 GiB`**，留有 ~1 GiB 安全余量。
  2. **防 K90 `mi_ext` Overlay 劫持**：K90 `vendor/etc/fstab.qcom` 会将 `mi_ext` 以 `overlay` 叠挂到 `/system/app`、`/system/priv-app`、`/product/overlay`、`/system/etc/permissions`（均带 `nofail`）。打包 `super.img` 时必须把 `mi_ext_a` / `mi_product_a` 替换为空 EROFS 镜像，防止小米残留包污染 OriginOS。
  3. **补齐 `/oem` 与 `/vgc` 虚拟目录**：Neo 11 `system/build.prop` 尾部执行 `import /oem/oem.prop` 与 `import /vgc/vgc.prop`，但 K90 `fstab.qcom` 无独立 `oem`/`vgc` 分区；由于 SAR 架构下 `system.img` 根目录即 `/`，且内部已预建 `/oem` 与 `/vgc` 目录，只需将 `vgc_V000_PD2520MA.zip` 与 `oem_PD2520_ALL_IN_ONE_02.zip`（选用 `PD2520_CN-ZH_FULL_SC_NULL` 全网通公开版）解包灌入 `system` 根下的 `/vgc` 与 `/oem` 目录即可原生生效。
  4. **禁用 Neo 11 Q2 独显/144Hz 私有属性并校准 Codec2**：清除 `persist.vivo.displayic.*`（`iQOO0301` Q2 独显）与 `persist.sys.private_fps=144`（对齐 K90 120Hz），并将 `debug.stagefright.ccodec` 由 `1` 对齐 K90 `vendor` 的 `4`（AIDL Codec2）。
  5. **首版调试直连保障**：在首版 `system/build.prop` 放行早期 ADB 调试（`ro.adb.secure=0`、`persist.sys.usb.config=mtp,adb`），且保留 `JoviIme` 输入法防止精简后无键盘可用；EROFS 重打包全程严格保留原文件 UID/GID、mode、`security.selinux` 与 `security.capability` 扩展属性。

#### Step 11：阶段二云端构包全套代码 + 一次性 GitHub Release 极速中转 Workflow 落盘
- **新增设备配置与补丁规则**：
  - [`config/device_annibale.env`](config/device_annibale.env)：锁定 K90 `super` 动态组上限（`13,411,287,040 B`）、原厂保留分区字节数（`4,132,216,832 B`）、`64 MiB` 安全裕量、K90 `product` 显示配置 XML 路径与 Neo 11 零售版 OEM 变体（`PD2520_CN-ZH_FULL_SC_NULL`）。
  - [`config/remove_list.txt`](config/remove_list.txt)：清理 `/system/custom/app/*`（立省 ~2.26 GiB）、移除冲突包 `Vivo3rdAlgoService`、`vibrator4d` 与防误更 `Updater`/`COTA`。
  - [`config/prop_override.conf`](config/prop_override.conf)：剔除 Q2 独显与 144Hz 私有属性，校准 Codec2 AIDL（`debug.stagefright.ccodec=4`）、基带网络制式（`33,33`）、120Hz / 480dpi，并提供首版 `debug_adb` 早期免授权调试与禁 RescueParty 规则。
- **新增核心构建、无损 EROFS 与云端传输脚本**：
  - [`scripts/erofs_repack.py`](scripts/erofs_repack.py)：无损复制挂载的 EROFS 分区（完整保留 UID/GID、mode、硬链接、`security.selinux`、`security.capability`），提供缺失标签自动修复与打包后回挂载校验门禁（要求 `≥99.9%` SELinux 标签覆盖率）。
  - [`scripts/patch_props.py`](scripts/patch_props.py)：原地修改 `build.prop` 并保留原文件权限与 SELinux xattr。
  - [`scripts/03_patch_port.sh`](scripts/03_patch_port.sh)：阶段二主构建脚本（支持 `full` 首次全套分区包与 `system_only` 极速单分区迭代模式）；自动将 Neo 11 `/vgc` 与扁平化后的 `/oem/oem.prop` 灌入 SAR `system` 根，迁入 K90 `display_id_4630947238302509459.xml`，生成防劫持空 `mi_ext.img`/`mi_product.img`，执行 `super` 容量硬门禁校验，并内置生成带 SHA256 自检、设备校验与安全先缩后刷逻辑的 macOS `fastbootd` 刷机脚本 `flash_port_mac.sh`。
  - [`scripts/05_upload_ms.sh`](scripts/05_upload_ms.sh) & [`scripts/local_download_ms.sh`](scripts/local_download_ms.sh)：云端 `zstd` 压缩并自动 `2000 MiB` 分卷 + SHA256 清单回传魔搭私有数据集；macOS 本地一行命令 6 路并发拉回、校验合并并解压。
- **新增两条 GitHub Actions Workflows**：
  - [`.github/workflows/00-mirror-to-gh-release.yml`](.github/workflows/00-mirror-to-gh-release.yml)：一次性把魔搭 6 个源包分卷云端中转到私有 GitHub 仓库 Release，后续所有阶段二构包拉 10 GB 源包可从 ~20 分钟缩短至 **~20 秒**。
  - [`.github/workflows/02-build-port.yml`](.github/workflows/02-build-port.yml)：阶段二正式云端构包 Workflow，输出 `fastbootd` 独立分区刷机包至魔搭，并产出轻量 `k90-originos7-build-report` Artifact（含容量表、SELinux 回检日志、`/system/custom/app` 实际清单、vivo `init.rc` 原始片段与 `flash_port_mac.sh` 副本）。
- **`.gitignore` 补充**：忽略 `k90-neo11-inspection-report/`，避免将 235 份本地解压的体检原始文件推入公开仓库。

#### Step 12：开机链路深度防变砖审计——新增实机级 `secilc` 跨厂 SEPolicy 编译门禁与 4 项加固
- **排查出的 4 项潜在开不了机隐患及修复**：
  1. **跨厂 SEPolicy 合并编译崩溃风险（最致命隐患）**：Android `init` 二阶段会用 `/system/bin/secilc` 将 Neo 11（`system`+`system_ext`+`product`）与 K90（`vendor`+`odm`）的 `.cil` 策略合编；若 K90 `vendor_sepolicy.cil` / `odm_sepolicy.cil` 引用了小米私有平台类型而 Neo 11 缺失，`secilc` 报错会令 `init` 在 `adbd` 启动前直接重启。
     - **加固**：新增 [`scripts/check_sepolicy.py`](scripts/check_sepolicy.py)，并在 [`scripts/03_patch_port.sh`](scripts/03_patch_port.sh) 与 [`.github/workflows/02-build-port.yml`](.github/workflows/02-build-port.yml) 中接入真实 `secilc -m -M true -G -N -c 30` 预演门禁——从 K90 底包提取真实 `vendor`/`odm` SELinux CIL，与 Neo 11 策略联合试编；若发现 K90 `vendor`/`odm` 依赖的小米缺失类型/属性，自动向 `mapping/202404.cil` 注入最小兼容声明并复测至 `secilc` 退出码 `0`，所有补丁明细输出至 `sepolicy_check.txt`。
  2. **`fastbootd` 缩容保留原分区组**：将 `flash_port_mac.sh` 中对旧分区先删后建（`delete`+`create` 可能落入 `default` 分区组）升级为优先执行 `fastboot resize-logical-partition "${p}_${SLOT}" 0`，完整保留 K90 原生 `qti_dynamic_partitions_${SLOT}` 组元数据。
  3. **`/adb_keys` SELinux 扩展属性尾空字节一致化**：移除 `setfattr` 调用，统一改用 Python `os.setxattr` 写入带 `\x00` 结尾的原生 EROFS SELinux 标签。
  4. **高危 `init.rc` 审计**：在构建报告中自动输出 `neo11_critical_rc_audit.txt`，抓取 Neo 11 `/system/etc/init/` 中所有 `critical`/`reboot`/`mount` 声明以及 `securemount.rc`、`/vgc/vgc.rc` 全文，供刷机前终审。

#### Step 13：全仓脚本与 Workflow 二轮逐行代码复核（修复 6 项隐性缺陷）
- **排查并修复的具体问题**：
  1. **`scripts/check_sepolicy.py` 返回值解包崩溃 & CIL 规则覆盖补齐**：修复 `find_missing_tokens_on_line()` 在文件/行号越界早退时返回 `[]` 而非 `([], "")` 导致的 `ValueError` 解包崩溃；补全 `allowx`/`dontauditx` 与 `genfscon` 语句的缺失类型提取。
  2. **`scripts/03_patch_port.sh` root 挂载目录检测与 `set -e` 安全加固**：将挂载 EROFS / root 暂存树上的非特权 `[[ -f/-d/-e ]]` 及 `[[ -d ... ]] && cp` 统一改为 `if sudo test -d/-f/-e ...; then ...; fi`；将多处双引号内嵌 `python3 -c` 改为 `sys.argv` / 单引号 heredoc 传参，消除转义与路径注入隐患。
  3. **`scripts/03_patch_port.sh` `/oem/oem.prop` 扁平化防御性修复**：写入 `ro.vivo.default.oem.name` 前补齐 `if key not in kv: order.append(key)`，防止基础文件缺键时属性漏写。
  4. **`flash_port_mac.sh` 刷机状态机加固**：若用户启动脚本时手机已处于 `fastbootd`，刷写 `vbmeta`/`vbmeta_system` 前先自动 `fastboot reboot bootloader` 切回 Bootloader 模式关闭 AVB，再切入 `fastbootd` 并强断言 `is-userspace == yes` 后才执行逻辑分区缩容与刷写。
  5. **`.github/workflows/00-mirror-to-gh-release.yml` 两项防翻车加固**：
     - 在耗时约 20 分钟的魔搭拉取**之前**增加 2 秒前置检查（校验 `STORAGE_GH_REPO` 非空仓库与 `STORAGE_GH_TOKEN` 的 Release 写权限），配置有误时秒级报错，避免白等 20 分钟；
     - 改用临时文件传递 `MANIFEST_NAME`，避免 `modelscope_hub` 向 `stdout` 输出日志污染命令替换结果。
  6. **全量静态校验通过**：对全部 8 个 `.sh`、内嵌 133 行 `flash_port_mac.sh`、全部 5 个 `.py`（AST 解析）及全部 3 个 GitHub Actions `.yml` 完成语法与格式复核。

#### Step 14：三轮实机链路深度复核（对照 K90 `fstab.qcom` / `super` / `build.prop` 实测数据修复 6 项深层缺陷）
- **排查并修复的具体问题**：
  1. **`scripts/03_patch_port.sh` 致命权限清理缺陷（高危）**：`secilc` 门禁结束后执行 `rm -rf "$WORK_ROOT/neo11_sepolicy" "$WORK_ROOT/k90_sepolicy"` 漏加 `sudo`，而该目录由 `sudo cp -r` 创建、属主为 `root:root`，会导致构建在 `secilc` 通过后因 `Permission denied` 中断；已修正为 `sudo rm -rf`，并在 `EXIT` trap（`cleanup_mounts`）中增加对 `$REPORT_DIR` 的自动 `chown`，确保即使中途失败报告也可完整上传。
  2. **K90 `fstab.qcom` `/product/vm-system` 缺失挂载点修复**：对照 K90 实测 `vendor/etc/fstab.qcom` 第 97 行发现 `vm-bootsys -> /product/vm-system`（无 `nofail` 标记），而 Neo 11 `product.img` 不含 `/product/vm-system` 目录；现于 Phase D 在只读 EROFS 打包前主动创建 `0755 root:root`、`u:object_r:system_file:s0` 的 `/product/vm-system` 空挂载点。
  3. **`.github/workflows/02-build-port.yml` 1 秒前置 Secret 校验**：在安装工具与拉包前先校验 `PORT_ROM_SOURCE` / `STORAGE_GH_TOKEN` / `MODELSCOPE_API_TOKEN` / `MS_OUTPUT_REPO` 组合完整性，杜绝切完 `gh-release://` 后漏填 `MS_OUTPUT_REPO` 导致跑完 15 分钟打包才在上传阶段报错。
  4. **`system_only` 增量构建 SEPolicy Shim 持久化机制**：支持可选仓库跟踪文件 `config/sepolicy_shims.cil`，在 `full` 与 `system_only` 两种模式下均会注入 `mapping/202404.cil`，避免首版 `full` 产出的跨厂 SELinux 兼容垫片在后续 `system_only` 快速构建时丢失。
  5. **属性与去臃肿闭环补齐**：在 `config/prop_override.conf` 补充关闭 `ro.vivo.vivo4dgamevib.enable=0` 与 `ro.vivo.cota.enable=0`（与移除 `vibrator4d`/`COTA`/`Updater` 一致）；在 `debug_adb=true` 时若 Neo 11 含 `/system/etc/prop.default` 则同步覆写 `ro.adb.secure`/`ro.debuggable`，防止写一次属性提前锁死；将 `remove_list.txt` 解析重构为纯 Bash 通用函数 `apply_remove_list`，同时支持 `[system]` 与 `[product]`。
  6. **`flash_port_mac.sh` 清除数据兜底**：若 `fastboot -w` 在 `fastbootd` 下失败，自动回退执行 `fastboot erase metadata && fastboot erase userdata`（K90 `fstab.qcom` 均标有 `formattable`，首次开机自动按原生 F2FS + `inlinecrypt` 参数重建）。
  7. **修复 `00-mirror-to-gh-release.yml` 第 84 行 YAML 缩进语法错误**：将原先内联在 YAML `run: |` 块中未缩进的 Python heredoc 拆分为独立脚本 [`scripts/00_mirror_ms_to_gh.py`](scripts/00_mirror_ms_to_gh.py)，并使用 macOS 原生 Ruby `YAML.load_file`（Psych 解析器）复验全部 3 个 Workflow YAML 语法全部通过。
  8. **修复 `scripts/03_patch_port.sh` 嵌套解包误选 `vbmeta_vgc.img`/`vbmeta_oem.img`**：`vgc_*.zip` 与 `oem_*.zip` 的 `payload.bin` 内均同时包含分区镜像与对应 `vbmeta_*.img`，原 `find -name '*.img' | head -n 1` 命中了 `vbmeta_*` 导致 `mount -t erofs` 报退出码 `32`；已改为指定 `-p vgc` / `-p oem` 提取并精确匹配 `vgc.img`、`oem.img`（排除 `vbmeta*`）。
  9. **防宿主机 `secilc` 版本代差误杀 + 挂载/通配符细节加固**：`scripts/check_sepolicy.py` 在校检 `Neo 11 + K90` 前先用纯原厂 K90 五分区 CIL 做 0.3 秒基线自校（若 Ubuntu 24.04 自带 `secilc 3.5` 连原厂 Android 17 CIL 语法都不支持，则输出警告并跳过硬拦截，避免误杀）；`mount_erofs_ro` 增加 `-o ro,loop` 自动文件系统兜底；修复 `sudo du -sm .../*` 非 root shell 展开通配符问题，并在 `mkfs.erofs` 前清理同名旧镜像。

---

## 待补操作清单（Pending / Next Steps）

以下为尚未执行、需要逐步补齐的操作项（每完成一项将移入上方正式记录并标注日期与结果）：

### A. 仓库与阿里魔搭 ModelScope 对接
- [x] **A1. 提交代码并推送到 GitHub 远端**（已完成，Public 仓库）。
- [x] **A2. 准备魔搭 ModelScope 私有数据集与 Token 并上传 Neo 11 源包**（已完成，6 路分卷上传完毕）。
- [x] **A3. 在 GitHub Actions 运行 `01 - Inspect K90 & Neo 11 ROMs` 并回收报告**（已完成，见 Step 10）。
- [ ] **A4. （强烈推荐）可选一次性镜像转存**：将魔搭 6 个分卷云端中转至 GitHub 私有 Release，使后续所有阶段二构包拉取 Neo 11 从 ~20 分钟缩短至 ~20 秒。
- [ ] **A5. 本地 macOS 补装轻量工具**：按需安装 `zstd`（`brew install zstd`，用于后续解压成品包）。

### B. 手机端前置安全备份（刷机前强制项）
- [ ] **B1. 确认红米 K90 已解锁 BL 并刷至 HyperOS 4（`OS4.0.6.0.XPKCNXM`）底包**。
- [ ] **B2. 留档 Fastboot 变量**：执行 `fastboot getvar all > backups/k90_fastboot_vars.txt 2>&1`，确认当前活跃槽位。
- [ ] **B3. 备份不可再生分区**：Root 下 `dd` 备份 `persist`、`modemst1`、`modemst2`、`fsg`、`fsc`、`devinfo` 到 `backups/` 并校验 `SHA256SUMS`。
- [ ] **B4. 本地预解压一份 K90 救砖线刷包**（独立于 Git 目录外），确保随时可执行 `flash_all.sh` 一键救砖。

### C. 阶段二正式打包脚本建设
- [x] **C1. 编写 `01-inspect-roms.yml` 与全套体检脚本**（已完成，见 Step 4）。
- [x] **C2. 根据体检报告落盘 `config/` 与核心脚本**（已完成，见 Step 11：`device_annibale.env`、`remove_list.txt`、`prop_override.conf`、`erofs_repack.py`、`patch_props.py`、`03_patch_port.sh`、`05_upload_ms.sh`、`local_download_ms.sh`）。
- [x] **C3. 编写 `00-mirror-to-gh-release.yml` 与 `02-build-port.yml`**（已完成，见 Step 11）。
- [ ] **C4. 按需补充阶段三精细化 RRO 适配包**：根据首版实机运行效果，视需要提取 K90 挖孔/圆角/自动亮度曲线/电池配置打成轻量 `K90OriginOverlay.apk`。

### D. 刷机点亮与迭代排障
- [ ] **D1. 准备 K90 原厂 `init_boot.img`/`boot.img` 的 Root + 调试期 SELinux Permissive 方案**。
- [ ] **D2. 首次灰度验证**：优先 DSU Sideloader 无损试跑，或 `fastbootd` 刷入实验槽 + 禁用 `vbmeta`/`vbmeta_system` + `fastboot -w`。
- [ ] **D3. 抓取首轮 `logcat` / `dmesg` 并逐项修复**：开机引导 → 联网/vivo 账号 → 显示/刷新率/亮度 → 屏下指纹 → 相机/相册 → 线性马达 → 音频/NFC/蓝牙 → SELinux 回归 Enforcing & 关闭调试开关。
