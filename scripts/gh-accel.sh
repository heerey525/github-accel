#!/usr/bin/env bash
# gh-accel - 多生态镜像源管理器（GitHub / npm / pip / go / cargo）
# 交互参考 nrm：ls / use / test / add / rm
# 兼容 macOS 自带 bash 3.2（不使用关联数组 / mapfile 等 bash4 特性）
#
# 用法: gh-accel <command> [args]

set -uo pipefail

# 输出被 head/tail 截断时不刷 Broken pipe 噪音
trap '' PIPE 2>/dev/null || true

# ---------------------------------------------------------------------------
# 内置镜像源表
# 格式: eco|name|url|备注
# 增删内置源只改这里；用户自定义源写入 $USER_MIRRORS（同格式，同名覆盖）
# ---------------------------------------------------------------------------
MIRROR_DB="github|ssh|ssh|走 SSH，可推送、抗 443 抖动（等价 git-mng route ssh）
github|gh-proxy|https://gh-proxy.com|只读镜像，release 实测最快
github|ghfast|https://ghfast.top|只读镜像，次选
github|ghproxy-net|https://ghproxy.net|只读镜像，较慢
github|direct|https://github.com|HTTPS 直连，国内常超时
npm|npm|https://registry.npmjs.org/|官方
npm|taobao|https://registry.npmmirror.com/|阿里 npmmirror
npm|tencent|https://mirrors.cloud.tencent.com/npm/|腾讯云
npm|huawei|https://repo.huaweicloud.com/repository/npm/|华为云
npm|cnpm|https://r.cnpmjs.org/|cnpm，较慢
npm|yarn|https://registry.yarnpkg.com/|yarn 官方
pip|tencent|https://mirrors.cloud.tencent.com/pypi/simple/|腾讯云
pip|aliyun|https://mirrors.aliyun.com/pypi/simple/|阿里云
pip|ustc|https://pypi.mirrors.ustc.edu.cn/simple/|中科大
pip|tuna|https://pypi.tuna.tsinghua.edu.cn/simple/|清华
pip|pypi|https://pypi.org/simple/|官方
go|aliyun|https://mirrors.aliyun.com/goproxy/|阿里云
go|goproxy-cn|https://goproxy.cn|七牛
go|goproxy-io|https://goproxy.io|goproxy.io
go|bcebos|https://goproxy.bj.bcebos.com/|百度云
go|direct|direct|不走代理，直连
cargo|rsproxy|sparse+https://rsproxy.cn/index/|字节
cargo|tuna|sparse+https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/|清华
cargo|crates-io|https://github.com/rust-lang/crates.io-index|官方 git index"

# 仅用于 raw 单文件的 CDN（不支持 release 资产、不支持 git clone）
RAW_MIRRORS="https://fastly.jsdelivr.net/gh https://cdn.jsdelivr.net/gh"

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gh-accel"
STATE_FILE="$CONF_DIR/state"
BACKUP_FILE="$CONF_DIR/git-url-backup"
USER_MIRRORS="$CONF_DIR/mirrors.conf"

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
bold() { printf "\033[1m%b\033[0m\n" "$*"; }

mkdir -p "$CONF_DIR"

# ---------------------------------------------------------------------------
# 源表查询
# ---------------------------------------------------------------------------
mirror_rows() {
  { printf '%s\n' "$MIRROR_DB"
    [ -f "$USER_MIRRORS" ] && cat "$USER_MIRRORS" 2>/dev/null
  } | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}

mirror_url() {
  mirror_rows | awk -F'|' -v E="$1" -v N="$2" '$1==E && $2==N {print $3; exit}'
}

mirror_note() {
  mirror_rows | awk -F'|' -v E="$1" -v N="$2" '$1==E && $2==N {print $4; exit}'
}

mirror_names() {
  mirror_rows | awk -F'|' -v E="$1" '$1==E {print $2}'
}

mirror_ecos() {
  mirror_rows | awk -F'|' '{print $1}' | awk '!s[$0]++'
}

eco_title() {
  case "$1" in
    github) echo "GitHub 路由" ;;
    npm)    echo "npm registry" ;;
    pip)    echo "pip index" ;;
    go)     echo "Go GOPROXY" ;;
    cargo)  echo "Cargo 源" ;;
    *)      echo "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# 各生态「当前源」检测
