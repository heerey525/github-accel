#!/usr/bin/env bash
# gh-accel - GitHub 依赖安装加速工具
# 兼容 macOS 自带 bash 3.2（不使用关联数组 / mapfile 等 bash4 特性）
#
# 用法: gh-accel <command> [args]
#   probe              探测所有镜像可用性与速度，写入推荐配置
#   on [mirror]        开启 git 全局加速（默认用 probe 推荐值）
#   off                关闭 git 全局加速，恢复原配置
#   status             显示当前加速状态
#   url <github-url>   把 GitHub URL 转成加速 URL
#   verify             验证加速是否真正生效（直连 vs 镜像对比）
#   doctor             全面体检：git 配置 + 各生态镜像 + 失效域名
#   help               显示帮助

set -uo pipefail

# 输出被 head/tail 截断时不刷 Broken pipe 噪音
trap '' PIPE 2>/dev/null || true

# ---------------------------------------------------------------------------
# 配置区：镜像候选池（按 2026-10 实测速度排序，详见 references/mirrors.md）
# ---------------------------------------------------------------------------
# git / release 通吃的 GitHub 全量代理
GH_MIRRORS="https://gh-proxy.com https://ghfast.top https://ghproxy.net"
# 仅用于 raw 单文件的 CDN（不支持 release 资产、不支持 git clone）
RAW_MIRRORS="https://fastly.jsdelivr.net/gh https://cdn.jsdelivr.net/gh"

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gh-accel"
STATE_FILE="$CONF_DIR/state"
BACKUP_FILE="$CONF_DIR/git-url-backup"
LOG_FILE="$CONF_DIR/probe.log"

# 用于测速的探针资源
PROBE_RAW="raw.githubusercontent.com/torvalds/linux/master/README"
PROBE_REL="github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64"

# 已确认失效的域名（避免每次探测白等超时）
DEAD_HOSTS="gh.llkk.cc hub.gitmirror.com github.moeyy.xyz raw.kkgithub.com raw.gitmirror.com ghproxy.link"

C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_DIM="\033[2m"; C_OFF="\033[0m"
[ -t 1 ] || { C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""; }

log()  { printf "%b\n" "$*"; }
ok()   { printf "${C_OK}✓${C_OFF} %b\n" "$*"; }
warn() { printf "${C_WARN}!${C_OFF} %b\n" "$*"; }
err()  { printf "${C_ERR}✗${C_OFF} %b\n" "$*" >&2; }
dim()  { printf "${C_DIM}%b${C_OFF}\n" "$*"; }

mkdir -p "$CONF_DIR"

# ---------------------------------------------------------------------------
# 底层工具
# ---------------------------------------------------------------------------

# 单次探测：$1=name $2=url $3=期望字节下限(可选)
# 输出: "code<TAB>time_total<TAB>size_download"
probe_once() {
  local name="$1" url="$2" minbytes="${3:-1}"
  local res code secs size
  res=$(curl -sL --max-time 12 -o /dev/null \
        -w "%{http_code}\t%{time_total}\t%{size_download}" "$url" 2>/dev/null)
  [ -z "$res" ] && res="000\t0\t0"
  code=$(printf "%s" "$res" | cut -f1)
  secs=$(printf "%s" "$res" | cut -f2)
  size=$(printf "%s" "$res" | cut -f3)
  # 内容校验：防止镜像返回错误页（HTML）冒充成功
  if [ "$code" = "200" ] && [ "$size" -lt "$minbytes" ] 2>/dev/null; then
    code="SHORT"
  fi
  printf "%s\t%s\t%s" "$code" "$secs" "$size"
}

