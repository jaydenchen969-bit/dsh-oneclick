# dsh-oneclick

把 YG 现在这台机器的 DeepSeek Harness 环境，压成**一条命令可重建**的安装包。
换电脑（Windows 或 macOS）从零开始，装完就是现在这套：同一个 dsh 版本、同一套
purge 清洗、同一份提示词与 profile 配置、升级被焊死。

```
Windows :  irm https://raw.githubusercontent.com/jaydenchen969-bit/dsh-oneclick/main/bootstrap.ps1 | iex
macOS   :  curl -fsSL https://raw.githubusercontent.com/jaydenchen969-bit/dsh-oneclick/main/bootstrap.sh | bash
```

装完打开：`dsh-lock web`（浏览器 `http://127.0.0.1:19387`）或桌面壳 `DeepSeek Harness`。

---

## 1. 锁定的版本栈

| 组件 | 版本 | 说明 |
|---|---|---|
| `@deepseek-ai/dsh` | **0.2.2-rc.5** | npm latest，内核锁定 |
| `dsh-purge` | **1.1.71** | 82 条清洗补丁，装完自动 `--apply` |
| DeepSeek Harness 桌面壳 | **0.2.0-rc.2** | Electron 窗口（可选轨道） |
| Node | **24.21.0** | 便携版，装在安装根目录，不动系统 Node |
| pnpm | **11.7.0** | profile 依赖用 |
| Python | **3.12.14** | 仅桌面壳自带 runtime 内有（office 技能用） |
| profile | `desktop` | `~/.dsh/profiles/desktop` |

全部版本写在 [`manifest.json`](manifest.json)，安装器只认这份文件。

---

## 2. 安装方式

### 2.1 联网一键（推荐）

```powershell
# Windows（PowerShell 5.1+ 或 pwsh 7）
irm https://raw.githubusercontent.com/jaydenchen969-bit/dsh-oneclick/main/bootstrap.ps1 | iex
```

```bash
# macOS
curl -fsSL https://raw.githubusercontent.com/jaydenchen969-bit/dsh-oneclick/main/bootstrap.sh | bash
```