# ---------------------------------------------------------------------------
pip_conf_path() {
  if [ -f "$HOME/.pip/pip.conf" ] && [ ! -f "$HOME/.config/pip/pip.conf" ]; then
    printf '%s' "$HOME/.pip/pip.conf"
  else
    printf '%s' "$HOME/.config/pip/pip.conf"
  fi
}

current_mirror() {
  case "$1" in
    github)
      if [ "$(git config --global --get 'url.git@github.com:.insteadOf' 2>/dev/null)" = "https://github.com/" ]; then
        printf 'ssh'; return 0
      fi
      local found="" eco n u note
      while IFS='|' read -r eco n u note; do
        [ "$eco" = "github" ] || continue
        case "$u" in ssh|https://github.com) continue ;; esac
        if [ "$(git config --global --get "url.${u}/https://github.com/.insteadOf" 2>/dev/null)" = "https://github.com/" ]; then
          found="$n"; break
        fi
      done <<EOF
$(mirror_rows)
EOF
      printf '%s' "$found"
      ;;
    npm)
      command -v npm >/dev/null 2>&1 || return 0
      local r; r=$(npm config get registry 2>/dev/null)
      mirror_rows | awk -F'|' -v R="$r" '$1=="npm" && $3==R {print $2; exit}'
      ;;
    pip)
      local f; f=$(pip_conf_path)
      [ -f "$f" ] || return 0
      local r; r=$(grep -E '^[[:space:]]*index-url[[:space:]]*=' "$f" 2>/dev/null | tail -1 | sed 's/.*=[[:space:]]*//' | tr -d ' ')
      mirror_rows | awk -F'|' -v R="$r" '$1=="pip" && $3==R {print $2; exit}'
      ;;
    go)
      command -v go >/dev/null 2>&1 || return 0
      local r; r=$(go env GOPROXY 2>/dev/null | sed 's/,direct$//')
      mirror_rows | awk -F'|' -v R="$r" '$1=="go" && $3==R {print $2; exit}'
      ;;
    cargo)
      local f="$HOME/.cargo/config.toml"
      [ -f "$f" ] || return 0
      local r; r=$(grep -E '^[[:space:]]*registry[[:space:]]*=' "$f" 2>/dev/null | tail -1 | sed 's/.*=[[:space:]]*//' | tr -d '" ')
      mirror_rows | awk -F'|' -v R="$r" '$1=="cargo" && $3==R {print $2; exit}'
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 各生态「应用」逻辑
# ---------------------------------------------------------------------------
apply_github() {
  local name="$1" url="$2" eco n u note
  # 统一清理：git-mng 的 ssh key + 本表所有 github 镜像 key
  git config --global --unset 'url.git@github.com:.insteadOf' 2>/dev/null
  while IFS='|' read -r eco n u note; do
    [ "$eco" = "github" ] || continue
    case "$u" in ssh|https://github.com) continue ;; esac
    git config --global --unset "url.${u}/https://github.com/.insteadOf" 2>/dev/null
  done <<EOF
$(mirror_rows)
EOF
  case "$url" in
    ssh)
      git config --global 'url.git@github.com:.insteadOf' 'https://github.com/'
      ok "GitHub 路由 → ssh（与 git-mng route ssh 等价）"
      ;;
    https://github.com)
      ok "GitHub 路由 → direct（已清除所有重写规则）"
      ;;
    *)
      git config --global "url.${url}/https://github.com/.insteadOf" 'https://github.com/'
      ok "GitHub 路由 → ${url}"
      warn "镜像只读，push 请用 ssh 源（gh-accel use github ssh）"
      ;;
  esac
}

apply_npm() {
  command -v npm >/dev/null 2>&1 || { err "npm 未安装"; return 1; }
  if npm config set registry "$1" >/dev/null 2>&1; then
    ok "npm registry → $1"
  else
    err "设置失败"; return 1
  fi
}

apply_pip() {
  local url="$1" f
  f=$(pip_conf_path)
  mkdir -p "$(dirname "$f")" 2>/dev/null
  if command -v pip >/dev/null 2>&1 && pip config set global.index-url "$url" >/dev/null 2>&1; then
    ok "pip index-url → $url"
    return 0
  fi
  # 回退：直接写文件（保留其它段落）
  local tmp; tmp=$(mktemp)
  [ -f "$f" ] && grep -v -E '^[[:space:]]*index-url' "$f" > "$tmp" 2>/dev/null
  if ! grep -q '^\[global\]' "$tmp" 2>/dev/null; then
    printf '[global]\n' >> "$tmp"
  fi
  printf 'index-url = %s\n' "$url" >> "$tmp"
  mv "$tmp" "$f"
  ok "pip index-url → $url（写入 $f）"
}

