#!/usr/bin/env bash
# 先提示输入 -> 再安装/运行 的 Aztec CLI 一键脚本（前台运行）
# 用法：sudo -E ./aztec_cli_run.sh

# --- 确保用 bash 运行 ---
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
set -Eeuo pipefail
umask 022
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ===== 基础路径/权限 =====
[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行：sudo -E $0"; exit 1; }
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(eval echo "~$TARGET_USER")"
TARGET_BASHRC="$TARGET_HOME/.bashrc"
CONFIG_DIR="/etc/aztec-node"
CONFIG_FILE="$CONFIG_DIR/config.env"
LOG_DIR="/var/log/aztec-node"
mkdir -p "$CONFIG_DIR" "$LOG_DIR"; chmod 700 "$CONFIG_DIR"; touch "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"

# ===== 彩色输出 =====
c(){ printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
info(){ c "1;34" "ℹ️  $*"; }; ok(){ c "1;32" "✓ $*"; }; warn(){ c "1;33" "⚠️  $*"; }; err(){ c "1;31" "✗ $*"; }

# ===== 读入旧配置（如有）=====
# shellcheck disable=SC1090
source "$CONFIG_FILE" || true

# ===== 校验函数 =====
is_url(){ [[ "${1:-}" =~ ^https?:// ]]; }
is_privkey(){ [[ "${1:-}" =~ ^0x[0-9a-fA-F]{64}$ ]]; }
is_ethaddr(){ [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_ipv4(){ [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# ===== 安全输入（支持默认/保密/最多重试）=====
ASK_TRIES=5
ask_url(){
  local var="$1" prompt="$2" curr input
  curr="${!var-}"
  for ((i=1;i<=ASK_TRIES;i++)); do
    read -r -p "$prompt${curr:+ [默认: $curr]}: " input
    [[ -z "$input" ]] && input="$curr"
    if is_url "$input"; then printf -v "$var" '%s' "$input"; return 0; fi
    err "URL 无效（需 http:// 或 https://）($i/$ASK_TRIES)"
  done
  err "多次失败，退出。"; exit 10
}
ask_secret(){
  local var="$1" prompt="$2" validator="$3" curr input
  curr="${!var-}"
  for ((i=1;i<=ASK_TRIES;i++)); do
    if [[ -n "$curr" ]]; then
      read -r -s -p "$prompt [已保存，回车不变]: " input; echo
      [[ -z "$input" ]] && { printf -v "$var" '%s' "$curr"; return 0; }
    else
      read -r -s -p "$prompt: " input; echo
    fi
    if "$validator" "$input"; then printf -v "$var" '%s' "$input"; return 0; fi
    err "格式不正确 ($i/$ASK_TRIES)"
  done
  err "多次失败，退出。"; exit 11
}
ask_plain(){
  local var="$1" prompt="$2" validator="$3" curr input
  curr="${!var-}"
  for ((i=1;i<=ASK_TRIES;i++)); do
    read -r -p "$prompt${curr:+ [默认: $curr]}: " input
    [[ -z "$input" ]] && input="$curr"
    if "$validator" "$input"; then printf -v "$var" '%s' "$input"; return 0; fi
    err "格式不正确 ($i/$ASK_TRIES)"
  done
  err "多次失败，退出。"; exit 12
}

# ===== 公网 IP 侦测（可为空）=====
PUB_IP="${PUB_IP:-$(curl -4 -fsS icanhazip.com || curl -4 -fsS ifconfig.co || true)}"
[[ -n "${PUB_IP:-}" ]] && ok "检测到公网 IPv4：$PUB_IP" || warn "未能自动获取公网 IPv4。"

# ===== 先提示输入（再执行安装/运行）=====
info "请输入运行所需变量（回车可沿用历史值，最多重试 $ASK_TRIES 次）："
ask_url ETHEREUM_HOSTS "EL RPC URL（执行层，示例：https://eth-sepolia.g.alchemy.com/v2/xxxx）"
ask_url L1_CONSENSUS_HOST_URLS "CL RPC URL（Beacon 共识层，示例：https://.../beacon）"
ask_secret VALIDATOR_PRIVATE_KEY "验证者私钥（0x+64hex）" is_privkey
ask_plain COINBASE "COINBASE 地址（0x+40hex）" is_ethaddr
# P2P_IP 可选：留空时自动用检测到的公网 IPv4
read -r -p "P2P 对外 IPv4（可回车自动使用检测值 ${PUB_IP:-<无>}）: " P2P_IN
if [[ -z "$P2P_IN" ]]; then
  P2P_IP="${P2P_IP:-$PUB_IP}"
else
  is_ipv4 "$P2P_IN" || { err "IPv4 格式不正确"; exit 13; }
  P2P_IP="$P2P_IN"
fi

# ===== 确认摘要 =====
echo "----------------------------------"
echo "EL RPC: $ETHEREUM_HOSTS"
echo "CL RPC: $L1_CONSENSUS_HOST_URLS"
echo "COINBASE: $COINBASE"
echo "P2P_IP: ${P2P_IP:-<未设置>（将由 CLI/环境决定）}"
echo "私钥: ****${VALIDATOR_PRIVATE_KEY: -6}"
echo "----------------------------------"
read -r -p "确认以上信息并继续安装/运行？(y/N): " _go
[[ "$_go" =~ ^[yY]$ ]] || { warn "已取消。"; exit 0; }

# ===== 保存配置（仅 root 可读）=====
cat > "$CONFIG_FILE" <<EOF
ETHEREUM_HOSTS="$ETHEREUM_HOSTS"
L1_CONSENSUS_HOST_URLS="$L1_CONSENSUS_HOST_URLS"
VALIDATOR_PRIVATE_KEY="$VALIDATOR_PRIVATE_KEY"
COINBASE="$COINBASE"
P2P_IP="${P2P_IP-}"
EOF
chmod 600 "$CONFIG_FILE"
ok "配置已保存：$CONFIG_FILE"

# ===== 依赖 =====
info "安装通用依赖（curl gnupg lsb-release jq netcat-openbsd ufw）…"
apt-get update -y -o Acquire::Retries=3
apt-get install -y ca-certificates curl gnupg lsb-release jq netcat-openbsd ufw

# ===== Docker（keyrings 稳定安装；失败降级到 docker.io）=====
if ! command -v docker >/dev/null 2>&1; then
  info "安装 Docker（官方源 + keyrings）…"
  rm -f /etc/apt/keyrings/docker.gpg || true
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 20 --ipv4 \
    https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y || true
  if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    warn "官方仓库安装失败，回退系统仓库：docker.io"
    apt-get install -y docker.io docker-compose-plugin
  fi
  systemctl enable --now docker
  usermod -aG docker "${SUDO_USER:-$USER}" || true
  ok "Docker 安装完成。"
else
  ok "Docker 已安装：$(docker --version | head -n1)"
  systemctl enable --now docker
fi

# ===== UFW =====
info "配置 UFW（22 / 40400 TCP+UDP / 8080）…"
ufw allow 22 || true; ufw allow 40400/tcp || true; ufw allow 40400/udp || true; ufw allow 8080/tcp || true
yes | ufw enable >/dev/null 2>&1 || true
ok "UFW 就绪。"

# ===== Aztec CLI =====
ensure_path_line='export PATH="$HOME/.aztec/bin:$PATH"'
aztec_exists(){ sudo -u "$TARGET_USER" bash -lc 'command -v aztec >/dev/null 2>&1 || [[ -x "$HOME/.aztec/bin/aztec" ]]'; }
if ! aztec_exists; then
  info "安装 Aztec CLI…（需要可用 Docker）"
  sudo -u "$TARGET_USER" -g docker bash -lc 'bash -i <(curl -s https://install.aztec.network)'
  if ! sudo -u "$TARGET_USER" bash -lc "grep -Fq '$ensure_path_line' '$TARGET_BASHRC' 2>/dev/null"; then
    echo "$ensure_path_line" >> "$TARGET_BASHRC"; chown "$TARGET_USER":"$TARGET_USER" "$TARGET_BASHRC"
  fi
  sudo -u "$TARGET_USER" bash -lc 'source ~/.bashrc >/dev/null 2>&1; command -v aztec >/dev/null 2>&1' \
    || { err "Aztec CLI 安装失败"; exit 3; }
  ok "Aztec CLI 安装完成。"
else
  ok "Aztec CLI 已安装。"
fi

# ===== 前台运行 =====
cat <<'TXT'
---------------------------------------------
将以前台方式启动 Aztec 节点（当前终端）：
- 停止：Ctrl+C
- 下次运行将复用 /etc/aztec-node/config.env
---------------------------------------------
TXT

export ETHEREUM_HOSTS L1_CONSENSUS_HOST_URLS VALIDATOR_PRIVATE_KEY COINBASE P2P_IP
exec sudo --preserve-env=ETHEREUM_HOSTS,L1_CONSENSUS_HOST_URLS,VALIDATOR_PRIVATE_KEY,COINBASE,P2P_IP \
  -u "$TARGET_USER" -g docker bash -lc '
  set -Eeuo pipefail
  source ~/.bashrc >/dev/null 2>&1 || true
  if command -v aztec >/dev/null 2>&1; then AZTEC_BIN="$(command -v aztec)";
  elif [[ -x "$HOME/.aztec/bin/aztec" ]]; then AZTEC_BIN="$HOME/.aztec/bin/aztec";
  else echo "[ERROR] aztec 未找到"; exit 1; fi

  CMD=(
    "$AZTEC_BIN" start --node --archiver --sequencer
    --network testnet
    --l1-rpc-urls "$ETHEREUM_HOSTS"
    --l1-consensus-host-urls "$L1_CONSENSUS_HOST_URLS"
    --sequencer.validatorPrivateKey "$VALIDATOR_PRIVATE_KEY"
    --sequencer.coinbase "$COINBASE"
  )
  if [[ -n "${P2P_IP:-}" ]]; then CMD+=(--p2p.p2pIp "$P2P_IP"); fi

  echo "▶ 启动命令：${CMD[*]}"
  exec "${CMD[@]}"
'
