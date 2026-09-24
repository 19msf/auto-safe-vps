#!/usr/bin/env bash
# Sync Cloudflare IP list to UFW rules.
# Managed by Ansible (cloudflare_ufw role). Edits will be overwritten.
set -euo pipefail

PORTS_CSV="${CF_UFW_PORTS:-80,443}"
IPV4_URL="${CF_UFW_IPV4_URL:-https://www.cloudflare.com/ips-v4}"
IPV6_URL="${CF_UFW_IPV6_URL:-https://www.cloudflare.com/ips-v6}"
ENABLE_IPV6="${CF_UFW_IPV6:-true}"
STATE_DIR="${CF_UFW_STATE_DIR:-/var/lib/cf-ufw}"
COMMENT_TAG="${CF_UFW_COMMENT:-cf-allow}"
NOTIFY_BIN="/opt/scripts/notify.sh"

mkdir -p "$STATE_DIR"
LAST_FILE="$STATE_DIR/last-ips.txt"
LOG_FILE="$STATE_DIR/sync.log"

# 防止 systemd timer 与手工/Ansible 同步同时修改 UFW。
exec 9>"$STATE_DIR/sync.lock"
if ! flock -n 9; then
  log_msg="[$(date -Iseconds)] another sync is running, skip"
  echo "$log_msg" | tee -a "$LOG_FILE"
  exit 0
fi

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"; }

notify_failure() {
  local reason="$1"
  log "FAIL: $reason"
  if [ -x "$NOTIFY_BIN" ]; then
    "$NOTIFY_BIN" cf_ufw_sync_failed "❌ Cloudflare IP 同步失败" \
      "原因=$reason" \
      "动作=保留上一次的 UFW 规则" \
      "时间=$(date -Iseconds)" \
      "主机=$(hostname)" || true
  fi
}

trap 'notify_failure "脚本异常退出（行号 $LINENO）"' ERR

fetch() {
  curl -fsSL --max-time 15 --retry 2 --retry-delay 3 "$1"
}

# 1. 拉取 CF IP 列表
TMP_IPV4="$(mktemp)"
TMP_IPV6="$(mktemp)"
trap 'rm -f "$TMP_IPV4" "$TMP_IPV6"' EXIT

if ! fetch "$IPV4_URL" > "$TMP_IPV4"; then
  notify_failure "拉取 IPv4 列表失败 ($IPV4_URL)"
  exit 1
fi
if [ ! -s "$TMP_IPV4" ]; then
  notify_failure "IPv4 列表为空"
  exit 1
fi

if [ "$ENABLE_IPV6" = "true" ]; then
  if ! fetch "$IPV6_URL" > "$TMP_IPV6"; then
    notify_failure "拉取 IPv6 列表失败 ($IPV6_URL)"
    exit 1
  fi
fi

# 2. 校验格式（CIDR）
validate() {
  local file="$1"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if ! [[ "$line" =~ ^[0-9a-fA-F:.]+/[0-9]+$ ]]; then
      return 1
    fi
  done < "$file"
}
if ! validate "$TMP_IPV4"; then
  notify_failure "IPv4 列表格式异常"
  exit 1
fi
if [ "$ENABLE_IPV6" = "true" ] && ! validate "$TMP_IPV6"; then
  notify_failure "IPv6 列表格式异常"
  exit 1
fi

# 3. 合并 + 排序，得到本次目标列表与完整状态
NEW_LIST="$(mktemp)"
TARGET_STATE="$(mktemp)"
DESIRED_RULES="$(mktemp)"
RAW_RULES="$(mktemp)"
ACTUAL_RULES="$(mktemp)"
trap 'rm -f "$TMP_IPV4" "$TMP_IPV6" "$NEW_LIST" "$TARGET_STATE" "$DESIRED_RULES" "$RAW_RULES" "$ACTUAL_RULES"' EXIT
{
  cat "$TMP_IPV4"
  [ "$ENABLE_IPV6" = "true" ] && cat "$TMP_IPV6"
} | sort -u > "$NEW_LIST"

# 端口先做严格校验，再生成用于漂移检测的目标规则集合。
IFS=',' read -ra PORTS <<< "$PORTS_CSV"
for port in "${PORTS[@]}"; do
  port="${port//[[:space:]]/}"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    notify_failure "非法端口: $port"
    exit 1
  fi
done

while IFS= read -r cidr; do
  [ -z "$cidr" ] && continue
  for port in "${PORTS[@]}"; do
    port="${port//[[:space:]]/}"
    printf '%s|%s\n' "$port" "$cidr"
  done