apply_go() {
  command -v go >/dev/null 2>&1 || { err "go 未安装"; return 1; }
  local url="$1"
  case "$url" in
    direct) go env -w GOPROXY=direct >/dev/null 2>&1 ;;
    *)      go env -w GOPROXY="${url},direct" >/dev/null 2>&1 ;;
  esac
  [ $? -eq 0 ] && ok "Go GOPROXY → $url" || { err "设置失败"; return 1; }
}

apply_cargo() {
  local url="$1" f="$HOME/.cargo/config.toml"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  if [ -f "$f" ] && grep -q 'source.crates-io' "$f" 2>/dev/null; then
    warn "$f 已有 crates-io 配置，未自动改动"
    dim "  请手动把 registry 改为: $url"
    return 1
  fi
  {
    printf '\n[source.crates-io]\n'
    printf "replace-with = 'gh-accel'\n\n"
    printf '[source.gh-accel]\n'
    printf 'registry = "%s"\n' "$url"
  } >> "$f"
  ok "Cargo 源 → $url（写入 $f）"
}

apply_mirror() {
  local eco="$1" name="$2" url
  url=$(mirror_url "$eco" "$name")
  if [ -z "$url" ]; then
    err "未知源: ${eco}/${name}"
    dim "  可用: $(mirror_names "$eco" | tr '\n' ' ')"
    return 1
  fi
  case "$eco" in
    github) apply_github "$name" "$url" ;;
    npm)    apply_npm "$url" ;;
    pip)    apply_pip "$url" ;;
    go)     apply_go "$url" ;;
    cargo)  apply_cargo "$url" ;;
    *)      err "不支持的生态: $eco"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 测速
# ---------------------------------------------------------------------------
speed_probe_url() {
  # $1=eco $2=url -> 用于测速的 HTTP URL；返回非 0 表示该源无法用 HTTP 探测
  local eco="$1" u="$2" base
  case "$u" in
    ssh) return 1 ;;
    direct)
      case "$eco" in
        github) printf 'https://github.com' ;;
        go)     printf 'https://goproxy.cn' ;;
        *)      printf '%s' "$u" ;;
      esac
      return 0 ;;
  esac
  # cargo 的 git index（非 sparse）无法用 HTTP 探测
  if [ "$eco" = "cargo" ]; then
    case "$u" in sparse+*) ;; *) return 1 ;; esac
  fi
  u="${u#sparse+}"
  base=$(printf '%s' "$u" | sed 's#/*$#/#')
  case "$eco" in
    github) printf '%shttps://raw.githubusercontent.com/torvalds/linux/master/README' "$base" ;;
    npm)    printf '%sexpress' "$base" ;;
    pip)    printf '%srequests/' "$base" ;;
    go)     printf '%sgithub.com/gin-gonic/gin/@v/list' "$base" ;;
    cargo)  printf '%sconfig.json' "$base" ;;
    *)      printf '%s' "$u" ;;
  esac
  return 0
}

speed_of() {
  # $1=eco $2=url -> "code<TAB>seconds"
  local u res
  if ! u=$(speed_probe_url "$1" "$2"); then
    printf -- '-\t-'; return
  fi
  res=$(curl -sL --max-time 10 -o /dev/null -w '%{http_code}\t%{time_total}' "$u" 2>/dev/null)
  [ -z "$res" ] && res="000\t-"
  printf '%s' "$res"
}

cmd_test() {
  local filter="${1:-}" eco cur
  for eco in $(mirror_ecos); do
    [ -n "$filter" ] && [ "$eco" != "$filter" ] && continue
    cur=$(current_mirror "$eco")
    bold "$(eco_title "$eco")"
    printf '  %-14s %-8s %-10s %s\n' "源" "状态" "耗时" "地址"
    local eco2 n u note res code secs mark tshow
    while IFS='|' read -r eco2 n u note; do
      [ "$eco2" = "$eco" ] || continue
      res=$(speed_of "$eco" "$u")
      code=$(printf '%s' "$res" | cut -f1)
      secs=$(printf '%s' "$res" | cut -f2)
      mark=" "
      [ "$n" = "$cur" ] && mark="*"
      if [ "$code" = "-" ]; then tshow="-"; else tshow="${secs}s"; fi
      printf '  %s%-13s %-8s %-10s %s\n' "$mark" "$n" "$code" "$tshow" "$u"
    done <<EOF
$(mirror_rows)
EOF
    echo
  done
  dim "状态 200=通；404=路径不通（可能仅根路径）；000=超时/失败；- =不适用"
}

