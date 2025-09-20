#!/usr/bin/env bash
# aztec_node_setup.sh — Ubuntu 一键部署 & 前台启动（先取未开VPN公网IP→提示开VPN→记录→使用未开VPN IP）
# 用法：
#   chmod +x aztec_node_setup.sh
#   sudo ./aztec_node_setup.sh
#
# 特点：
# - 脚本一开始即执行：curl -4 icanhazip.com 拿“未开VPN公网IP”，随后提示你开启VPN继续，仅记录对比；始终用“未开VPN IP”做 --p2p.p2pIp
# - 依赖按需安装、UFW 放行、Aztec CLI 自动安装并加入 ~/.bashrc
# - 变量保存到 /etc/aztec-node/config.env（仅 root 可读），IP 记录到 /var/log/aztec-node/ip_history.log
# - 前台运行（Ctrl+C 停止）

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
  err "请用 sudo 运行：sudo ./aztec_node_setup.sh"
  exit 1
fi

# ===== 目标用户/路径 =====
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(eval echo "~$TARGET_USER")"
TARGET_BASHRC="$TARGET_HOME/.bashrc"
CONFIG_DIR="/etc/aztec-node"
CONFIG_FILE="$CONFIG_DIR/config.env"
LOG_DIR="/var/log/aztec-node"
IP_HISTORY="$LOG_DIR/ip_history.log"
mkdir -p "$CONFIG_DIR" "$LOG_DIR"
chmod 700 "$CONFIG_DIR"
touch "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
touch "$IP_HISTORY"; chmod 644 "$IP_HISTORY"