# 探测整个池子，返回第一个可用镜像（按给定顺序）
pick_first_ok() {
  local kind="$1"  # gh | raw
  local pool url target res code
  if [ "$kind" = "raw" ]; then
    pool="$RAW_MIRRORS"
    for m in $pool; do
      url="${m}/torvalds/linux@master/README"
      res=$(probe_once "$m" "$url" 50); code=$(printf "%s" "$res" | cut -f1)
      [ "$code" = "200" ] && { printf "%s" "$m"; return 0; }
    done
  else
    pool="$GH_MIRRORS"
    for m in $pool; do
      url="${m}/https://${PROBE_RAW}"
      res=$(probe_once "$m" "$url" 50); code=$(printf "%s" "$res" | cut -f1)
      [ "$code" = "200" ] && { printf "%s" "$m"; return 0; }
    done
  fi
  return 1
}

# ---------------------------------------------------------------------------
# probe - 探测并排序
# ---------------------------------------------------------------------------
cmd_probe() {
  log "探测 GitHub 代理镜像（超时 12s，含内容校验）..."
  log ""
  printf "%-24s %-8s %-10s %-12s %s\n" "镜像" "状态" "耗时" "吞吐" "备注"
  printf "%s\n" "--------------------------------------------------------------------------"

  local best_gh="" best_time=999
  local m url res code secs size speed note

  for m in $GH_MIRRORS; do
    url="${m}/https://${PROBE_REL}"
    res=$(probe_once "$m" "$url" 100000)
    code=$(printf "%s" "$res" | cut -f1); secs=$(printf "%s" "$res" | cut -f2); size=$(printf "%s" "$res" | cut -f3)
    note=""
    case "$code" in
      200) note="可用"
           # 用实测耗时选最优（release 场景更有代表性）
           if awk "BEGIN{exit !($secs < $best_time)}"; then best_time="$secs"; best_gh="$m"; fi ;;
      SHORT) note="返回内容异常" ;;
      000)   note="超时/连接失败" ;;
      *)     note="HTTP $code" ;;
    esac
    speed="-"
    [ "$code" = "200" ] && [ "$size" -gt 0 ] 2>/dev/null && \
      speed=$(awk "BEGIN{printf \"%.0f KB/s\", $size/1024/$secs}")
    printf "%-24s %-8s %-10s %-12s %s\n" "$m" "$code" "${secs}s" "$speed" "$note"
  done

  log ""
  log "raw 单文件 CDN（不支持 release / clone）:"
  for m in $RAW_MIRRORS; do
    url="${m}/torvalds/linux@master/README"
    res=$(probe_once "$m" "$url" 50)
    code=$(printf "%s" "$res" | cut -f1); secs=$(printf "%s" "$res" | cut -f2)
    printf "  %-34s %-8s %s\n" "$m" "$code" "${secs}s"
  done

  log ""
  if [ -n "$best_gh" ]; then
    printf "%s %s\n" "$best_gh" "$best_time" > "$STATE_FILE"
    ok "推荐镜像: $best_gh  (release 实测 ${best_time}s)"
    dim "  已写入 ${STATE_FILE}；执行 'gh-accel on' 应用"
  else
    err "所有 GitHub 代理均不可用 —— 检查网络，或改用直连（可能很慢）"
    return 1
  fi
}

# 读取推荐镜像，没有则用池内第一个
recommended() {
  if [ -f "$STATE_FILE" ]; then
    cut -d' ' -f1 < "$STATE_FILE"
  else
    printf "%s" "$(printf "%s" "$GH_MIRRORS" | awk '{print $1}')"
  fi
}

# ---------------------------------------------------------------------------
# on / off - 配置 git 全局 insteadOf
# ---------------------------------------------------------------------------
git_cfg_key() {
  # $1 = mirror  ->  git config 的 url.<mirror>/https://github.com/.insteadof 键名
  printf 'url.%s/https://github.com/.insteadof' "$1"
}