# ---------------------------------------------------------------------------
# ls / use / add / rm
# ---------------------------------------------------------------------------
cmd_ls() {
  local filter="${1:-}" eco cur
  for eco in $(mirror_ecos); do
    [ -n "$filter" ] && [ "$eco" != "$filter" ] && continue
    cur=$(current_mirror "$eco")
    bold "$(eco_title "$eco")"
    local eco2 n u note mark pad fill
    while IFS='|' read -r eco2 n u note; do
      [ "$eco2" = "$eco" ] || continue
      mark=" "
      [ "$n" = "$cur" ] && mark="*"
      pad=$((12 - ${#n}))
      [ "$pad" -lt 1 ] && pad=1
      fill=$(printf '%*s' "$pad" '' | tr ' ' '-')
      printf '  %s %s %s %s' "$mark" "$n" "$fill" "$u"
      [ -n "$note" ] && printf "  ${C_DIM}# %s${C_OFF}" "$note"
      printf '\n'
    done <<EOF
$(mirror_rows)
EOF
    if [ -z "$cur" ]; then
      case "$eco" in
        go|cargo)
          if command -v "$eco" >/dev/null 2>&1; then
            dim "    （未设置）"
          else
            dim "    （本机未安装 ${eco}）"
          fi ;;
        *) dim "    （未设置或非内置源）" ;;
      esac
    fi
    echo
  done
  dim "用法: gh-accel use <eco> <name>   |   gh-accel test [eco]   |   gh-accel add <eco> <name> <url> [备注]"
}

cmd_use() {
  local eco="$1" name="${2:-}"
  if [ -z "$eco" ] || [ -z "$name" ]; then
    err "用法: gh-accel use <eco> <name>"
    dim "  生态: $(mirror_ecos | tr '\n' ' ')"
    return 1
  fi
  apply_mirror "$eco" "$name"
}

cmd_add() {
  local eco="$1" name="$2" url="$3" note="${4:-自定义源}"
  if [ -z "$eco" ] || [ -z "$name" ] || [ -z "$url" ]; then
    err "用法: gh-accel add <eco> <name> <url> [备注]"
    return 1
  fi
  if [ -n "$(mirror_url "$eco" "$name")" ]; then
    warn "源 ${eco}/${name} 已存在，先删除再添加：gh-accel rm ${eco} ${name}"
    return 1
  fi
  printf '%s|%s|%s|%s\n' "$eco" "$name" "$url" "$note" >> "$USER_MIRRORS"
  ok "已添加 ${eco}/${name} → ${url}"
  dim "  写入 $USER_MIRRORS"
}

cmd_rm() {
  local eco="$1" name="${2:-}"
  if [ -z "$eco" ] || [ -z "$name" ]; then
    err "用法: gh-accel rm <eco> <name>"
    return 1
  fi
  if [ ! -f "$USER_MIRRORS" ] || ! grep -q "^${eco}|${name}|" "$USER_MIRRORS" 2>/dev/null; then
    err "${eco}/${name} 不是自定义源（内置源不可删除）"
    return 1
  fi
  local tmp; tmp=$(mktemp)
  grep -v "^${eco}|${name}|" "$USER_MIRRORS" > "$tmp"
  mv "$tmp" "$USER_MIRRORS"
  ok "已删除 ${eco}/${name}"
}

# ---------------------------------------------------------------------------
# 底层探测（GitHub 专项）
# ---------------------------------------------------------------------------
probe_once() {
  local name="$1" url="$2" minbytes="${3:-1}"
  local res code secs size
  res=$(curl -sL --max-time 12 -o /dev/null \
        -w "%{http_code}\t%{time_total}\t%{size_download}" "$url" 2>/dev/null)
  [ -z "$res" ] && res="000\t0\t0"
  code=$(printf "%s" "$res" | cut -f1)
  secs=$(printf "%s" "$res" | cut -f2)
  size=$(printf "%s" "$res" | cut -f3)
  if [ "$code" = "200" ] && [ "$size" -lt "$minbytes" ] 2>/dev/null; then
    code="SHORT"
  fi
  printf "%s\t%s\t%s" "$code" "$secs" "$size"
}

pick_first_ok() {
  local kind="$1" pool url res code
  if [ "$kind" = "raw" ]; then
    pool="$RAW_MIRRORS"
    for m in $pool; do
      url="${m}/torvalds/linux@master/README"
      res=$(probe_once "$m" "$url" 50); code=$(printf "%s" "$res" | cut -f1)
      [ "$code" = "200" ] && { printf "%s" "$m"; return 0; }
    done
  else
    pool=$(mirror_rows | awk -F'|' '$1=="github" && $3 ~ /^https:\/\// && $3 != "https://github.com" {print $3}')
    for m in $pool; do
      url="${m}/https://${PROBE_RAW}"
      res=$(probe_once "$m" "$url" 50); code=$(printf "%s" "$res" | cut -f1)
      [ "$code" = "200" ] && { printf "%s" "$m"; return 0; }
    done
  fi
  return 1
}

cmd_probe() {
  log "探测 GitHub 代理镜像（超时 12s，含内容校验）..."
  log ""
  printf "%-26s %-8s %-10s %-12s %s\n" "镜像" "状态" "耗时" "吞吐" "备注"
  printf "%s\n" "--------------------------------------------------------------------------"

  local best_gh="" best_time=999
  local m url res code secs size speed note
  for m in $(mirror_rows | awk -F'|' '$1=="github" && $3 ~ /^https:\/\// && $3 != "https://github.com" {print $3}'); do
    url="${m}/https://${PROBE_REL}"
    res=$(probe_once "$m" "$url" 100000)
    code=$(printf "%s" "$res" | cut -f1); secs=$(printf "%s" "$res" | cut -f2); size=$(printf "%s" "$res" | cut -f3)
    note=""
    case "$code" in
      200) note="可用"
           if awk "BEGIN{exit !($secs < $best_time)}"; then best_time="$secs"; best_gh="$m"; fi ;;
      SHORT) note="返回内容异常" ;;
      000)   note="超时/连接失败" ;;
      *)     note="HTTP $code" ;;
    esac
    speed="-"
    [ "$code" = "200" ] && [ "$size" -gt 0 ] 2>/dev/null && \
      speed=$(awk "BEGIN{printf \"%.0f KB/s\", $size/1024/$secs}")
    printf "%-26s %-8s %-10s %-12s %s\n" "$m" "$code" "${secs}s" "$speed" "$note"
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
    local best_name; best_name=$(mirror_rows | awk -F'|' -v U="$best_gh" '$1=="github" && $3==U {print $2; exit}')
    ok "推荐镜像: ${best_gh}  (release 实测 ${best_time}s)"
    dim "  应用: gh-accel use github ${best_name:-gh-proxy}"
  else
    err "所有 GitHub 代理均不可用 —— 检查网络，或改用 ssh 源"
    return 1
  fi
}

