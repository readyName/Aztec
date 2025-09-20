#!/usr/bin/env bash
# aztec_node_setup.sh — Ubuntu 一键部署 & 前台启动 Aztec 节点
# 用法：
#   chmod +x aztec_node_setup.sh
#   sudo ./aztec_node_setup.sh
#
# 特点：
# - 幂等：已装依赖会跳过；变量会保存到 /etc/aztec-node/config.env，复跑可直接回车使用旧值
# - 自动安装/修复 aztec CLI，并写入 ~/.bashrc（仅目标用户）
# - 自动放行 UFW 端口：22/ssh、40400、8080
# - 前台运行：脚本最后会“接管”当前终端，直接运行 aztec；按 Ctrl+C 停止

set -Eeuo pipefail
umask 022
DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ===== 彩色输出 =====
color(){ printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
info(){  color "1;34" "ℹ️  $*"; }
ok(){    color "1;32" "✓ $*"; }
warn(){  color "1;33" "⚠️  $*"; }
err(){   color "1;31" "✗ $*"; }

# ===== Root 检查 =====
if [[ $EUID -ne 0 ]]; then
  err "请使用 sudo 以 root 身份运行：sudo ./aztec_node_setup.sh"
  exit 1
fi

# ===== 目标用户路径/配置 =====
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

# ===== 依赖（检测后按需安装）=====
PKGS=(curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip ufw)
missing_pkgs=()
for p in "${PKGS[@]}"; do dpkg -s "$p" &>/dev/null || missing_pkgs+=("$p"); done

info "更新系统源并升级（可能耗时）…"
apt-get update -y -o Acquire::Retries=3
apt-get upgrade -y || true

if ((${#missing_pkgs[@]})); then
  info "安装缺失依赖: ${missing_pkgs[*]}"
  apt-get install -y "${missing_pkgs[@]}"
else
  ok "依赖已满足，跳过安装。"
fi

# ===== UFW 防火墙 =====
if ! command -v ufw >/dev/null 2>&1; then apt-get install -y ufw; fi
info "配置 UFW（22/ssh、40400、8080）…"
ufw allow 22 || true
ufw allow ssh || true
ufw allow 40400 || true
ufw allow 8080 || true
yes | ufw enable >/dev/null 2>&1 || true
ok "UFW 就绪。"

# ===== Aztec CLI 安装/检测 =====
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
  info "安装 Aztec CLI…"
  sudo -u "$TARGET_USER" bash -lc 'bash -i <(curl -s https://install.aztec.network)'
  ensure_bashrc_path
  if ! sudo -u "$TARGET_USER" bash -lc 'source ~/.bashrc >/dev/null 2>&1; command -v aztec >/dev/null 2>&1 || [[ -x "$HOME/.aztec/bin/aztec" ]]'; then
    warn "未检测到 aztec，重试安装…"
    sudo -u "$TARGET_USER" bash -lc 'bash -i <(curl -s https://install.aztec.network)'
  fi
}
if aztec_exists; then
  ok "检测到 aztec 已安装。"
else
  install_aztec
  ensure_bashrc_path
  if ! aztec_exists; then
    err "aztec 安装失败，请检查网络后重试。"
    exit 2
  fi
fi

# 显示版本（可选）
sudo -u "$TARGET_USER" bash -lc 'source ~/.bashrc >/dev/null 2>&1; (aztec --version || aztec version || aztec help || true) 2>/dev/null' || true

# ===== 获取公网 IP =====
PUB_IP="$(curl -fsS ipv4.icanhazip.com || true)"
[[ -n "${PUB_IP:-}" ]] && ok "公网 IPv4：$PUB_IP" || warn "未能获取公网 IPv4。"

# ===== 载入已保存配置并提示输入 =====
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
  if [[ -z "$input" && -n "$curr" ]]; then
    printf -v "$var" '%s' "$curr"
  else
    printf -v "$var" '%s' "$input"
  fi
}

echo
info "请按提示输入所需变量（回车可沿用历史值）："
prompt_keep RPC_URL        "RPC_URL（L1 执行层 RPC，如 https://... ）"
prompt_keep BEACON_URL     "BEACON_URL（L1 共识层 Beacon，如 https://... ）"
prompt_keep VALIDATOR_PRIV "验证者私钥 0xYourPrivateKey（0x+64hex）" 1
prompt_keep COINBASE_ADDR  "出块奖励地址 0xYourAddress（0x+40hex）"
if [[ -z "${P2P_IP:-}" && -n "$PUB_IP" ]]; then P2P_IP="$PUB_IP"; fi
prompt_keep P2P_IP         "P2P 对外 IP（默认检测值）"

# 基本校验
if [[ -z "$RPC_URL" || -z "$BEACON_URL" ]]; then
  err "RPC_URL / BEACON_URL 不能为空。"
  exit 3
fi
[[ "$VALIDATOR_PRIV" =~ ^0x[0-9a-fA-F]{64}$ ]] || warn "私钥格式似乎不符合 0x+64hex，请确认。"
[[ "$COINBASE_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] || warn "地址格式似乎不符合 0x+40hex，请确认。"
[[ -n "$P2P_IP" ]] || warn "未提供 P2P_IP，可能影响对外连接。"

# 保存配置（仅 root 可读）
cat > "$CONFIG_FILE" <<EOF
# 自动生成：Aztec 节点配置（含私钥，注意保密）
RPC_URL="$RPC_URL"
BEACON_URL="$BEACON_URL"
VALIDATOR_PRIV="$VALIDATOR_PRIV"
COINBASE_ADDR="$COINBASE_ADDR"
P2P_IP="$P2P_IP"
EOF
chmod 600 "$CONFIG_FILE"
ok "已保存配置：$CONFIG_FILE"

# ===== 前台运行 =====
cat <<'EOS'
---------------------------------------------
将以前台方式启动 Aztec 节点（当前终端）：
- 停止：按 Ctrl+C
- 如需再次启动，重跑本脚本并回车复用旧变量
---------------------------------------------
EOS

# 将变量传给目标用户的 shell，并在其环境中查找 aztec 可执行文件后前台启动
export RPC_URL BEACON_URL VALIDATOR_PRIV COINBASE_ADDR P2P_IP
exec sudo --preserve-env=RPC_URL,BEACON_URL,VALIDATOR_PRIV,COINBASE_ADDR,P2P_IP -u "$TARGET_USER" bash -lc '
  set -Eeuo pipefail
  source ~/.bashrc >/dev/null 2>&1 || true
  # 解析 aztec 路径
  if command -v aztec >/dev/null 2>&1; then
    AZTEC_BIN="$(command -v aztec)"
  elif [[ -x "$HOME/.aztec/bin/aztec" ]]; then
    AZTEC_BIN="$HOME/.aztec/bin/aztec"
  else
    AZTEC_BIN="aztec"
  fi
  # 构造并执行（前台）
  CMD=(
    "$AZTEC_BIN" start --node --archiver --sequencer
    --network testnet
    --l1-rpc-urls "$RPC_URL"
    --l1-consensus-host-urls "$BEACON_URL"
    --sequencer.validatorPrivateKey "$VALIDATOR_PRIV"
    --sequencer.coinbase "$COINBASE_ADDR"
  )
  if [[ -n "${P2P_IP:-}" ]]; then
    CMD+=(--p2p.p2pIp "$P2P_IP")
  fi
  echo "▶ 正在启动：${CMD[*]}"
  exec "${CMD[@]}"
'