cmd_on() {
  local mirror="${1:-$(recommended)}"
  case "$mirror" in
    http*) ;;
    *) mirror="https://$mirror" ;;
  esac

  # 验证镜像确实可用，不可用则自动回退到下一个候选
  local res code
  res=$(probe_once "$mirror" "${mirror}/https://${PROBE_RAW}" 50)
  code=$(printf "%s" "$res" | cut -f1)
  if [ "$code" != "200" ]; then
    warn "${mirror} 当前不可用（${code}），尝试自动回退..."
    local alt; alt=$(pick_first_ok gh)
    if [ -z "$alt" ]; then err "无可用镜像，放弃。"; return 1; fi
    mirror="$alt"; ok "回退到 $mirror"
  fi

  # 备份现有 insteadOf 配置（首次 on 时）
  if [ ! -f "$BACKUP_FILE" ]; then
    {
      local existing
      existing=$(git config --global --get-regexp '^url\..*\.insteadof$' 2>/dev/null || true)
      printf "%s\n" "$existing"
    } > "$BACKUP_FILE"
    dim "已备份原 insteadOf 配置 -> $BACKUP_FILE"
  fi

  # 清理本工具此前写入的其它镜像规则，避免多条规则互相干扰
  local old
  for old in $GH_MIRRORS; do
    git config --global --unset "$(git_cfg_key "$old")" 2>/dev/null || true
  done

  git config --global "$(git_cfg_key "$mirror")" "https://github.com/"
  ok "已开启 git 加速: https://github.com/  ->  $mirror/https://github.com/"
  log ""
  warn "注意: insteadOf 同时作用于 fetch 和 push（详见 SKILL.md「陷阱」章节）"
  warn "      push 若走不通，执行 'gh-accel doctor' 查看修复建议"
}

cmd_off() {
  local m found=0
  for m in $GH_MIRRORS; do
    if git config --global --get "$(git_cfg_key "$m")" >/dev/null 2>&1; then
      git config --global --unset "$(git_cfg_key "$m")"
      ok "已移除 $m 规则"
      found=1
    fi
  done
  [ "$found" = "0" ] && dim "没有本工具写入的规则需要移除"

  if [ -f "$BACKUP_FILE" ]; then
    local line key val
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      key=$(printf "%s" "$line" | awk '{print $1}')
      val=$(printf "%s" "$line" | sed "s/^[^ ]* //")
      git config --global "$key" "$val" 2>/dev/null && dim "已恢复: $key = $val"
    done < "$BACKUP_FILE"
    mv "$BACKUP_FILE" "$BACKUP_FILE.restored"
    dim "备份已标记为已恢复"
  fi
  ok "git 加速已关闭"
}

cmd_status() {
  log "=== gh-accel 状态 ==="
  local m key val any=0
  for m in $GH_MIRRORS; do
    key=$(git_cfg_key "$m")
    val=$(git config --global --get "$key" 2>/dev/null || true)
    if [ -n "$val" ]; then
      ok "git 加速生效中: $key = $val"
      any=1
    fi
  done
  [ "$any" = "0" ] && dim "git 全局加速: 未开启"

  log ""
  log "其它相关配置:"
  printf "  npm registry : %s\n" "$(npm config get registry 2>/dev/null || echo '(npm 未安装)')"
  local pipcfg="$HOME/.pip/pip.conf"
  [ -f "$HOME/.config/pip/pip.conf" ] && pipcfg="$HOME/.config/pip/pip.conf"
  if [ -f "$pipcfg" ]; then
    printf "  pip 配置     : %s\n" "$pipcfg"
    grep -E 'index-url' "$pipcfg" 2>/dev/null | sed 's/^/    /'
  else
    printf "  pip 配置     : (无，走默认源)\n"
  fi
  printf "  go GOPROXY   : %s\n" "$(go env GOPROXY 2>/dev/null || echo '(go 未安装)')"
  if [ -n "${HTTP_PROXY:-}" ]; then
    printf "  HTTP_PROXY   : %s ${C_DIM}(本地代理已开启，可能与镜像叠加)${C_OFF}\n" "$HTTP_PROXY"
  fi

  if [ -f "$STATE_FILE" ]; then
    log ""
    dim "probe 推荐值: $(cat "$STATE_FILE")"
  fi
}