recommended() {
  if [ -f "$STATE_FILE" ]; then
    cut -d' ' -f1 < "$STATE_FILE"
  else
    printf '%s' "$(mirror_rows | awk -F'|' '$1=="github" && $3 ~ /^https:\/\// && $3 != "https://github.com" {print $3; exit}')"
  fi
}

# ---------------------------------------------------------------------------
# on / off（向后兼容，等价 use github <name>）
# ---------------------------------------------------------------------------
cmd_on() {
  local arg="${1:-}"
  if [ -z "$arg" ]; then
    local rec n
    rec=$(recommended)
    n=$(mirror_rows | awk -F'|' -v U="$rec" '$1=="github" && $3==U {print $2; exit}')
    arg="${n:-gh-proxy}"
  fi
  case "$arg" in
    *://*)
      local n2; n2=$(mirror_rows | awk -F'|' -v U="$arg" '$1=="github" && $3==U {print $2; exit}')
      if [ -n "$n2" ]; then
        arg="$n2"
      else
        # 未登记的 URL：直接按镜像规则应用
        if [ ! -f "$BACKUP_FILE" ]; then
          git config --global --get-regexp '^url\..*\.insteadof$' > "$BACKUP_FILE" 2>/dev/null
        fi
        apply_github "$arg" "$arg"
        return $?
      fi
      ;;
  esac
  cmd_use github "$arg"
}

