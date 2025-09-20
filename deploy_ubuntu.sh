#!/usr/bin/env bash
# Aztec 节点部署脚本（CLI 版：生成目录一键启动文件）
# - 启动使用 aztec CLI（仍需 Docker，但不再用 docker-compose.yml）
# - 会在 AZTEC_DIR 生成 ./start_aztec_cli.sh 供一键启动（前台，Ctrl+C 停止）
# - 保留你的菜单结构，并修复/增强若干细节

set -Eeuo pipefail

# ===== 配置 =====
AZTEC_DIR="/root/aztec"
DATA_DIR="/root/.aztec/testnet/data"
LOG_DIR="/var/log/aztec"
mkdir -p "$AZTEC_DIR" "$DATA_DIR" "$LOG_DIR"

# ===== 颜色 =====
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_info(){ echo -e "${GREEN}[INFO]${NC} $*"; }
print_warning(){ echo -e "${YELLOW}[WARNING]${NC} $*"; }
print_error(){ echo -e "${RED}[ERROR]${NC} $*"; }
print_step(){ echo -e "${BLUE}[STEP]${NC} $*"; }

# ===== 必须 root =====
check_root(){
  if [[ $(id -u) -ne 0 ]]; then
    print_error "本脚本必须以 root 运行：sudo $0"
    exit 1
  fi
}
check_root

# ===== 智能加载 .env（若存在）=====
if [[ -f "$AZTEC_DIR/.env" ]]; then
  print_info "从 $AZTEC_DIR/.env 载入环境变量…"
  set +u
  # shellcheck disable=SC1090
  source "$AZTEC_DIR/.env"
  set -u
fi

# ===== 依赖（jq / netcat-openbsd / ufw 等）=====
ensure_deps(){
  print_step "检查通用依赖…"
  apt-get update -y -o Acquire::Retries=3
  apt-get install -y ca-certificates curl gnupg lsb-release jq netcat-openbsd ufw
}
ensure_deps

# ===== Docker（keyrings 稳定安装）=====
install_docker(){
  if command -v docker >/dev/null 2>&1; then
    print_info "Docker 已安装：$(docker --version | head -n1)"
    systemctl enable --now docker
    return 0
  fi
  print_step "安装 Docker…"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 5 --retry-delay 2 --ipv4 https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  usermod -aG docker "${SUDO_USER:-$USER}" || true
  print_info "Docker 安装完成。"
}
install_docker

# ===== Aztec CLI =====
ensure_aztec_path_line='export PATH="$HOME/.aztec/bin:$PATH"'
install_aztec_cli(){
  if sudo -u "${SUDO_USER:-root}" bash -lc 'command -v aztec >/dev/null 2>&1 || [[ -x "$HOME/.aztec/bin/aztec" ]]'; then
    print_info "Aztec CLI 已安装。"
    return 0
  fi
  print_step "安装 Aztec CLI…（需要可用的 Docker）"
  sudo -u "${SUDO_USER:-root}" -g docker bash -lc 'bash -i <(curl -s https://install.aztec.network)'
  # 写 PATH
  local target_home
  target_home="$(eval echo "~${SUDO_USER:-root}")"
  if ! grep -Fq "$ensure_aztec_path_line" "$target_home/.bashrc" 2>/dev/null; then
    echo "$ensure_aztec_path_line" >> "$target_home/.bashrc"
  fi
  # 验证
  sudo -u "${SUDO_USER:-root}" bash -lc 'source ~/.bashrc >/dev/null 2>&1; command -v aztec >/dev/null 2>&1' \
    || { print_error "Aztec CLI 安装失败"; exit 2; }
  print_info "Aztec CLI 安装完成。"
}
install_aztec_cli

# ===== 获取公网 IPv4 =====
get_pub_ipv4(){
  curl -4 -fsS icanhazip.com || curl -4 -fsS ifconfig.co || echo ""
}