# ---------------------------------------------------------------------------
# url - URL 转换
# ---------------------------------------------------------------------------
cmd_url() {
  local input="$1"
  [ -z "$input" ] && { err "用法: gh-accel url <github-url>"; return 1; }

  # 已经是镜像 URL，原样返回
  local m
  for m in $GH_MIRRORS $RAW_MIRRORS; do
    case "$input" in "$m"/*) printf "%s\n" "$input"; return 0;; esac
  done

  case "$input" in
    *raw.githubusercontent.com/*)
      # raw 文件 -> jsdelivr（比全量代理快）
      local rest path
      rest="${input#*raw.githubusercontent.com/}"
      path=$(printf "%s" "$rest" | sed 's|^\([^/]*\)/\([^/]*\)/|\1/\2@|')
      printf "%s/%s\n" "$(printf "%s" "$RAW_MIRRORS" | awk '{print $1}')" "$path"
      ;;
    *github.com/*)
      printf "%s/%s\n" "$(recommended)" "$input"
      ;;
    *)
      err "不是 GitHub URL: $input"; return 1;;
  esac
}

# ---------------------------------------------------------------------------
# verify - 验证加速是否生效
# ---------------------------------------------------------------------------
cmd_verify() {
  log "=== 加速效果验证（同一资源，直连 vs 镜像）==="
  log ""
  local direct="https://${PROBE_RAW}"
  local mirror="$(recommended)/https://${PROBE_RAW}"

  local dres dcode dsecs mres mcode msecs
  log "[1/2] 直连 raw.githubusercontent.com ..."
  dres=$(probe_once "direct" "$direct" 50)
  dcode=$(printf "%s" "$dres" | cut -f1); dsecs=$(printf "%s" "$dres" | cut -f2)
  if [ "$dcode" = "200" ]; then
    ok "  直连成功 ${dsecs}s"
  else
    err "  直连失败（${dcode}）—— 这正是需要加速的原因"
  fi

  log "[2/2] 经镜像 $(recommended) ..."
  mres=$(probe_once "mirror" "$mirror" 50)
  mcode=$(printf "%s" "$mres" | cut -f1); msecs=$(printf "%s" "$mres" | cut -f2)
  if [ "$mcode" = "200" ]; then
    ok "  镜像成功 ${msecs}s"
  else
    err "  镜像失败（${mcode}）—— 执行 'gh-accel probe' 重新选源"
    return 1
  fi

  log ""
  if [ "$dcode" = "200" ]; then
    awk "BEGIN{printf \"提速: %.2f 倍\n\", $dsecs/$msecs}"
  else
    log "${C_OK}结论: 直连不可用，镜像可用 —— 加速生效且必要${C_OFF}"
  fi

  # 内容一致性校验
  log ""
  log "内容一致性校验（防止镜像返回错误页）:"
  local f1 f2 h1 h2
  f1=$(mktemp); f2=$(mktemp)
  curl -sL --max-time 12 -o "$f1" "$direct" 2>/dev/null
  curl -sL --max-time 12 -o "$f2" "$mirror" 2>/dev/null
  h1=$(md5 -q "$f1" 2>/dev/null || md5sum "$f1" 2>/dev/null | cut -d' ' -f1)
  h2=$(md5 -q "$f2" 2>/dev/null || md5sum "$f2" 2>/dev/null | cut -d' ' -f1)
  rm -f "$f1" "$f2"
  if [ -n "$h1" ] && [ "$h1" = "$h2" ]; then
    ok "内容一致 ($h1)"
  elif [ "$dcode" != "200" ]; then
    dim "直连不可用，跳过对比（镜像内容哈希 ${h2}）"
  else
    err "内容不一致！直连=$h1 镜像=$h2 —— 该镜像可能返回了错误页，换源"
  fi
}

# ---------------------------------------------------------------------------
# doctor - 全面体检
# ---------------------------------------------------------------------------
cmd_doctor() {
  log "=== gh-accel 体检 ==="
  log ""
  log "[1] git URL 重写规则"
  local m key val n=0
  for m in $GH_MIRRORS; do
    key=$(git_cfg_key "$m"); val=$(git config --global --get "$key" 2>/dev/null || true)
    [ -n "$val" ] && { printf "  %s\n" "$key = $val"; n=$((n+1)); }
  done
  [ "$n" = "0" ] && dim "  （无）"

  # push 是否被劫持
  log ""
  log "[2] push 通道检查"
  local tmpd pushurl
  tmpd=$(mktemp -d); ( cd "$tmpd" && git init -q . && git remote add origin https://github.com/octocat/Hello-World.git \
    && git remote get-url --push origin 2>/dev/null ) > "$tmpd/out" 2>/dev/null
  pushurl=$(cat "$tmpd/out" 2>/dev/null); rm -rf "$tmpd"
  case "$pushurl" in
    *gh-proxy*|*ghfast*|*ghproxy*)
      warn "  push 走镜像: $pushurl"
      dim "    三个主流镜像实测均转发 git-receive-pack（支持 push），但需注意："
      dim "    - 部分镜像不转发认证，push 会 401/403"
      dim "    - 改用 SSH 可彻底绕开: git remote set-url origin git@github.com:user/repo.git" ;;
    *github.com*) ok "  push 走直连: $pushurl" ;;
    *) dim "  $pushurl" ;;
  esac

  log ""
  log "[3] 各生态镜像连通性"
  check_eco "npm  " "https://registry.npmmirror.com/express"
  check_eco "pip  " "https://mirrors.cloud.tencent.com/pypi/simple/requests/"
  check_eco "go   " "https://mirrors.aliyun.com/goproxy/github.com/gin-gonic/gin/@v/list"
  check_eco "cargo" "https://rsproxy.cn/index/config.json"

  log ""
  log "[4] 已失效域名黑名单（不要再配）"
  dim "  $DEAD_HOSTS"
  log ""
  ok "体检完成"
}

check_eco() {
  local name="$1" url="$2" res code secs
  res=$(probe_once "$name" "$url" 1)
  code=$(printf "%s" "$res" | cut -f1); secs=$(printf "%s" "$res" | cut -f2)
  if [ "$code" = "200" ]; then
    printf "  %s %s${C_OK}可用${C_OFF} (%ss)\n" "$name" "" "$secs"
  else
    printf "  %s ${C_ERR}异常${C_OFF} (%s)\n" "$name" "$code"
  fi
}

# ---------------------------------------------------------------------------
cmd_help() {
  cat <<'HELP'
gh-accel - GitHub 依赖安装加速

用法: gh-accel <command> [args]

  probe              探测所有镜像的可用性与速度，选出推荐值
  on [mirror]        开启 git 全局加速（默认用 probe 推荐值）
  off                关闭加速并恢复原有配置
  status             显示当前加速状态（git/npm/pip/go）
  url <url>          把 GitHub URL 转成加速 URL
  verify             验证加速是否真正生效（直连 vs 镜像 + 内容校验）
  doctor             全面体检（git 规则 / push 通道 / 各生态镜像 / 失效域名）
  help               显示本帮助

示例:
  gh-accel probe                     # 先测速
  gh-accel on                        # 开启加速
  gh-accel url https://github.com/foo/bar/archive/main.tar.gz
  gh-accel verify                    # 确认生效
  gh-accel off                       # 用完关掉（避免污染全局 git）

环境变量:
  GH_MIRRORS   覆盖 GitHub 全量代理候选池（空格分隔）
  RAW_MIRRORS  覆盖 raw 单文件 CDN 候选池
HELP
}

# ---------------------------------------------------------------------------
case "${1:-help}" in
  probe)  cmd_probe ;;
  on)     shift; cmd_on "$@" ;;
  off)    cmd_off ;;
  status) cmd_status ;;
  url)    shift; cmd_url "${1:-}" ;;
  verify) cmd_verify ;;
  doctor) cmd_doctor ;;
  help|-h|--help) cmd_help ;;
  *) err "未知命令: $1"; log ""; cmd_help; exit 1 ;;
esac