cmd_off() {
  if [ ! -f "$BACKUP_FILE" ]; then
    git config --global --get-regexp '^url\..*\.insteadof$' > "$BACKUP_FILE" 2>/dev/null
    dim "已备份当前 insteadOf 配置 → $BACKUP_FILE"
  fi
  local m found=0
  git config --global --unset 'url.git@github.com:.insteadOf' 2>/dev/null && found=1
  for m in $(mirror_rows | awk -F'|' '$1=="github" && $3 ~ /^https:\/\// {print $3}'); do
    if git config --global --get "url.${m}/https://github.com/.insteadOf" >/dev/null 2>&1; then
      git config --global --unset "url.${m}/https://github.com/.insteadOf"
      ok "已移除 ${m} 规则"
      found=1
    fi
  done
  [ "$found" = "0" ] && dim "没有本工具写入的规则需要移除"
  ok "GitHub 加速已关闭（走直连）"
}

# ---------------------------------------------------------------------------
# status / url / verify / doctor
# ---------------------------------------------------------------------------
cmd_status() {
  log "=== gh-accel 状态 ==="
  local eco cur n
  for eco in $(mirror_ecos); do
    cur=$(current_mirror "$eco")
    if [ -n "$cur" ]; then
      printf "  %-12s ${C_OK}%s${C_OFF}\n" "$(eco_title "$eco")" "$cur"
    else
      case "$eco" in
        go|cargo)
          command -v "$eco" >/dev/null 2>&1 || { printf "  %-12s ${C_DIM}(未安装)${C_OFF}\n" "$(eco_title "$eco")"; continue; } ;;
      esac
      printf "  %-12s ${C_DIM}(非内置源或未设置)${C_OFF}\n" "$(eco_title "$eco")"
    fi
  done
  log ""
  if [ -n "${HTTP_PROXY:-}" ]; then
    dim "HTTP_PROXY=${HTTP_PROXY}（本地代理已开启，可能与镜像叠加）"
  fi
  if [ -f "$STATE_FILE" ]; then
    dim "probe 推荐值: $(cat "$STATE_FILE")"
  fi
}

