---
name: github-accel
display_name: GitHub 依赖安装加速
description: 加速从 GitHub 拉取依赖、克隆仓库、下载发布文件。当 npm/pip/go/cargo 安装卡在 GitHub、git clone 超时或龟速、Release 资产下载不动、raw 文件拉取失败时使用。含国内镜像实测选型（gh-proxy.com 首选）、git insteadOf 会连 push 一起劫持的陷阱、镜像失效自动回退、以及加速是否真正生效的验证方法。
description_zh: 把卡在 GitHub 上的依赖安装、仓库克隆、Release 下载切换到国内代理镜像，含实测选型、失效自动回退与效果验证。
description_en: Accelerate GitHub-dependent installs by routing git clone, release downloads and raw file fetches through China-accessible mirrors, with measured mirror selection, automatic fallback and verification.
version: 1.0.0
author: heerey525
agent_created: true
---

# GitHub 依赖安装加速

## 何时用（触发条件）

出现以下任一情况时加载本 skill：

| 场景 | 典型症状 |
|---|---|
| **git clone / fetch** | `github.com` 连接超时、clone 卡在 `Receiving objects`、速度几十 KB/s |
| **Release 资产下载** | 从 `github.com/<org>/<repo>/releases/download/...` 下 `.dmg`/`.tar.gz`/`.zip` 极慢或中断 |
| **raw 文件拉取** | `raw.githubusercontent.com` 直接超时（安装脚本里的 `curl -fsSL`） |
| **npm 安装** | 依赖里含 `github:user/repo`、`user/repo#tag`、GitHub tarball URL，install 卡住 |
| **pip 安装** | `pip install git+https://github.com/...`、`-r requirements.txt` 里的 git 依赖 |
| **go 模块** | `go get` 拉取 GitHub 上的模块超时 |
| **cargo / 其它** | `cargo build` 拉 git 依赖、flutter `pub get`、composer 等 |

**不要触发的情况**：目标只是普通 npm/pip 包（走 registry 镜像即可，不需要 GitHub 代理）；或者本机已开着全局 HTTP 代理且测速正常。

## 核心结论（先读，省一半时间）

**2026-10 实测（Mac M1 Pro，国内网络，12s 超时，含内容校验）：**

| 镜像 | raw 小文件 | git clone | release 831KB | push 转发 | 结论 |
|---|---|---|---|---|---|
| `gh-proxy.com` | ✅ 0.34s | ✅ 3s | **388 KB/s** | ✅ 支持 | **首选** |
| `ghfast.top` | ✅ 1.3s | ✅ 2s | 146 KB/s | ✅ 支持 | 次选 |
| `ghproxy.net` | ✅ 1.1s | — | 20 KB/s | ✅ 支持 | 慢，仅兜底 |
| `fastly.jsdelivr.net` | ✅ **0.24s** | ✗ | ✗ | ✗ | **raw 单文件首选** |
| `cdn.jsdelivr.net` | ✅ 0.44s | ✗ | ✗ | ✗ | raw 备选 |

**直连对照**：`raw.githubusercontent.com` 直连 **超时**；`github.com` 直连 4.2–6.8s（慢但常能通）。

**已死，不要再用**：`gh.llkk.cc`（DNS 被污染到 Facebook IP）、`hub.gitmirror.com`、`github.moeyy.xyz`、`raw.kkgithub.com`、`raw.gitmirror.com`（域名解析全部失败）、`ghproxy.link`（返回 HTML 而非文件，不支持直接拼接）。

**URL 拼接规则**（全量代理）：`https://<镜像>/<原始完整 GitHub URL>`
```
https://gh-proxy.com/https://github.com/user/repo.git
https://gh-proxy.com/https://github.com/user/repo/releases/download/v1.0/x.tar.gz
```
**raw 文件**改用 jsdelivr 格式（更快）：`https://raw.githubusercontent.com/u/r/ref/path` → `https://fastly.jsdelivr.net/gh/u/r@ref/path`

## 首选做法：用自带脚本

脚本位于本 skill 目录下 `scripts/gh-accel.sh`，纯 bash、兼容 macOS 自带 bash 3.2。

```bash
S=~/.workbuddy-ai/skills/github-accel/scripts/gh-accel.sh

bash $S probe     # 1. 实测所有镜像，选出最快的一个（写入 ~/.config/gh-accel/state）
bash $S on        # 2. 开启 git 全局加速（用 probe 的推荐值）
bash $S verify    # 3. 验证是否真生效（直连 vs 镜像 + md5 内容校验）
bash $S off       # 4. 用完关掉，恢复原有配置
```

辅助命令：

```bash
bash $S status                          # 看当前 git/npm/pip/go 加速状态
bash $S url https://github.com/a/b.git  # 把单个 URL 转成加速 URL
bash $S doctor                          # 体检：git 规则 / push 通道 / 各生态镜像 / 失效域名
```

## 代理地址的配置与切换

### git（clone / fetch / 依赖拉取）

**方式 A：全局 insteadOf（脚本 `on` 干的事）**
```bash
git config --global url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/"
```
- 优点：所有 `https://github.com/...` 自动重写，npm/pip/go 里的 git 依赖一并受益
- **缺点：`insteadOf` 同时作用于 push（见下方陷阱）**

**方式 B：单次 clone 直接拼 URL（零副作用，推荐给一次性任务）**
```bash
git clone https://gh-proxy.com/https://github.com/user/repo.git
```

**方式 C：per-repo 配置（只影响当前仓库）**
```bash
git remote set-url origin https://gh-proxy.com/https://github.com/user/repo.git
```

