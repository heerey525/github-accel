# 镜像实测数据与参考手册

> 实测时间：**2026-10-12** ｜ 环境：Mac M1 Pro / 国内网络 ｜ 方法：`curl -L --max-time 12`，含内容校验
> 判定：HTTP 200 **且**返回字节数 ≥ 预期（防止错误页冒充成功）

## 一、GitHub 代理镜像

### raw 单文件转发（探针：`raw.githubusercontent.com/torvalds/linux/master/README`）

| 镜像 | 代理模式 | HTTP | 耗时 | 备注 |
|---|---|---|---|---|
| `gh-proxy.com` | 代理 | 200 | **0.34s** | 最快 |
| `gh-proxy.com` | 裸连 | 200 | 0.34s | 与代理无关，国内直连可达 |
| `fastly.jsdelivr.net` | CDN | 200 | **0.24s** | 仅仓库内文件 |
| `cdn.jsdelivr.net` | CDN | 200 | 0.44s | 仅仓库内文件 |
| `ghfast.top` | 代理 | 200 | 1.27s | 可用 |
| `ghproxy.net` | 代理 | 200 | 1.10s | 可用 |
| `ghproxy.link` | 代理 | 200 | 1.55s | ⚠️ 返回 HTML，不支持直接拼接 |
| `gh.llkk.cc` | 代理 | 000 | 10s 超时 | ❌ DNS 污染 |
| `hub.gitmirror.com` | 代理 | 000 | 立即失败 | ❌ 域名已死 |
| `github.moeyy.xyz` | 代理 | 000 | 立即失败 | ❌ 域名已死 |
| `raw.kkgithub.com` | 镜像站 | 000 | 立即失败 | ❌ 域名已死 |
| `raw.gitmirror.com` | 镜像站 | 000 | 立即失败 | ❌ 域名已死 |
| **直连对照** `raw.githubusercontent.com` | — | 000 | **10s 超时** | 被墙 |

### Release 资产下载（探针：`jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64`，851,328 字节）

| 镜像 | HTTP | 耗时 | 吞吐 | 文件类型校验 |
|---|---|---|---|---|
| `gh-proxy.com` | 200 | 2.2s | **388 KB/s** | Mach-O 64-bit executable ✅ |
| `ghfast.top` | 200 | 5.8s | 146 KB/s | Mach-O 64-bit executable ✅ |
| `ghproxy.net` | 200 | 40s+ | 20 KB/s | Mach-O 64-bit executable ✅ |
| `ghproxy.link` | 200 | — | — | ❌ HTML document（1,739 字节） |

### git clone 实测（`octocat/Hello-World`，`--depth 1`）

| 镜像 | 退出码 | 耗时 | HEAD | 结论 |
|---|---|---|---|---|
| `gh-proxy.com` | 0 | 3s | `7fd1a60` | ✅ |
| `ghfast.top` | 0 | 2s | `7fd1a60` | ✅ |

### push 能力探测

方法：请求 `<镜像>/<repo>.git/info/refs?service=git-receive-pack`
- 返回 **401** → 端点存在（需认证）→ **支持 push 转发**
- 返回 **404** → 不支持

| 镜像 | receive-pack（推送） | upload-pack（拉取） |
|---|---|---|
| `gh-proxy.com` | 401 | 200 |
| `ghfast.top` | 401 | 200 |
| `ghproxy.net` | 401 | 200 |

### DNS 解析记录（用于识别污染/失效）

| 域名 | 解析结果 | 判定 |
|---|---|---|
| `gh-proxy.com` | 104.18.40.152 | ✅ Cloudflare |
| `ghfast.top` | 23.95.31.215 | ✅ |
| `ghproxy.net` | 5.135.5.132 | ✅ |
| `ghproxy.link` | 104.21.11.15 | 可解析但功能不符 |
| `cdn/fastly.jsdelivr.net` | 151.101.129.229 | ✅ Fastly |
| `gh.llkk.cc` | **157.240.0.18** | ❌ Facebook IP，DNS 污染 |
| `hub.gitmirror.com` | FAIL | ❌ |
| `github.moeyy.xyz` | FAIL | ❌ |
| `raw.kkgithub.com` | FAIL | ❌ |
| `raw.gitmirror.com` | FAIL | ❌ |
| `raw.githubusercontent.com` | 185.199.110.133 | 真实 IP，但被墙 |

## 二、各生态包管理器镜像

实测（同一轮探测，耗时含 DNS + TLS 握手）：