默认 `-Mode desktop`：桌面壳 + CLI 运行时。只要 CLI + 网页版：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/jaydenchen969-bit/dsh-oneclick/main/bootstrap.ps1))) -Mode cli
```

```bash
curl -fsSL .../bootstrap.sh | bash -s -- --mode cli
```

### 2.2 全离线（没有任何网络）

在能上网的机器上到 [Releases](../../releases) 把资产全下下来，放到 `assets\`，
整包拷到新机器，然后：

```powershell
.\install.cmd -Offline -Assets .\assets
```

```bash
./install.sh --offline --assets ./assets
```

离线安装**不需要**访问 npm registry、nodejs.org 或 GitHub。

### 2.3 参数

| Windows | macOS | 作用 |
|---|---|---|
| `-Mode desktop\|cli` | `--mode desktop\|cli` | 是否装桌面壳 |
| `-Root DIR` | `--root DIR` | 安装根（node/prefix/cache） |
| `-DshHome DIR` | `--dsh-home DIR` | dsh 家目录，默认 `~/.dsh` |
| `-Assets DIR` | `--assets DIR` | 本地资产目录（离线） |
| `-Offline` | `--offline` | 禁止一切下载 |
| `-Force` | `--force` | 版本一致也重装 |
| `-DryRun` | `--dry-run` | 只打印计划 |
| `-DesktopDir` | — | 桌面壳安装目录（默认 `D:\dsh` 或 `%LOCALAPPDATA%\Programs`） |
| `-RouterBase` | `--router-base` | 写进 `DSH_ROUTER_BASE` |
| `-RouterKey` | `--router-key` | 写进 `DS9700_API_KEY` |

---

## 3. 安装器到底做了什么

1. **预检**：系统版本、磁盘、已有安装探测。
2. **备份**：`~/.dsh`（跳过 cache/sessions/storages）→ `<Root>\backups\dsh-home-<时间戳>`。
3. **Node 便携版**：解压到 `<Root>\node`，不碰系统 Node、不改全局 registry。
4. **离线 npm cache**：`<Root>\npm-cache`（含 Windows + macOS 双平台二进制）。
5. **装包**：`dsh@0.2.2-rc.5`、`pnpm@11.7.0`、`dsh-purge@1.1.71` → `<Root>\npm`。
6. **部署 dsh home**：
   - `prompt-inject.md`（你的系统提示词）
   - `profiles/web/cordis.patch.yml` ← 用户层补丁（模型列表 / 默认模型 / UI / MCP）。`web` 是 dsh 内置 profile，CLI 与网页版都跑它，所以这条永远部署。
   - `profiles/desktop/*`（`-Mode desktop`）：`cordis.yml` + 补丁 + `package.json` + `vendor/dsh-purge`。注意 `desktop` profile 由 Electron 独占，CLI 无法直接启动它（`dsh` 会报 "managed exclusively by the Electron application"），这是官方设计，不是装坏了。
7. **MCP 探测**：`tools/gen-mcp.mjs` 扫描本机实际存在的 MCP 服务（crm-lan-ci / github-review / magpie / aoci / chrome-devtools / ida / shadcn），只把能用的写进 `cordis.patch.yml`（desktop 与 web 两份都写），换机不会因为路径不存在而启动失败。
8. **profile 依赖**：`pnpm install`（`nodeLinker: hoisted`）。
9. **清洗**：`dsh-purge --apply`，日志在 `<Root>\logs\purge-apply.log`。
10. **桌面壳**（`-Mode desktop`）：静默安装 → 禁用自动更新 → 预置离线 runtime（Windows）。
11. **锁版本**：写 `~/.dsh/.lock/versions.json` + `PINNED.txt`，生成 `dsh-lock` 守卫启动器。
12. **环境变量**：`DSH_HOME` / `DSH_PROFILE` / `DSH_ROUTER_BASE` + PATH。
13. **自检**：`dsh --version`、profile YAML 语法（dsh 自带 js-yaml）、`--profile web --dump-config` 合成、purge 补丁计数。

---

## 4. 禁止升级（三层）

| 层 | 做法 | 位置 |
|---|---|---|
| 桌面壳 | `resources/app-update.yml` → `.disabled` | 安装时 + `verify` 检查 |
| dsh 内核 | 版本写入 lock；`dsh-lock` 启动时比对，漂移告警；`dsh-lock --repair` 用离线 cache 回滚 | `~/.dsh/.lock/versions.json` |
| profile 依赖 | `pnpm-workspace.yaml` + `nodeLinker: hoisted`，依赖走 vendored 目录 | `~/.dsh/profiles/desktop` |

**不要**手动跑 `npm i -g @deepseek-ai/dsh@latest` —— 一旦跑了：

```
<Root>\bin\dsh-lock --repair        # 离线回滚到 0.2.2-rc.5
```

随手体检：

```
<Root>\tools\verify.cmd             # Windows
~/.dsh-oneclick/bin/dsh-oneclick-verify   # macOS
```

---

## 5. 换电脑 checklist

- [ ] 新机跑一键命令（或离线 `install.cmd -Offline -Assets .\assets`）
- [ ] `verify` 全绿
- [ ] 填 API key：`setx DS9700_API_KEY "..."`（或改 `DSH_ROUTER_BASE` 指向可达的路由）
- [ ] 桌面壳首次启动 → 等 runtime 就绪（Windows 已预置，mac 需联网取一次）
- [ ] `dsh-lock web` 打开 GUI，确认模型列表与现在一致

> **profile 说明**：`desktop` profile 由 Electron 独占，CLI 不能启动它；CLI/网页版跑的是 dsh 内置的
> `web` profile + 你的补丁层（`~/.dsh/profiles/web/cordis.patch.yml`）。两套配置来自同一份
> `payload/dsh-home/profiles/desktop/cordis.patch.yml`，模型列表和 MCP 完全一致。

> **路由注意**：默认 `DSH_ROUTER_BASE=http://192.168.110.45:3425/v1` 是局域网地址。
> 新机器不在同一网段时，把它改成可达地址，或切到 `deepseek-account` +
> `DEEPSEEK_API_KEY`。

---

## 6. 仓库结构

```
install.ps1 / install.sh        主安装器（幂等、可回滚）
install.cmd                      Windows 双击入口
bootstrap.ps1 / bootstrap.sh     一行命令引导（下载仓库 → 调安装器）
manifest.json                   锁定版本 + 资产映射（唯一事实来源）
payload/dsh-home/               ~/.dsh 的落地内容
  prompt-inject.md              你的系统提示词
  profiles/desktop/             cordis.yml / cordis.patch.yml / package.json
  lock/versions.json            版本锁模板
payload/vendor/dsh-purge/       dsh-purge 1.1.71 源码（随仓库走，不依赖网络）
tools/gen-mcp.mjs               MCP 探测与 patch 生成
tools/dsh-lock.ps1              守卫启动器
tools/verify.ps1 / verify.sh    体检
tools/uninstall.ps1             卸载（保留数据）
scripts/build-assets.ps1        在源机器上构建 Release 资产
.github/workflows/ci.yml        结构校验（不构建二进制）
```

Release 资产（不上仓库，走 Release）：

| 资产 | 约体积 |
|---|---|
| `dsh-npm-cache-0.2.2-rc.5.tar` | 345 MB |
| `node-v24.21.0-win-x64.zip` | 30 MB |
| `node-v24.21.0-darwin-arm64.tar.gz` | 48 MB |
| `node-v24.21.0-darwin-x64.tar.gz` | 50 MB |
| `DeepSeekHarness-0.2.0-rc.2-win-x64.exe` | 276 MB |
| `DeepSeekHarness-0.2.0-rc.2-mac-arm64.dmg` | 353 MB |
| `DeepSeekHarness-0.2.0-rc.2-mac-x64.dmg` | 369 MB |
| `dsh-runtime-0.2.0-rc.2-win32-x64.tar.gz` | ~200 MB |
| `dsh-purge-1.1.71.tgz` | 1 MB |
| `dsh-home-config-1.0.0.tar.gz` | 40 KB |
| `SHA256SUMS.txt` | — |

---

## 7. 升级到新版本（以后想动的时候）

1. 改 `manifest.json` 的 `pinned.*` 与 `assets.*`
2. 源机器上重建资产：`.\scripts\build-assets.ps1 -Verify`
3. 新 tag 上传：`gh release create v1.0.1 dist\*`
4. 新机器直接跑一键命令；老机器：`install.cmd -Force`

---

## 8. 故障排查

| 现象 | 处理 |
|---|---|
| `profile "desktop" is managed exclusively by the Electron application` | 正常：`desktop` 只能由桌面壳启动。CLI 用 `dsh-lock web`（shipped `web` profile + 你的补丁层） |
| `dump-config failed` | 用 `dsh --profile web --dump-config` 看真实报错；再看 `<Root>\logs\install-*.log`，多半是 `cordis.patch.yml` 被手改坏，从仓库 `payload/` 恢复 |
| purge 补丁数不是 82 | `dsh-purge --apply` 重跑，日志在 `<Root>\logs\purge-apply.log` |
| GUI 起不来 | `dsh-lock web --help` 看参数；端口占用查 `Get-NetTCPConnection -LocalPort 19387` |
| 模型列表空 | `DSH_ROUTER_BASE` 不可达；先 `curl $DSH_ROUTER_BASE/models` |
| 桌面壳又要更新 | 说明 `app-update.yml.disabled` 被还原，重跑 `install.cmd -Force` |
| 卸载 | `<Root>\tools\uninstall.cmd`（`-PurgeData` 连 `~/.dsh` 一起清） |

---

## 9. 安全与隐私

- `~/.dsh/.credentials.yaml`（会话密钥）**不入库**，新机器首次运行自动生成。
- `payload/dsh-home/profiles/desktop/cordis.yml` 只含 `apiKeyEnv: DS9700_API_KEY` 之类的**环境变量名**，不含明文密钥。
- Release 资产全部带 `SHA256SUMS.txt`，安装器逐个校验。