cmd_url() {
  local input="$1"
  [ -z "$input" ] && { err "用法: gh-accel url <github-url>"; return 1; }

  local m
  for m in $(mirror_rows | awk -F'|' '$1=="github" && $3 ~ /^https:\/\// {print $3}') $RAW_MIRRORS; do
    case "$input" in "$m"/*) printf "%s\n" "$input"; return 0;; esac
  done

  case "$input" in
    *raw.githubusercontent.com/*)
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

cmd_verify() {
  log "=== 加速效果验证（同一资源，直连 vs 镜像）==="
  log ""
  local direct="https://${PROBE_RAW}"
  local mir; mir=$(recommended)
  local mirror="${mir}/https://${PROBE_RAW}"

  local dres dcode dsecs mres mcode msecs
  log "[1/2] 直连 raw.githubusercontent.com ..."
  dres=$(probe_once "direct" "$direct" 50)
  dcode=$(printf "%s" "$dres" | cut -f1); dsecs=$(printf "%s" "$dres" | cut -f2)
  if [ "$dcode" = "200" ]; then
    ok "  直连成功 ${dsecs}s"
  else
    err "  直连失败（${dcode}）—— 这正是需要加速的原因"
  fi

  log "[2/2] 经镜像 ${mir} ..."
  mres=$(probe_once "mirror" "$mirror" 50)
  mcode=$(printf "%s" "$mres" | cut -f1); msecs=$(printf "%s" "$mres" | cut -f2)
  if [ "$mcode" = "200" ]; then
    ok "  镜像成功 ${msecs}s"
  else
    err "  镜像失败（${mcode}）—— 执行 'gh-accel test github' 重新选源"
    return 1
  fi

  log ""
  if [ "$dcode" = "200" ]; then
    awk "BEGIN{printf \"提速: %.2f 倍\n\", $dsecs/$msecs}"
  else
    log "${C_OK}结论: 直连不可用，镜像可用 —— 加速生效且必要${C_OFF}"
  fi

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
    ok "内容一致 (${h1})"
  elif [ "$dcode" != "200" ]; then
    dim "直连不可用，跳过对比（镜像内容哈希 ${h2}）"
  else
    err "内容不一致！直连=${h1} 镜像=${h2} —— 该镜像可能返回了错误页，换源"
  fi
}

cmd_doctor() {
  log "=== gh-accel 体检 ==="
  log ""
  log "[1] GitHub 路由"
  local cur; cur=$(current_mirror github)
  if [ -n "$cur" ]; then
    ok "  当前源: ${cur}"
  else
    dim "  未匹配内置源"
  fi

  log ""
  log "[2] push 通道检查"
  local tmpd pushurl
  tmpd=$(mktemp -d)
  ( cd "$tmpd" && git init -q . && git remote add origin https://github.com/octocat/Hello-World.git \
    && git remote get-url --push origin 2>/dev/null ) > "$tmpd/out" 2>/dev/null
  pushurl=$(cat "$tmpd/out" 2>/dev/null); rm -rf "$tmpd"
  case "$pushurl" in
    git@github.com:*) ok "  push 走 SSH: ${pushurl}" ;;
    *gh-proxy*|*ghfast*|*ghproxy*)
      warn "  push 走镜像: ${pushurl}"
      dim "    镜像通常不转发认证，push 可能 401。建议改用: gh-accel use github ssh" ;;
    *github.com*) ok "  push 走直连: ${pushurl}" ;;
    *) dim "  ${pushurl}" ;;
  esac

  log ""
  log "[3] SSH 连通性"
  local sshout
  sshout=$(ssh -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -T git@github.com 2>&1 | head -1)
  case "$sshout" in
    *successfully\ authenticated*) ok "  ${sshout}" ;;
    "") err "  SSH 无响应（22 端口可能被拦）" ;;
    *)  err "  ${sshout}" ;;
  esac

  log ""
  log "[4] 各生态可用性"
  check_eco "npm  " "https://registry.npmmirror.com/express"
  check_eco "pip  " "https://mirrors.cloud.tencent.com/pypi/simple/requests/"
  check_eco "go   " "https://mirrors.aliyun.com/goproxy/github.com/gin-gonic/gin/@v/list"
  check_eco "cargo" "https://rsproxy.cn/index/config.json"

  log ""
  log "[5] 已失效域名黑名单（不要再配）"
  dim "  ${DEAD_HOSTS}"
  log ""
  ok "体检完成"
}

check_eco() {
  local name="$1" url="$2" res code secs
  res=$(probe_once "$name" "$url" 1)
  code=$(printf "%s" "$res" | cut -f1); secs=$(printf "%s" "$res" | cut -f2)
  if [ "$code" = "200" ]; then
    printf "  %s ${C_OK}可用${C_OFF} (%ss)\n" "$name" "$secs"
  else
    printf "  %s ${C_ERR}异常${C_OFF} (%s)\n" "$name" "$code"
  fi
}

# ---------------------------------------------------------------------------
cmd_help() {
  cat <<'HELP'
gh-accel - 多生态镜像源管理器（参考 nrm 交互）

用法: gh-accel <command> [args]

源管理:
  ls [eco]                     列出所有镜像源（* 标记当前使用）
  use <eco> <name>             切换源
  test [eco]                   测速对比
  add <eco> <name> <url> [备注]  添加自定义源
  rm <eco> <name>              删除自定义源

生态 (eco): github | npm | pip | go | cargo

GitHub 专项:
  probe                        实测各镜像速度，选出推荐值
  on [name|url]                开启 GitHub 加速（等价 use github）
  off                          关闭 GitHub 加速
  url <github-url>             把 GitHub URL 转成加速 URL
  verify                       验证加速是否生效（直连 vs 镜像 + 内容校验）

其它:
  status                       总览各生态当前源
  doctor                       体检（路由 / push 通道 / SSH / 各生态 / 失效域名）
  help                         显示本帮助

示例:
  gh-accel ls                        看所有源和当前值
  gh-accel use npm taobao            切 npm 到阿里源
  gh-accel use github ssh            切 GitHub 到 SSH 路由
  gh-accel test github               测 GitHub 各镜像速度
  gh-accel add pip corp https://pypi.corp.local/simple/  加自定义源
  gh-accel rm pip corp               删自定义源

环境变量:
  XDG_CONFIG_HOME   配置目录（默认 ~/.config）
HELP
}

# ---------------------------------------------------------------------------
case "${1:-help}" in
  ls)     shift; cmd_ls "${1:-}" ;;
  use)    shift; cmd_use "${1:-}" "${2:-}" ;;
  test)   shift; cmd_test "${1:-}" ;;
  add)    shift; cmd_add "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
  rm)     shift; cmd_rm "${1:-}" "${2:-}" ;;
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