done < "$NEW_LIST" | sort -u > "$DESIRED_RULES"

{
  printf 'ports=%s\n' "$PORTS_CSV"
  printf 'ipv6=%s\n' "$ENABLE_IPV6"
  cat "$NEW_LIST"
} > "$TARGET_STATE"

# 同时核对实时 UFW 规则，不能只信状态文件；手工删改后的漂移必须自动修复。
managed_rules_match() {
  : > "$RAW_RULES"
  : > "$ACTUAL_RULES"
  ufw status numbered | grep -E "# ${COMMENT_TAG}$" > "$RAW_RULES" || true
  local line port cidr
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+([0-9]+)/tcp([[:space:]]+\(v6\))?[[:space:]]+ALLOW[[:space:]]+IN[[:space:]]+([^[:space:]]+) ]]; then
      port="${BASH_REMATCH[2]}"
      cidr="${BASH_REMATCH[4]}"
      printf '%s|%s\n' "$port" "$cidr" >> "$ACTUAL_RULES"
    else
      return 1
    fi
  done < "$RAW_RULES"
  sort -u -o "$ACTUAL_RULES" "$ACTUAL_RULES"
  cmp -s "$DESIRED_RULES" "$ACTUAL_RULES"
}

# 4. 配置状态和实时防火墙都一致时才跳过。
if [ -f "$LAST_FILE" ] \
  && cmp -s "$TARGET_STATE" "$LAST_FILE" \
  && managed_rules_match; then
  log "no change, skip ufw update ($(wc -l < "$NEW_LIST") cidrs)"
  exit 0
fi

log "change detected, applying ufw rules ($(wc -l < "$NEW_LIST") cidrs)"

# 添加一整套规则；任何一条失败都返回非零。
add_rules() {
  local added=0
  local failed=0
  local cidr port
  while IFS= read -r cidr; do
    [ -z "$cidr" ] && continue
    for port in "${PORTS[@]}"; do
      port="${port//[[:space:]]/}"
      if ufw allow proto tcp from "$cidr" to any port "$port" comment "$COMMENT_TAG" >/dev/null 2>&1; then
        added=$((added + 1))
      else
        failed=$((failed + 1))
        log "WARN: ufw allow failed for $cidr port $port"
      fi
    done
  done < "$NEW_LIST"
  log "rules ensured added_or_existing=$added failed=$failed"
  [ "$failed" -eq 0 ]
}

# 判断一个 CIDR + 端口是否仍在目标集合内。
is_desired() {
  local cidr="$1"
  local candidate_port="$2"
  local port
  grep -Fxq "$cidr" "$NEW_LIST" || return 1
  for port in "${PORTS[@]}"; do
    port="${port//[[:space:]]/}"
    [ "$port" = "$candidate_port" ] && return 0
  done
  return 1
}

# 仅删除已不在目标集合中的旧规则。倒序按编号删除，避免编号漂移。
delete_obsolete() {
  local line num port cidr
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+([0-9]+)/tcp([[:space:]]+\(v6\))?[[:space:]]+ALLOW[[:space:]]+IN[[:space:]]+([^[:space:]]+) ]]; then
      num="${BASH_REMATCH[1]}"
      port="${BASH_REMATCH[2]}"
      cidr="${BASH_REMATCH[4]}"
      if ! is_desired "$cidr" "$port"; then
        ufw --force delete "$num" >/dev/null
        log "removed obsolete rule cidr=$cidr port=$port"
      fi
    else
      log "WARN: cannot parse managed UFW rule, keeping it: $line"
    fi
  done < <(ufw status numbered | grep -E "# ${COMMENT_TAG}$" | tac || true)
}

# 5. 先补齐全部新规则；任何失败都保留旧规则并中止。
if ! add_rules; then
  notify_failure "添加 Cloudflare 规则失败；旧规则已保留"
  exit 1
fi

# 6. 新规则完整存在后，再删除不再需要的旧规则。
delete_obsolete

# 7. 重载 ufw
ufw reload >/dev/null

# 8. 仅在整套规则成功后保存完整状态
cp "$TARGET_STATE" "$LAST_FILE"
log "applied $(wc -l < "$NEW_LIST") cidrs to ports $PORTS_CSV"

# 9. 通知（仅在变化时发）
if [ -x "$NOTIFY_BIN" ]; then
  "$NOTIFY_BIN" cf_ufw_sync_updated "✅ Cloudflare IP 列表已更新" \
    "新条目数=$(wc -l < "$NEW_LIST")" \
    "端口=$PORTS_CSV" \
    "时间=$(date -Iseconds)" \
    "主机=$(hostname)" || true
fi