# ===== 交互输入（安全版，兼容 set -u）=====
prompt_keep(){
  local var="$1" prompt="$2" is_secret="${3:-0}" curr input
  curr="${!var-}"
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

get_user_input(){
  print_step "请输入 Aztec CLI 配置信息（用于生成一键启动文件）"
  echo

  echo "L1 执行（EL）RPC URL 示例：Alchemy / dRPC / Ankr 等"
  while :; do
    prompt_keep ETHEREUM_HOSTS "EL RPC URL（http/https 开头）"
    [[ "$ETHEREUM_HOSTS" =~ ^https?:// ]] && break
    print_error "URL 无效，需以 http:// 或 https:// 开头。"
  done
  echo

  echo "L1 共识（CL/Beacon）RPC URL 示例：dRPC / Ankr 等"
  while :; do
    prompt_keep L1_CONSENSUS_HOST_URLS "CL RPC URL（http/https 开头）"
    [[ "$L1_CONSENSUS_HOST_URLS" =~ ^https?:// ]] && break
    print_error "URL 无效，需以 http:// 或 https:// 开头。"
  done
  echo

  echo "验证者私钥：0x 开头 + 64 位十六进制"
  while :; do
    prompt_keep VALIDATOR_PRIVATE_KEY "验证者私钥" 1
    [[ "$VALIDATOR_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] && break
    print_error "私钥格式不对。"
  done
  echo

  echo "COINBASE 地址：0x 开头 + 40 位十六进制"
  while :; do
    prompt_keep COINBASE "COINBASE 地址"
    [[ "$COINBASE" =~ ^0x[0-9a-fA-F]{40}$ ]] && break
    print_error "地址格式不对。"
  done
  echo

  local detected_ip
  detected_ip="$(get_pub_ipv4)"
  [[ -z "${P2P_IP-}" && -n "$detected_ip" ]] && P2P_IP="$detected_ip"
  prompt_keep P2P_IP "P2P 对外 IPv4（默认自动探测）"
  echo
}

# ===== 生成 .env 与 一键启动文件 =====
generate_env_and_starter(){
  print_step "生成配置文件与一键启动脚本…"

  # .env（仅 root 可读）
  cat > "$AZTEC_DIR/.env" <<EOF
ETHEREUM_HOSTS=$ETHEREUM_HOSTS
L1_CONSENSUS_HOST_URLS=$L1_CONSENSUS_HOST_URLS
P2P_IP=$P2P_IP
VALIDATOR_PRIVATE_KEY=$VALIDATOR_PRIVATE_KEY
COINBASE=$COINBASE
DATA_DIRECTORY=/data
LOG_LEVEL=info
EOF
  chmod 600 "$AZTEC_DIR/.env"
  print_info "已写入 $AZTEC_DIR/.env（含私钥，注意保密）"

  # 一键启动（前台运行）：start_aztec_cli.sh
  cat > "$AZTEC_DIR/start_aztec_cli.sh" <<'EOS'
#!/usr/bin/env bash
# 使用 aztec CLI 前台启动（读取同目录 .env）
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set +u
source "$DIR/.env"
set -u

# 校验
: "${ETHEREUM_HOSTS:?缺少 EL RPC（ETHEREUM_HOSTS）}"
: "${L1_CONSENSUS_HOST_URLS:?缺少 CL RPC（L1_CONSENSUS_HOST_URLS）}"
: "${VALIDATOR_PRIVATE_KEY:?缺少验证者私钥}"
: "${COINBASE:?缺少 COINBASE 地址}"
P2P="${P2P_IP:-$(curl -4 -fsS icanhazip.com || true)}"

# 定位 aztec 可执行
if command -v aztec >/dev/null 2>&1; then
  AZTEC_BIN="$(command -v aztec)"
elif [[ -x "$HOME/.aztec/bin/aztec" ]]; then
  AZTEC_BIN="$HOME/.aztec/bin/aztec"
else
  echo "[ERROR] aztec 未找到，请先安装 Aztec CLI。" >&2
  exit 1
fi

echo "▶ 正在以前台方式启动 Aztec（Ctrl+C 停止）…"
echo "   EL: $ETHEREUM_HOSTS"
echo "   CL: $L1_CONSENSUS_HOST_URLS"
echo "   P2P_IP: ${P2P:-<未设置>}"
echo

exec "$AZTEC_BIN" start --node --archiver --sequencer \
  --network testnet \
  --l1-rpc-urls "$ETHEREUM_HOSTS" \
  --l1-consensus-host-urls "$L1_CONSENSUS_HOST_URLS" \
  --sequencer.validatorPrivateKey "$VALIDATOR_PRIVATE_KEY" \
  --sequencer.coinbase "$COINBASE" \
  ${P2P:+--p2p.p2pIp "$P2P"}
EOS
  chmod +x "$AZTEC_DIR/start_aztec_cli.sh"
  print_info "一键启动：$AZTEC_DIR/start_aztec_cli.sh"
}

# ===== 防火墙提示（保留你的做法）=====
show_firewall_info(){
  print_step "防火墙端口提醒（请自行按需放行）"
  print_info "  22/tcp（SSH）"
  print_info "  40400/tcp + 40400/udp（P2P）"
  print_info "  8080/tcp（HTTP API）"
  echo "ufw allow 22/tcp; ufw allow 40400/tcp; ufw allow 40400/udp; ufw allow 8080/tcp"
}

# ===== 镜像预拉（可选）=====
pull_latest_image(){
  print_step "（可选）预拉镜像 aztecprotocol/aztec:latest…"
  docker pull aztecprotocol/aztec:latest || print_warning "拉取失败可忽略，CLI 会按需拉取。"
}

# ===== 启动（前台，会占用当前终端）=====
start_node_cli(){
  print_step "以前台方式启动（CLI）——当前终端会被接管，Ctrl+C 停止"
  echo "Tips: 你也可以以后直接运行：$AZTEC_DIR/start_aztec_cli.sh"
  echo "────────────────────────────────────────"
  cd "$AZTEC_DIR"
  ./start_aztec_cli.sh
}

# ===== 删除数据/镜像（保留）=====
delete_node(){
  print_step "彻底删除（容器、数据、镜像）"
  read -p "确认删除？(y/N): " a
  [[ "$a" =~ ^[yY]$ ]] || { print_info "已取消"; read -n1 -s -p "按任意键返回"; return; }
  # 停可能存在的容器（尽力而为）
  docker ps -q --filter "ancestor=aztecprotocol/aztec" | xargs -r docker stop
  docker ps -aq --filter "ancestor=aztecprotocol/aztec" | xargs -r docker rm
  rm -rf "$AZTEC_DIR" "$DATA_DIR"
  docker rmi aztecprotocol/aztec:latest 2>/dev/null || true
  docker system prune -f
  print_info "清理完成。"
  read -n1 -s -p "按任意键返回"
}

# ===== 升级（拉新镜像 + 重新启动）=====
upgrade_node(){
  print_step "升级 aztec 镜像到最新…"
  docker pull aztecprotocol/aztec:latest || { print_error "拉取失败"; read -n1 -s -p "按任意键返回"; return; }
  print_info "镜像已更新。重新启动请执行：$AZTEC_DIR/start_aztec_cli.sh"
  read -n1 -s -p "按任意键返回"
}

# ===== 查看状态（HTTP + 日志）=====
check_node_status(){
  print_step "节点健康检查"
  if ss -tulpn | grep -q ":8080"; then
    echo "1. API 端口: ✅ 8080 listening"
  else
    echo "1. API 端口: ❌ 未监听（节点可能未启动）"
  fi

  # L2 tips
  local proven latest
  proven=$(curl -sS -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":1}' http://127.0.0.1:8080 \
    | jq -r '.result.proven.number // empty' || true)
  latest=$(curl -sS -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":1}' http://127.0.0.1:8080 \
    | jq -r '.result.latest.number // empty' || true)

  if [[ -n "${proven:-}" && -n "${latest:-}" ]]; then
    local diff=$(( latest - proven ))
    if (( diff <= 5 )); then
      echo "2. 同步状态: ✅ 已同步 (proven=$proven latest=$latest)"
    elif (( diff <= 20 )); then
      echo "2. 同步状态: ⚠️ 基本同步 (proven=$proven latest=$latest, 差=$diff)"
    else
      echo "2. 同步状态: 🚀 同步中 (proven=$proven latest=$latest, 差=$diff)"
    fi
  else
    echo "2. 同步状态: ❌ 无法获取（节点未就绪或 API 不通）"
  fi

  # P2P 端口占用（TCP/UDP 粗查）
  local p2p_tcp="❌" p2p_udp="❌"
  nc -z 127.0.0.1 40400 2>/dev/null && p2p_tcp="✅"
  nc -uz -w1 127.0.0.1 40400 2>/dev/null && p2p_udp="✅"
  echo "3. P2P监听: TCP $p2p_tcp / UDP $p2p_udp"

  echo "4. 近期日志（如使用 CLI 前台启动，可直接看前台输出）："
  docker ps --format '{{.ID}}\t{{.Image}}\t{{.Names}}' | grep aztecprotocol/aztec || true
  read -n1 -s -p "按任意键返回"
}

restart_node(){
  print_step "重启（CLI 前台方式）"
  echo "当前使用 CLI 前台启动，重启 = Ctrl+C 停止后重新执行：$AZTEC_DIR/start_aztec_cli.sh"
  read -n1 -s -p "按任意键返回"
}

# ===== 主安装流程（生成一键启动并可立即启动）=====
install_and_start_node(){
  print_step "开始安装/配置（CLI 版）"
  # 防火墙提示
  show_firewall_info
  # 输入
  get_user_input
  # 生成 .env & start_aztec_cli.sh
  generate_env_and_starter
  # （可选）提前拉镜像
  pull_latest_image
  # 立刻前台启动
  start_node_cli
}

# ===== 菜单 =====
main_menu(){
  while true; do
    clear
    echo -e "\033[38;5;24m┌─────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[38;5;24m│                                                         │\033[0m"
    echo -e "\033[38;5;24m│              \033[1;38;5;45m🚀 Aztec 2.0 节点部署脚本（CLI 版）🚀\033[0m\033[38;5;24m               │\033[0m"
    echo -e "\033[38;5;24m│                                                         │\033[0m"
    echo -e "\033[38;5;24m└─────────────────────────────────────────────────────────┘\033[0m"
    echo
    echo "  1. 安装/配置并生成一键启动文件（并立刻前台启动）"
    echo "  2. 查看节点状态"
    echo "  3. 升级（拉最新镜像）"
    echo "  4. 彻底删除（容器/数据/镜像）"
    echo "  5. 退出"
    echo
    read -p "  请选择 [1-5]: " choice
    case "$choice" in
      1) install_and_start_node ;;
      2) check_node_status ;;
      3) upgrade_node ;;
      4) delete_node ;;
      5|q|Q) print_info "再见！"; exit 0 ;;
      *) print_warning "无效选项"; sleep 1 ;;
    esac
  done
}

main_menu