# ===== 先获取“未开 VPN 的公网 IPv4” → 提示开启 VPN → 记录对比 =====
get_pub_v4_primary() {
  # 按你的要求先用这条命令
  curl -4 -fsS --max-time 8 --noproxy '*' http://ipv4.icanhazip.com 2>/dev/null | tr -d '\r'
}
get_pub_v4_fallback() {
  for URL in https://api.ipify.org http://ifconfig.co/ip; do
    IP=$(curl -4 -fsS --max-time 8 --noproxy '*' "$URL" 2>/dev/null | tr -d '\r')
    [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$IP"; return 0; }
  done
  return 1
}

info "获取【未开 VPN】公网 IPv4（curl -4 icanhazip.com）…"
PRE_VPN_IP="$(get_pub_v4_primary || true)"
if [[ -z "${PRE_VPN_IP:-}" ]]; then
  warn "icanhazip 获取失败，尝试备用服务…"
  PRE_VPN_IP="$(get_pub_v4_fallback || true)"
fi
if [[ -z "${PRE_VPN_IP:-}" ]]; then
  err "未能获取【未开 VPN】的公网 IPv4，请先关闭 VPN 或检查网络后重试。"
  exit 3
fi
ok "未开 VPN 的公网 IPv4：$PRE_VPN_IP"
echo "$(date -Is)  PRE_VPN_IP=$PRE_VPN_IP" | tee -a "$IP_HISTORY" >/dev/null

read -r -p "现在请手动开启 VPN（如需），开启好后按回车继续记录…"
POST_VPN_IP="$(get_pub_v4_primary || true)"
if [[ -z "${POST_VPN_IP:-}" ]]; then
  POST_VPN_IP="$(get_pub_v4_fallback || true)"
fi
if [[ -n "${POST_VPN_IP:-}" ]]; then
  info "VPN 开启后的公网 IPv4：$POST_VPN_IP"
  echo "$(date -Is)  POST_VPN_IP=$POST_VPN_IP" | tee -a "$IP_HISTORY" >/dev/null
else
  warn "无法在 VPN 开启后获取公网 IPv4（可能被代理/防火墙拦截），跳过记录。"
fi

# 固定使用“未开 VPN 的 IP”作为 p2pIp
P2P_IP="$PRE_VPN_IP"
export P2P_IP
ok "将使用 --p2p.p2pIp=$P2P_IP"

# ===== 依赖（已装跳过）=====
PKGS=(curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip ufw)
missing=(); for p in "${PKGS[@]}"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done

info "更新系统源并升级（可能耗时）…"
apt-get update -y -o Acquire::Retries=3
apt-get upgrade -y || true

if ((${#missing[@]})); then
  info "安装缺失依赖: ${missing[*]}"
  apt-get install -y "${missing[@]}"
else
  ok "依赖已满足，跳过安装。"
fi

# ===== UFW 防火墙 =====
command -v ufw >/dev/null 2>&1 || apt-get install -y ufw
info "配置 UFW 放行 22/ssh、40400、8080 …"
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
aztec_exists(){ sudo -u "$TARGET_USER" bash -lc 'command -v aztec >/dev/null 2>&1 || [[ -x "$HOME/.aztec/bin/aztec" ]]'; }
install_aztec(){
  info "安装 Aztec CLI…"
  sudo -u "$TARGET_USER" bash -lc 'bash -i <(curl -s https://install.aztec.network)'
  ensure_bashrc_path
  sudo -u "$TARGET_USER" bash -lc 'source ~/.bashrc >/dev/null 2>&1 || true'
}
if aztec_exists; then
  ok "检测到 aztec 已安装。"
else
  install_aztec
  aztec_exists || { err "aztec 安装失败，请检查网络后重试。"; exit 2; }
fi
sudo -u "$TARGET_USER" bash -lc '(aztec --version || aztec version || true) 2>/dev/null' || true

# ===== 载入/输入变量并保存 =====
# shellcheck disable=SC1090
source "$CONFIG_FILE" || true

read -r -p "RPC_URL（执行层 RPC，如 https://... ）${RPC_URL:+ [默认: $RPC_URL]}: " x; RPC_URL="${x:-${RPC_URL:-}}"
read -r -p "BEACON_URL（共识层 Beacon，如 https://... ）${BEACON_URL:+ [默认: $BEACON_URL]}: " x; BEACON_URL="${x:-${BEACON_URL:-}}"
read -r -s -p "验证者私钥 0xYourPrivateKey（0x+64hex）${VALIDATOR_PRIV:+ [已保存，回车不变]}: " x; echo; VALIDATOR_PRIV="${x:-${VALIDATOR_PRIV:-}}"
read -r -p "出块奖励地址 0xYourAddress（0x+40hex）${COINBASE_ADDR:+ [默认: $COINBASE_ADDR]}: " x; COINBASE_ADDR="${x:-${COINBASE_ADDR:-}}"

[[ -z "${RPC_URL:-}" || -z "${BEACON_URL:-}" ]] && { err "RPC_URL / BEACON_URL 不能为空"; exit 4; }
[[ "$VALIDATOR_PRIV" =~ ^0x[0-9a-fA-F]{64}$ ]] || warn "私钥格式看起来不像 0x+64hex，请确认。"
[[ "$COINBASE_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] || warn "地址格式看起来不像 0x+40hex，请确认。"

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
ok "P2P 对外 IP（未开VPN）：$P2P_IP（已记录到 $IP_HISTORY）"

# ===== 前台启动 =====
cat <<'EOS'
---------------------------------------------
即将以前台方式启动 Aztec 节点（当前终端）：
- 停止：Ctrl+C
---------------------------------------------
EOS

export RPC_URL BEACON_URL VALIDATOR_PRIV COINBASE_ADDR P2P_IP
exec sudo --preserve-env=RPC_URL,BEACON_URL,VALIDATOR_PRIV,COINBASE_ADDR,P2P_IP -u "$TARGET_USER" bash -lc '
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
    --p2p.p2pIp "$P2P_IP"
  )
  echo "▶ 启动命令：${CMD[*]}"
  exec "${CMD[@]}"
'
