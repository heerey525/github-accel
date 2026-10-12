---
name: github-accel
display_name: GitHub 加速与镜像源管理
description: 加速从 GitHub 拉取依赖、克隆仓库、下载发布文件，并统一管理 github/npm/pip/go/cargo 的国内镜像源。当 npm/pip/go/cargo 安装卡在 GitHub、git clone 超时或龟速、Release 资产下载不动、raw 文件拉取失败，或需要切换国内镜像源时使用。命令交互参考 nrm（ls/use/test/add/rm），含实测选型、git insteadOf 会连 push 一起劫持的陷阱、镜像失效回退与效果验证。
description_zh: 一键切换 GitHub/npm/pip/go/cargo 的国内镜像源，加速卡在 GitHub 上的依赖安装与下载。
description_en: Accelerate GitHub-dependent installs and manage China mirrors for github/npm/pip/go/cargo, with nrm-style ls/use/test/add/rm commands, measured mirror selection and verification.
version: 1.1.0
author: heerey525
agent_created: true
---

# GitHub 加速与镜像源管理

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
| **只想换源** | 需要把 npm/pip/go/cargo 从官方源切到国内镜像，或对比各镜像速度 |

**不要触发的情况**：本机已开着全局 HTTP 代理且测速正常，且不涉及换源需求。

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

## 快速开始（nrm 风格）

脚本位于本 skill 目录下 `scripts/gh-accel.sh`，纯 bash、兼容 macOS 自带 bash 3.2、零第三方依赖。

```bash
S=~/.workbuddy-ai/skills/github-accel/scripts/gh-accel.sh
```

### 源管理（核心）

```bash
bash $S ls                  # 列出所有生态的镜像源，* 标记当前使用
bash $S ls npm              # 只看某一个生态
bash $S use npm taobao      # 切换 npm 源
bash $S use github ssh      # 切换 GitHub 路由到 SSH
bash $S test                # 全生态测速对比
bash $S test npm            # 只测某个生态
bash $S add pip corp https://pypi.corp.local/simple/   # 加自定义源
bash $S rm pip corp         # 删自定义源（内置源不可删）
```

**生态**：`github` / `npm` / `pip` / `go` / `cargo`

`ls` 输出示例：

```
GitHub 路由
  * ssh --------- ssh  # 走 SSH，可推送、抗 443 抖动
    gh-proxy ---- https://gh-proxy.com  # 只读镜像，release 实测最快
    direct ------ https://github.com  # HTTPS 直连，国内常超时

npm registry
    taobao ------ https://registry.npmmirror.com/  # 阿里 npmmirror
  * huawei ------ https://repo.huaweicloud.com/repository/npm/  # 华为云
```

### GitHub 专项

```bash
bash $S probe     # 实测各镜像 release 下载速度，选出推荐值
bash $S on        # 开启 GitHub 加速（等价 use github <probe 推荐值>）
bash $S off       # 关闭，恢复原有配置
bash $S verify    # 验证是否真生效（直连 vs 镜像 + md5 内容校验）
bash $S url https://github.com/a/b.git   # 把单个 URL 转成加速 URL
```

### 总览与体检

```bash
bash $S status          # 各生态当前源一览
bash $S doctor          # 体检：路由 / push 通道 / SSH / 各生态可用性 / 失效域名
bash $S selftest        # 无副作用自检（不修改任何真实配置）
bash $S selftest --net  # 追加网络连通测试
```

`selftest` 检查 6 组：运行环境 / 源表完整性 / 命令冒烟 / 当前源识别 / **配置写入可逆性** / 网络连通（可选）。
其中写入可逆性用**隔离的 `GIT_CONFIG_GLOBAL`** 验证，跑完不碰真实配置，可放心执行。

### 自定义源

用户自定义源写在 `~/.config/gh-accel/mirrors.conf`，格式 `eco|name|url|备注`，与内置源同构。`add` / `rm` 自动维护该文件；内置源只读、不可删除。同名自定义源会覆盖内置源。

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

## 与 git-mng 共存（重要）

若本机装有 `git-mng`（GitHub/Gitee 凭据与路由管理工具，`~/.local/bin/git-mng`），两者操作**同一组** git config key，需注意：

| gh-accel 源 | 写入的 key | git-mng `route status` 判定 |
|---|---|---|
| `use github ssh` | `url.git@github.com:.insteadOf` | `ssh` ✅ 一致 |
| `use github gh-proxy` | `url.https://gh-proxy.com/https://github.com/.insteadOf` | `proxy` ✅ 一致 |
| `use github ghfast` / `ghproxy-net` | 各自的 key | `direct` ⚠️ 不一致 |

**结论**：两者对 `ssh` 与 `gh-proxy` 的语义完全一致，可放心混用。但若切到 `ghfast` 等非 gh-proxy 镜像，`git-mng route status` 会误报为 `direct`——它只认 gh-proxy 那个 key，不是配置没生效。

`gh-accel use github <x>` 在切换时会**统一清理**所有已知 GitHub 路由 key（含 git-mng 写入的 ssh key），因此不会出现两条 `insteadOf` 同时生效的冲突。`gh-accel off` 同样会清理全部。

## 相关 skill

- `macos-app-from-github-release` —— 从 Release 装 macOS 应用时，本 skill 的镜像选型可直接复用
- `git-mng`（本机工具）—— GitHub/Gitee 凭据与路由体检；其 `route` 与 gh-accel 的 github 生态语义一致