**切换镜像**：改 `insteadOf` 的 base 即可。切换前先 `probe` 确认新镜像可用。

**关闭**：`bash $S off`，或 `git config --global --unset url."https://gh-proxy.com/https://github.com/".insteadOf`

### Release 资产下载

```bash
curl -L -o out.tar.gz "https://gh-proxy.com/https://github.com/org/repo/releases/download/v1.0/asset.tar.gz"
```
支持断点续传：加 `-C -`。下载后**务必校验**（镜像可能返回错误页）：
```bash
curl -sL "https://gh-proxy.com/https://github.com/org/repo/releases/download/v1.0/SHA256SUMS" | shasum -a 256 -c -
```

### raw 文件

```bash
# 推荐：jsdelivr（快，但有 20MB 单文件上限）
curl -fsSL "https://fastly.jsdelivr.net/gh/user/repo@main/install.sh"
# 大文件或 jsdelivr 不支持时，退回全量代理
curl -fsSL "https://gh-proxy.com/https://raw.githubusercontent.com/user/repo/main/install.sh"
```

### npm / pip / go / cargo

这些**优先走各自生态的国内镜像**（比 GitHub 代理更快更稳），只有依赖本身指向 GitHub 时才需要 GitHub 代理：

```bash
# npm：registry 换源
npm config set registry https://registry.npmmirror.com
# pip
pip config set global.index-url https://mirrors.cloud.tencent.com/pypi/simple/
# go
go env -w GOPROXY=https://mirrors.aliyun.com/goproxy/,direct GOSUMDB=off
# cargo（改 ~/.cargo/config.toml）
# [source.crates-io] replace-with = 'rsproxy'
```

各生态完整镜像清单与实测耗时见 `references/mirrors.md`。

## 陷阱清单（每条都踩过）

1. **`insteadOf` 会连 push 一起劫持。** `git remote get-url --push origin` 同样被重写成镜像地址。三个主流镜像实测都转发 `git-receive-pack`（端点返回 401 = 存在，需认证），所以通常能 push，但一旦镜像挂掉，**push 也跟着废**。

2. **`pushInsteadOf` 无法反向覆盖。** 想用 `url."https://github.com/".pushInsteadOf "https://gh-proxy.com/https://github.com/"` 把 push 摘回直连 —— **无效**。git 走「最长前缀匹配」，镜像那串更长，`insteadOf` 照样赢（实测验证过）。
   **正确解法**：push 改用 SSH，`insteadOf` 只匹配 `https://`，完全不碰 `git@github.com:`：
   ```bash
   git remote set-url origin git@github.com:user/repo.git
   ```

3. **jsdelivr 只能加速仓库内文件。** `gh/user/repo@ref/path` 这种格式，**不支持 release 资产**（实测 `gh/jqlang/jq@jq-1.7.1/README.md` 返回 000），也有单文件大小上限。release 下载必须走全量代理。

4. **镜像可能返回错误页而不是报错。** `ghproxy.link` 就返回 200 + 1739 字节 HTML。所以**永远要校验内容**（`gh-accel verify` 里的 md5 对比、下载后跑 SHA256）。

5. **别信任何"镜像清单"文章。** 这类域名死亡率极高（本次实测 6 个里有 5 个已死）。**先探测再配置**，`gh-accel probe` 就是干这个的。

6. **本机已有 HTTP_PROXY 时注意叠加。** 环境变量代理和镜像会串行叠加，可能反而更慢。`gh-accel status` 会提示。

7. **中文标点紧跟 shell 变量名会翻车。** 写这类脚本时 `"$VAR；"` 在 bash 3.2 下会把中文字节吞进变量名 → `unbound variable`。用 `"${VAR}；"`。（这是本脚本开发时实际踩到的 bug。）

## 失败回退机制

三层，从外到内：

1. **配置前探测**：`gh-accel on` 会先验证目标镜像可用（拉一个 raw 小文件并检查 ≥50 字节）。不可用则自动按候选池顺序回退到下一个可用镜像，全挂才报错退出。
2. **运行中失败**：某个下载/克隆失败时，直接换候选池里的下一个镜像重试：
   ```bash
   for m in gh-proxy.com ghfast.top ghproxy.net; do
     git clone "https://$m/https://github.com/user/repo.git" repo && break
   done
   ```
3. **彻底放弃加速**：`gh-accel off` 恢复原始配置，回到直连。脚本首次 `on` 时会备份原 `insteadOf` 配置到 `~/.config/gh-accel/git-url-backup`，`off` 时原样还原（已实测往返一致，不会破坏用户既有配置）。

## 如何验证加速是否生效

```bash
bash $S verify
```
输出三件事：
1. **直连耗时** —— 失败就说明加速必要
2. **镜像耗时** —— 失败说明该换源
3. **md5 内容一致性** —— 防止镜像返回错误页冒充成功

手动验证：
```bash
# 看 git 是否真的重写了 URL
git ls-remote --get-url https://github.com/foo/bar.git
# 期望输出: https://gh-proxy.com/https://github.com/foo/bar.git

# 看 push 走哪
git remote get-url --push origin

# 计时对比
time curl -sL -o /dev/null "https://gh-proxy.com/https://raw.githubusercontent.com/torvalds/linux/master/README"
```

**判定标准**：镜像耗时 < 直连耗时，且 md5 一致 → 加速生效。

## 相关 skill

- `macos-app-from-github-release` —— 从 Release 装 macOS 应用时，本 skill 的镜像选型可直接复用
