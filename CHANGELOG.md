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

---

## 待补操作清单（Pending / Next Steps）

以下为尚未执行、需要逐步补齐的操作项（每完成一项将移入上方正式记录并标注日期与结果）：

### A. 仓库与阿里魔搭 ModelScope 对接（立即可做）
- [ ] **A1. 提交代码并推送到 GitHub 远端**（优先推荐建 **Public** 仓库以获得 4 核 + 150 GB 大盘 + 无限时长；确认两个大包已被 `.gitignore` 屏蔽）。
- [ ] **A2. 准备魔搭 ModelScope 私有数据集与 Token（国内直连免梯子）**：
  - 登录 [魔搭社区](https://modelscope.cn/datasets/create) 创建一个 **非公开（私有）数据集**（如 `<你的魔搭用户名>/redmi-k90-roms`）。
  - 在 [魔搭访问令牌页](https://modelscope.cn/my/myaccesstoken) 获取具备 **读写权限** 的 SDK Token。
  - 在 macOS 运行 `bash scripts/local_upload_ms.sh <魔搭用户名>/redmi-k90-roms PD2520A_17.1.15.2W10.V000L1-update-full.zip` 上传 10 GB 源包（K90 底包无需上传，Actions 直接免费拉取小米官方 CDN）。
  - 在 GitHub 仓库 `Settings → Secrets and variables → Actions` 新增 Secret：**`MODELSCOPE_API_TOKEN`**。
- [ ] **A3. 在 GitHub Actions 运行 `01 - Inspect K90 & Neo 11 ROMs`**，下载 `k90-neo11-inspection-report` Artifact 并交给下一阶段分析。
- [ ] **A4. 本地 macOS 补装轻量工具**：按需安装 `zstd`（`brew install zstd`，用于后续解压成品包）。

### B. 手机端前置安全备份（刷机前强制项）
- [ ] **B1. 确认红米 K90 已解锁 BL 并刷至 HyperOS 4（`OS4.0.6.0.XPKCNXM`）底包**。
- [ ] **B2. 留档 Fastboot 变量**：执行 `fastboot getvar all > backups/k90_fastboot_vars.txt 2>&1`，确认当前活跃槽位。
- [ ] **B3. 备份不可再生分区**：Root 下 `dd` 备份 `persist`、`modemst1`、`modemst2`、`fsg`、`fsc`、`devinfo` 到 `backups/` 并校验 `SHA256SUMS`。
- [ ] **B4. 本地预解压一份 K90 救砖线刷包**（独立于 Git 目录外），确保随时可执行 `flash_all.sh` 一键救砖。

### C. 阶段二正式打包脚本建设（待 A3 体检报告产出后精准编写）
- [x] **C1. 编写 `01-inspect-roms.yml` 与全套体检脚本**（已完成，见 Step 4）。
- [ ] **C2. 根据体检报告落盘 `config/` 与 `patches/`**：
  - `config/device_annibale.env`（精确 `super` 元数据与分区字节上限）
  - `config/remove_list.txt`（`Vivo3rdAlgoService`、Q2 独显强绑定服务、超容量预装第三方 App 精简列表）
  - `config/prop_override.conf`（合并 `vgc.prop`/`oem.prop`/`dyn.prop` + 品牌伪装 + 禁改白名单）
  - `config/vintf_relax.json`（放宽 K90 缺失的 vivo 私有 HAL 强依赖）
  - `patches/overlays/`（K90 2K `1440×3200` / 挖孔 / 圆角 / 亮度 / 6500mAh 电池 RRO）
- [ ] **C3. 编写 `02-build-port.yml` 与正式构建脚本**：实现清盘、边解边删、自动打补丁、EROFS 打包、容量与挂载门禁自检、并自动免切片上传成品 ROM 至 Hugging Face 私有 Dataset（可选同步发 GitHub Release 1.9 GB 分卷）。

### D. 刷机点亮与迭代排障
- [ ] **D1. 准备 K90 原厂 `init_boot.img`/`boot.img` 的 Root + 调试期 SELinux Permissive 方案**。
- [ ] **D2. 首次灰度验证**：优先 DSU Sideloader 无损试跑，或 `fastbootd` 刷入实验槽 + 禁用 `vbmeta`/`vbmeta_system` + `fastboot -w`。
- [ ] **D3. 抓取首轮 `logcat` / `dmesg` 并逐项修复**：开机引导 → 联网/vivo 账号 → 显示/刷新率/亮度 → 屏下指纹 → 相机/相册 → 线性马达 → 音频/NFC/蓝牙 → SELinux 回归 Enforcing & 关闭调试开关。