| 生态 | 镜像 | HTTP | 耗时 | 推荐 |
|---|---|---|---|---|
| **npm** | `https://registry.npmmirror.com` | 200 | **0.46s** | ⭐ 首选 |
| npm | `https://mirrors.cloud.tencent.com/npm/` | 200 | 1.28s | 备选 |
| npm | `https://registry.npmjs.org` | 200 | 1.88s | 官方 |
| npm | `https://r.cnpmjs.org` | 200 | 4.03s | 慢 |
| **pip** | `https://mirrors.cloud.tencent.com/pypi/simple/` | 200 | **0.52s** | ⭐ 首选 |
| pip | `https://mirrors.aliyun.com/pypi/simple/` | 200 | 0.67s | 备选 |
| pip | `https://pypi.mirrors.ustc.edu.cn/simple/` | 200 | 0.71s | 备选 |
| pip | `https://pypi.tuna.tsinghua.edu.cn/simple/` | 200 | 1.12s | 常用 |
| **go** | `https://mirrors.aliyun.com/goproxy/` | 200 | **0.15s** | ⭐ 首选 |
| go | `https://goproxy.bj.bcebos.com/` | 200 | 0.37s | 备选 |
| go | `https://goproxy.cn` | 200 | 0.59s | 常用 |
| go | `https://goproxy.io` | 200 | 2.32s | 慢 |
| **cargo** | `https://rsproxy.cn` | 200 | **0.24s** | ⭐ 首选 |
| cargo | `https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/` | 200 | 0.77s | 备选 |
| **flutter** | `https://pub.flutter-io.cn` | 200 | **0.33s** | ⭐ |
| ruby | `https://gems.ruby-china.com` | 000 | — | ❌ 当前不可用 |
| hex | `https://hexpm.upyun.com` | 404 | — | 路径需调整 |
| maven | `https://maven.aliyun.com/repository/public/` | 404 | — | 根路径 404，用具体仓库路径 |

## 三、配置片段速查

```bash
# npm
npm config set registry https://registry.npmmirror.com

# pip（写入 ~/.config/pip/pip.conf 或 ~/.pip/pip.conf）
pip config set global.index-url https://mirrors.cloud.tencent.com/pypi/simple/
pip config set global.trusted-host mirrors.cloud.tencent.com

# go
go env -w GOPROXY=https://mirrors.aliyun.com/goproxy/,direct
go env -w GOSUMDB=off

# cargo（~/.cargo/config.toml）
# [source.crates-io]
# replace-with = 'rsproxy'
# [source.rsproxy]
# registry = "https://rsproxy.cn/crates.io-index"
# [registries.rsproxy]
# index = "https://rsproxy.cn/crates.io-index"
# [net]
# git-fetch-with-cli = true

# git（全局，注意 push 副作用）
git config --global url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/"
```

## 四、重新探测的方法

镜像域名死亡率极高，**超过 1-2 个月必须重新探测**：

```bash
# 单点探测（含内容校验）
curl -sL --max-time 12 -o /dev/null \
  -w "code=%{http_code} time=%{time_total}s size=%{size_download}\n" \
  "https://gh-proxy.com/https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64"

# 一键重测全部并自动更新推荐值
bash ~/.workbuddy-ai/skills/github-accel/scripts/gh-accel.sh probe
```

**探测三原则**：
1. **必须看返回字节数** —— 200 不等于成功（`ghproxy.link` 就返回 200 + HTML）
2. **必须测 release 场景** —— 有的镜像 raw 快但 release 极慢（`ghproxy.net`：raw 1.1s，release 20 KB/s）
3. **必须测 push 端点** —— `info/refs?service=git-receive-pack` 返回 404 就说明不支持 push

## 五、已知失效域名黑名单

以下域名经实测**不可用**，不要再写进任何配置：

```
gh.llkk.cc          # DNS 污染至 157.240.0.18 (Facebook)
hub.gitmirror.com   # DNS 解析失败
github.moeyy.xyz    # DNS 解析失败
raw.kkgithub.com    # DNS 解析失败
raw.gitmirror.com   # DNS 解析失败
ghproxy.link        # 返回 HTML 而非文件，不支持 URL 直接拼接
```

> 注：`gitmirror.com` 系列、`kkgithub`、`moeyy` 在 2024-2025 年的各类"镜像汇总"文章中高频出现，如今已全部失效。这类文章普遍不维护，**以本文件实测数据为准**。

## 六、gh-accel 内置源清单

脚本内置源表（`scripts/gh-accel.sh` 的 `MIRROR_DB`），用 `gh-accel ls` 查看实时状态与当前值。

### github（GitHub 路由）

| 源名 | 值 | 说明 |
|---|---|---|
| `ssh` | `git@github.com:` | 走 SSH，可推送、抗 443 抖动 |
| `gh-proxy` | `https://gh-proxy.com` | 只读镜像，release 实测最快 |
| `ghfast` | `https://ghfast.top` | 只读镜像，次选 |
| `ghproxy-net` | `https://ghproxy.net` | 只读镜像，较慢 |
| `direct` | `https://github.com` | HTTPS 直连，国内常超时 |

### npm

| 源名 | 值 | 备注 |
|---|---|---|
| `npm` | `https://registry.npmjs.org/` | 官方（nrm 同名） |
| `taobao` | `https://registry.npmmirror.com/` | 阿里 npmmirror（nrm 同名） |
| `tencent` | `https://mirrors.tencent.com/npm/` | 腾讯软件源（nrm 同名） |
| `tencent-cloud` | `https://mirrors.cloud.tencent.com/npm/` | 腾讯云镜像（旧域名） |
| `huawei` | `https://repo.huaweicloud.com/repository/npm/` | 华为云（nrm 同名） |
| `cnpm` | `https://r.cnpmjs.org/` | cnpm，较慢（nrm 同名） |
| `yarn` | `https://registry.yarnpkg.com/` | yarn 官方（nrm 同名） |

