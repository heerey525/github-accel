# github-accel

> 把卡在 GitHub 上的依赖安装、仓库克隆、Release 下载切到国内镜像；顺带用一套 nrm 风格的命令统一管理 `github` / `npm` / `pip` / `go` / `cargo` 的镜像源。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## 它解决什么问题

在国内网络环境下，`github.com` 和 `raw.githubusercontent.com` 经常连不上或慢到无法忍受，
直接后果就是：

- `npm install` / `pip install` / `go get` / `cargo build` 卡在拉取 GitHub 依赖
- `git clone` 停在 `Receiving objects` 不动
- 从 GitHub Releases 下载 `.dmg` / `.tar.gz` 龟速或中断
- 安装脚本里的 `curl -fsSL https://raw.githubusercontent.com/...` 直接超时

本项目提供一套**实测过**的镜像选型 + 一个零依赖的 shell 工具，把上述请求自动改道到国内可达的代理。

## 实测数据

2026-10-12 实测（Mac M1 Pro / 国内网络 / `curl --max-time 12` / 含内容校验）：

| 镜像 | raw 小文件 | git clone | Release 831KB | push 转发 | 结论 |
|---|---|---|---|---|---|
| `gh-proxy.com` | 0.34s | 3s | **388 KB/s** | ✅ | **首选** |
| `ghfast.top` | 1.3s | 2s | 146 KB/s | ✅ | 次选 |
| `ghproxy.net` | 1.1s | — | 20 KB/s | ✅ | 兜底 |
| `fastly.jsdelivr.net` | **0.24s** | ✗ | ✗ | ✗ | 仅 raw 单文件 |
| 直连 `raw.githubusercontent.com` | **超时** | — | — | — | 被墙 |

> ⚠️ **镜像域名死亡率极高。** 本次实测的 12 个域名里，6 个已失效：
> `gh.llkk.cc`（DNS 被污染）、`hub.gitmirror.com`、`github.moeyy.xyz`、
> `raw.kkgithub.com`、`raw.gitmirror.com`、`ghproxy.link`。
> 网上流传的"镜像大全"文章普遍不维护，**请以本仓库的探测结果为准**。

## 快速开始

```bash
git clone git@github.com:heerey525/github-accel.git
cd github-accel

S=./scripts/gh-accel.sh

bash $S ls                  # 列出所有镜像源，* 标记当前使用
bash $S use npm taobao      # 切换 npm 源
bash $S use github ssh      # 切换 GitHub 路由到 SSH
bash $S test                # 全生态测速对比
```

## 命令

**源管理**（参考 nrm 的交互）

| 命令 | 作用 |
|---|---|
| `ls [eco]` | 列出镜像源，`*` 标记当前使用 |
| `use <eco> <name>` | 切换源 |
| `test [eco]` | 测速对比 |
| `add <eco> <name> <url> [备注]` | 添加自定义源 |
| `rm <eco> <name>` | 删除自定义源（内置源不可删） |

**GitHub 专项**

| 命令 | 作用 |
|---|---|
| `probe` | 实测各镜像 Release 下载速度，选出推荐值 |
| `on [name\|url]` | 开启 GitHub 加速（等价 `use github <name>`） |
| `off` | 关闭加速，恢复原有配置 |
| `url <github-url>` | 把单个 GitHub URL 转成加速 URL |
| `verify` | 验证加速是否生效（直连 vs 镜像 + 内容一致性） |

**总览**

| 命令 | 作用 |
|---|---|
| `status` | 各生态当前源一览 |
| `doctor` | 体检：路由 / push 通道 / SSH / 各生态可用性 / 失效域名 |

**生态（eco）**：`github` · `npm` · `pip` · `go` · `cargo`

自定义源写入 `~/.config/gh-accel/mirrors.conf`，格式 `eco|name|url|备注`。

## 各生态配置

```bash
# git（注意 push 副作用，见下方陷阱）
git config --global url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/"

# npm
npm config set registry https://registry.npmmirror.com

# pip
pip config set global.index-url https://mirrors.cloud.tencent.com/pypi/simple/

# go
go env -w GOPROXY=https://mirrors.aliyun.com/goproxy/,direct
```

更多生态（cargo / flutter / maven 等）与完整实测耗时见 [`references/mirrors.md`](references/mirrors.md)。

## 已知陷阱

1. **`insteadOf` 会连 push 一起劫持。** 配置后 `git remote get-url --push` 同样被重写成镜像地址。
   镜像一挂，push 也跟着废。
2. **`pushInsteadOf` 无法反向覆盖。** git 走最长前缀匹配，镜像串更长，`insteadOf` 照样赢。
   想把 push 摘回直连，**改用 SSH**（`insteadOf` 只匹配 `https://`，不碰 `git@github.com:`）。
3. **jsdelivr 只能加速仓库内文件**，不支持 Release 资产，也有单文件大小上限。
4. **镜像可能返回错误页而不是报错**（`ghproxy.link` 就返回 200 + HTML），所以务必校验内容哈希。
5. **本机已有 `HTTP_PROXY` 时注意叠加**，环境代理和镜像串行可能反而更慢。

## 兼容性

- macOS / Linux，纯 bash，**兼容 macOS 自带 bash 3.2**（不使用关联数组等 bash4 特性）
- 依赖：`curl`、`git`；无需 Python / Node

## License

[MIT](LICENSE)
