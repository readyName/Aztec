#!/usr/bin/env bash
# 直接运行版：安装依赖 → 安装 Docker → 安装 Aztec CLI → 提示变量/保存 → 前台启动
# 用法：sudo -E ./aztec_cli_run.sh
# 注意：会把变量保存到 /etc/aztec-node/config.env（仅 root 可读）

# --- 确保用 bash 运行 ---
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
set -Eeuo pipefail
umask 022
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ===== 基础参数 =====
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(eval echo "~$TARGET_USER")"
TARGET_BASHRC="$TARGET_HOME/.bashrc"
CONFIG_DIR="/etc/aztec-node"
CONFIG_FILE="$CONFIG_DIR/config.env"
LOG_DIR="/var/log/aztec-node"
mkdir -p "$CONFIG_DIR" "$LOG_DIR"
chmod 700 "$CONFIG_DIR"
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# ===== 彩色输出 =====
c(){ printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
info(){ c "1;34" "ℹ️  $*"; }
ok(){   c "1;32" "✓ $*"; }
warn(){ c "1;33" "⚠️  $*"; }
err(){  c "1;31" "✗ $*"; }

# ===== 必须 root =====
if [[ $EUID -ne 0 ]]; then err "请用 sudo 运行：sudo -E $0"; exit 1; fi

# ===== 依赖 =====
ensure_deps(){
  info "安装通用依赖（curl gnupg lsb-release jq netcat-openbsd ufw）…"
  apt-get update -y -o Acquire::Retries=3
  apt-get install -y ca-certificates curl gnupg lsb-release jq netcat-openbsd ufw
}
ensure_deps

# ===== Docker（稳健安装 + 修复损坏 gpg）=====
install_docker(){
  if command -v docker >/dev/null 2>&1; then
    ok "Docker 已安装：$(docker --version | head -n1)"
    systemctl enable --now docker
    return 0
  fi
  info "安装 Docker（官方源 + keyrings）…"
  rm -f /etc/apt/keyrings/docker.gpg || true
  install -m 0755 -d /etc/apt/keyrings
  # 先下载到临时文件，避免半包写坏
  curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 20 --ipv4 \
    https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg
  gpg --show-keys --with-fingerprint /tmp/docker.gpg >/dev/null 2>&1 || { err "Docker GPG 下载/校验失败"; exit 2; }
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    warn "官方仓库安装失败，尝试使用系统仓库备用包（docker.io）…"
    apt-get install -y docker.io docker-compose-plugin
  fi
  systemctl enable --now docker
  usermod -aG docker "${SUDO_USER:-$USER}" || true
  ok "Docker 安装完成。"
}
install_docker

# ===== UFW =====
if ! command -v ufw >/dev/null 2>&1; then apt-get install -y ufw; fi
info "配置 UFW 端口（22 / 40400 TCP+UDP / 8080）…"
ufw allow 22 || true
ufw allow 40400/tcp || true
ufw allow 40400/udp || true
ufw allow 8080/tcp || true
yes | ufw enable >/dev/null 2>&1 || true
ok "UFW 就绪。"

# ===== 安装 Aztec CLI =====
ensure_path_line='export PATH="$HOME/.aztec/bin:$PATH"'
aztec_exists(){ sudo -u "$TARGET_USER" bash -lc 'command -v aztec >/dev/null 2>&1 || [[ -x "$HOME/.aztec/bin/aztec" ]]'; }
install_aztec(){
  if aztec_exists; then ok "Aztec CLI 已安装。"; return 0; fi
  info "安装 Aztec CLI…（需要可用 Docker）"
  sudo -u "$TARGET_USER" -g docker bash -lc 'bash -i <(curl -s https://install.aztec.network)'
  # 写 PATH
  if ! sudo -u "$TARGET_USER" bash -lc "grep -Fq '$ensure_path_line' '$TARGET_BASHRC' 2>/dev/null"; then
    echo "$ensure_path_line" >> "$TARGET_BASHRC"
    chown "$TARGET_USER":"$TARGET_USER" "$TARGET_BASHRC"
  fi
  # 校验
  sudo -u "$TARGET_USER" bash -lc 'source ~/.bashrc >/dev/null 2>&1; command -v aztec >/dev/null 2>&1' \
    || { err "Aztec CLI 安装失败"; exit 3; }
  ok "Aztec CLI 安装完成。"
}
install_aztec

# ===== 加载已有配置（若有）=====
# shellcheck disable=SC1090
source "$CONFIG_FILE" || true

# ===== 公网 IPv4 侦测 =====
PUB_IP="${PUB_IP:-$(curl -4 -fsS icanhazip.com || curl -4 -fsS ifconfig.co || true)}"
[[ -n "${PUB_IP:-}" ]] && ok "检测到公网 IPv4：$PUB_IP" || warn "未能自动获取公网 IPv4。"

# ===== 交互输入（安全，兼容 set -u）=====
prompt_keep(){
  local var="$1" tip="$2" secret="${3:-0}" curr input
  curr="${!var-}"
  if [[ "$secret" == "1" ]]; then
    read -r -s -p "$tip${curr:+ [已保存，回车不变]}: " input; echo
  else
    read -r -p "$tip${curr:+ [默认: $curr]}: " input
  fi
  if [[ -z "$input" && -n "$curr" ]]; then printf -v "$var" '%s' "$curr"; else printf -v "$var" '%s' "$input"; fi
}

info "请输入运行所需变量（回车可沿用历史值）"
while :; do
  prompt_keep ETHEREUM_HOSTS "EL RPC URL（http/https 开头）"
  [[ "$ETHEREUM_HOSTS" =~ ^https?:// ]] && break || err "URL 无效（需 http:// 或 https://）。"
done
while :; do
  prompt_keep L1_CONSENSUS_HOST_URLS "CL RPC URL（http/https 开头）"
  [[ "$L1_CONSENSUS_HOST_URLS" =~ ^https?:// ]] && break || err "URL 无效（需 http:// 或 https://）。"
done
while :; do
  prompt_keep VALIDATOR_PRIVATE_KEY "验证者私钥（0x+64hex）" 1
  [[ "$VALIDATOR_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] && break || err "私钥格式不对（0x+64hex）。"
done
while :; do
  prompt_keep COINBASE "COINBASE 地址（0x+40hex）"
  [[ "$COINBASE" =~ ^0x[0-9a-fA-F]{40}$ ]] && break || err "地址格式不对（0x+40hex）。"
done
[[ -z "${P2P_IP-}" && -n "${PUB_IP:-}" ]] && P2P_IP="$PUB_IP"
prompt_keep P2P_IP "P2P 对外 IPv4（默认自动探测）"

# ===== 保存配置 =====
cat > "$CONFIG_FILE" <<EOF
# 自动生成：Aztec 节点配置（含私钥，注意保密）
ETHEREUM_HOSTS="$ETHEREUM_HOSTS"
L1_CONSENSUS_HOST_URLS="$L1_CONSENSUS_HOST_URLS"
VALIDATOR_PRIVATE_KEY="$VALIDATOR_PRIVATE_KEY"
COINBASE="$COINBASE"
P2P_IP="$P2P_IP"
EOF
chmod 600 "$CONFIG_FILE"
ok "配置已保存：$CONFIG_FILE"

# ===== 前台运行 =====
cat <<'TXT'
---------------------------------------------
将以前台方式启动 Aztec 节点（当前终端）：
- 停止：Ctrl+C
- 复用变量：下次运行本脚本直接回车
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