### pip

| 源名 | 值 |
|---|---|
| `tencent` | `https://mirrors.cloud.tencent.com/pypi/simple/` |
| `aliyun` | `https://mirrors.aliyun.com/pypi/simple/` |
| `huawei` | `https://repo.huaweicloud.com/repository/pypi/simple/` |
| `ustc` | `https://pypi.mirrors.ustc.edu.cn/simple/` |
| `tuna` | `https://pypi.tuna.tsinghua.edu.cn/simple/` |
| `pypi` | `https://pypi.org/simple/` |

### go

| 源名 | 值 |
|---|---|
| `aliyun` | `https://mirrors.aliyun.com/goproxy/` |
| `goproxy-cn` | `https://goproxy.cn` |
| `goproxy-io` | `https://goproxy.io` |
| `bcebos` | `https://goproxy.bj.bcebos.com/` |
| `direct` | `direct`（不走代理） |

### cargo

| 源名 | 值 |
|---|---|
| `rsproxy` | `sparse+https://rsproxy.cn/index/` |
| `tuna` | `sparse+https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/` |
| `crates-io` | `https://github.com/rust-lang/crates.io-index`（git index，无法 HTTP 测速） |

**扩展自定义源**：`gh-accel add <eco> <name> <url> [备注]`，写入 `~/.config/gh-accel/mirrors.conf`（同格式），同名覆盖内置源；`gh-accel rm` 删除。内置源只读。

### 各生态「当前源」的判定方式

| 生态 | 读取位置 |
|---|---|
| github | `git config --global` 中 `url.*.insteadOf` 的实际值 |
| npm | `npm config get registry` |
| pip | `~/.config/pip/pip.conf`（或 `~/.pip/pip.conf`）的 `index-url` |
| go | `go env GOPROXY`（比对时自动去掉 `,direct` 后缀） |
| cargo | `~/.cargo/config.toml` 的 `registry` |

### 与 nrm 内置源的对照（nrm 2.1.0）

nrm 的内置源定义在 `nrm/dist/constants.js` 的 `REGISTRIES`，共 7 条。逐条对照：

| nrm 源 | nrm 的值 | gh-accel 对应 | 状态 |
|---|---|---|---|
| `npm` | `https://registry.npmjs.org/` | `npm` | ✅ 一致 |
| `yarn` | `https://registry.yarnpkg.com/` | `yarn` | ✅ 一致 |
| `taobao` | `https://registry.npmmirror.com/` | `taobao` | ✅ 一致 |
| `cnpm` | `https://r.cnpmjs.org/` | `cnpm` | ✅ 一致 |
| `huawei` | `https://repo.huaweicloud.com/repository/npm/` | `huawei` | ✅ 一致 |
| `tencent` | `https://mirrors.tencent.com/npm/` | `tencent` | ✅ 一致（v1.1.1 修正） |
| `npmMirror` | `https://skimdb.npmjs.com/registry/` | — | ❌ **未收录，源已失效** |

**关于 `npmMirror`（未收录）**：实测 `https://skimdb.npmjs.com/` 根路径返回 200，但查包路径 `https://skimdb.npmjs.com/registry/express` 返回 **404**，`/registry/-/all` 同样 404——它已不能作为 npm registry 使用。nrm 列表里仍保留，但切过去装不了包。gh-accel 故意不收录，避免用户切到死源。

**关于 `tencent`（曾不一致，已修正）**：nrm 用 `mirrors.tencent.com`（腾讯软件源新域名），早期 gh-accel 误用了 `mirrors.cloud.tencent.com`（腾讯云旧域名）。两者实测都能通、速度相近（0.6–1.2s 波动），但**域名不一致会导致跨工具识别失败**——在 nrm 里切到 tencent 后，gh-accel 会认不出当前源。v1.1.1 已对齐为 nrm 的值，同时保留 `tencent-cloud` 作为旧域名备选。

> 若你的 nrm 版本更新后新增了源，用 `nrm ls` 对照本表，缺失的可用 `gh-accel add npm <name> <url>` 自行补上。

### 与 git-mng 的 key 对应关系

| gh-accel 源 | 写入的 git config key | git-mng `route status` 判定 |
|---|---|---|
| `ssh` | `url.git@github.com:.insteadOf` | `ssh` ✅ |
| `gh-proxy` | `url.https://gh-proxy.com/https://github.com/.insteadOf` | `proxy` ✅ |
| `ghfast` / `ghproxy-net` | 各自镜像的 key | `direct` ⚠️ 误报（git-mng 只认 gh-proxy） |

`use github <x>` 与 `off` 都会先统一清理全部已知 GitHub 路由 key（含 git-mng 的 ssh key），不会出现多条 `insteadOf` 并存。
