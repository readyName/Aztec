#!/usr/bin/env bash
# aztec_node_setup.sh — Ubuntu 一键部署 & 前台启动 Aztec 节点（按你提供的 Docker 安装流程）
# 用法：
#   sudo ./aztec_node_setup.sh
# 特点：
# - Docker 安装严格按你提供的命令执行（加上 -y 以无人值守）
# - 依赖缺啥补啥；UFW 放行 22/40400/8080
# - Aztec CLI 自动安装；变量持久化 /etc/aztec-node/config.env（仅 root 读）
# - 前台运行（当前终端），Ctrl+C 停止

set -Eeuo pipefail
umask 022
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

color(){ printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
info(){  color "1;34" "ℹ️  $*"; }
ok(){    color "1;32" "✓ $*"; }
warn(){  color "1;33" "⚠️  $*"; }
err(){   color "1;31" "✗ $*"; }

[[ $EUID -eq 0 ]] || { err "请用 sudo 运行：sudo ./aztec_node_setup.sh"; exit 1; }

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(eval echo "~$TARGET_USER")"
TARGET_BASHRC="$TARGET_HOME/.bashrc"
CONFIG_DIR="/etc/aztec-node"
CONFIG_FILE="$CONFIG_DIR/config.env"
LOG_DIR="/var/log/aztec-node"
mkdir -p "$CONFIG_DIR" "$LOG_DIR"; chmod 700 "$CONFIG_DIR"; : >"$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"

# ===== 依赖（缺啥补啥）=====
PKGS=(curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip ufw ca-certificates gnupg lsb-release)
missing=(); for p in "${PKGS[@]}"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
info "更新系统..."
apt-get update -y -o Acquire::Retries=3
apt-get upgrade -y || true
if ((${#missing[@]})); then
  info "安装缺失依赖: ${missing[*]}"
  apt-get install -y "${missing[@]}"
else
  ok "依赖已满足。"
fi

# ===== Docker 安装（按你提供的命令）=====
install_docker_from_user_snippet() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker 已安装：$(docker --version | head -n1)"
    return 0
  fi
  info "按你的流程安装 Docker..."

  # 你的命令（做了轻微等价化处理，避免复杂 echo 嵌套；整体逻辑不变）
  apt update -y && apt upgrade -y

  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y "$pkg" || true
  done

  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list

  apt update -y && apt upgrade -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Test Docker（你的命令）
  docker run --rm hello-world || true

  systemctl enable --now docker
  systemctl restart docker

  # 让目标用户可用 docker（附加：便于后续不带 sudo 使用）
  usermod -aG docker "${SUDO_USER:-$USER}" || true
  ok "Docker 已按指定流程安装完毕。"
}
install_docker_from_user_snippet

# ===== UFW 防火墙 =====
if ! command -v ufw >/dev/null 2>&1; then apt-get install -y ufw; fi
info "配置 UFW（22/ssh、40400、8080）..."
ufw allow 22 || true
ufw allow ssh || true
ufw allow 40400 || true
ufw allow 8080 || true
yes | ufw enable >/dev/null 2>&1 || true
ok "UFW 就绪。"

# ===== Aztec CLI 安装 =====
ensure_path_line='export PATH="$HOME/.aztec/bin:$PATH"'
ensure_bashrc_path() {
  if ! sudo -u "$TARGET_USER" bash -lc "grep -Fq '$ensure_path_line' '$TARGET_BASHRC' 2>/dev/null"; then
    info "将 Aztec 路径加入 $TARGET_USER 的 ~/.bashrc"
    echo "$ensure_path_line" >> "$TARGET_BASHRC"
    chown "$TARGET_USER":"$TARGET_USER" "$TARGET_BASHRC"
  fi
}
aztec_exists() {
  sudo -u "$TARGET_USER" bash -lc 'command -v aztec >/dev/null 2>&1 || [[ -x "$HOME/.aztec/bin/aztec" ]]'
}
install_aztec() {
  info "安装 Aztec CLI..."
  # 以 docker 组身份运行安装器，确保能调用 docker
  sudo -u "$TARGET_USER" -g docker bash -lc 'bash -i <(curl -s https://install.aztec.network)'
  ensure_bashrc_path
  if ! sudo -u "$TARGET_USER" bash -lc 'source ~/.bashrc >/dev/null 2>&1; command -v aztec >/dev/null 2>&1 || [[ -x "$HOME/.aztec/bin/aztec" ]]'; then
    warn "未检测到 aztec，重试安装..."
    sudo -u "$TARGET_USER" -g docker bash -lc 'bash -i <(curl -s https://install.aztec.network)'
  fi
}
if aztec_exists; then
  ok "检测到 aztec 已安装。"
else
  install_aztec
  ensure_bashrc_path
  aztec_exists || { err "aztec 安装失败，请检查网络后重试。"; exit 2; }
fi
sudo -u "$TARGET_USER" bash -lc 'source ~/.bashrc >/dev/null 2>&1; (aztec --version || aztec version || true) 2>/dev/null' || true

# ===== 获取公网 IPv4（用于 p2pIp 默认值）=====
PUB_IP="$(curl -fsS ipv4.icanhazip.com || true)"
[[ -n "${PUB_IP:-}" ]] && ok "公网 IPv4：$PUB_IP" || warn "未能获取公网 IPv4。"

# ===== 载入历史配置 & 交互输入 =====
# shellcheck disable=SC1090
source "$CONFIG_FILE" || true
prompt_keep() {
  local var="$1" prompt="$2" is_secret="${3:-0}" curr input
  curr="${!var:-}"
  if [[ "$is_secret" == "1" ]]; then
    read -r -s -p "$prompt${curr:+ [已保存，回车不变]}: " input; echo
  else
    read -r -p "$prompt${curr:+ [默认: $curr]}: " input
  fi
  if [[ -z "$input" && -n "$curr" ]]; then printf -v "$var" '%s' "$curr"; else printf -v "$var" '%s' "$input"; fi
}

echo
info "请输入运行所需变量（回车可沿用历史值）："
prompt_keep RPC_URL        "RPC_URL（L1 执行层 RPC，如 https://... ）"
prompt_keep BEACON_URL     "BEACON_URL（L1 共识层 Beacon，如 https://... ）"
prompt_keep VALIDATOR_PRIV "验证者私钥 0xYourPrivateKey（0x+64hex）" 1
prompt_keep COINBASE_ADDR  "出块奖励地址 0xYourAddress（0x+40hex）"
if [[ -z "${P2P_IP:-}" && -n "$PUB_IP" ]]; then P2P_IP="$PUB_IP"; fi
prompt_keep P2P_IP         "P2P 对外 IP（默认检测到的公网 IPv4）"

# 简单校验
[[ -n "$RPC_URL" && -n "$BEACON_URL" ]] || { err "RPC_URL / BEACON_URL 不能为空。"; exit 3; }
[[ "$VALIDATOR_PRIV" =~ ^0x[0-9a-fA-F]{64}$ ]] || warn "私钥格式似乎不符合 0x+64hex，请确认。"
[[ "$COINBASE_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] || warn "地址格式似乎不符合 0x+40hex，请确认。"
[[ -n "$P2P_IP" ]] || warn "未提供 P2P_IP，可能影响对外连接。"

# 保存配置
cat > "$CONFIG_FILE" <<EOF
# 自动生成：Aztec 节点配置（含私钥，注意保密）
RPC_URL="$RPC_URL"
BEACON_URL="$BEACON_URL"
VALIDATOR_PRIV="$VALIDATOR_PRIV"
COINBASE_ADDR="$COINBASE_ADDR"
P2P_IP="$P2P_IP"
EOF
chmod 600 "$CONFIG_FILE"
ok "已保存配置到 $CONFIG_FILE"

cat <<'EOS'
---------------------------------------------
将以前台方式启动 Aztec 节点（当前终端）：
- 停止：Ctrl+C
- 复用变量：下次运行本脚本直接回车
---------------------------------------------
EOS

# 前台运行（以 docker 组身份，确保能访问 /var/run/docker.sock）
export RPC_URL BEACON_URL VALIDATOR_PRIV COINBASE_ADDR P2P_IP
exec sudo --preserve-env=RPC_URL,BEACON_URL,VALIDATOR_PRIV,COINBASE_ADDR,P2P_IP -u "$TARGET_USER" -g docker bash -lc '
  set -Eeuo pipefail
  source ~/.bashrc >/dev/null 2>&1 || true
  if command -v aztec >/dev/null 2>&1; then AZTEC_BIN="$(command -v aztec)";
  elif [[ -x "$HOME/.aztec/bin/aztec" ]]; then AZTEC_BIN="$HOME/.aztec/bin/aztec";
  else AZTEC_BIN="aztec"; fi
  CMD=(
    "$AZTEC_BIN" start --node --archiver --sequencer
    --network testnet
    --l1-rpc-urls "$RPC_URL"
    --l1-consensus-host-urls "$BEACON_URL"
    --sequencer.validatorPrivateKey "$VALIDATOR_PRIV"
    --sequencer.coinbase "$COINBASE_ADDR"
  )
  if [[ -n "${P2P_IP:-}" ]]; then CMD+=(--p2p.p2pIp "$P2P_IP"); fi
  echo "▶ 正在启动：${CMD[*]}"
  exec "${CMD[@]}"
'
