#!/usr/bin/env bash
# Aztec 2.0 节点部署脚本（CLI 版，先出菜单，选 1 才执行安装）
# - 生成一键启动文件：/root/aztec/start_aztec_cli.sh（前台运行）
# - 仅在“选项 1”里执行依赖/Docker/Aztec 安装；失败不会直接退出菜单
# - 自我重启到 bash，防止被 sh/dash 导致 read -p 失效

# --- 确保用 bash 运行 ---
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi

set -Eeuo pipefail

# ===== 配置 =====
AZTEC_DIR="/root/aztec"
DATA_DIR="/root/.aztec/testnet/data"
LOG_DIR="/var/log/aztec"
mkdir -p "$AZTEC_DIR" "$DATA_DIR" "$LOG_DIR"

# ===== 颜色 & 打印 =====
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_info(){ echo -e "${GREEN}[INFO]${NC} $*"; }
print_warning(){ echo -e "${YELLOW}[WARNING]${NC} $*"; }
print_error(){ echo -e "${RED}[ERROR]${NC} $*"; }
print_step(){ echo -e "${BLUE}[STEP]${NC} $*"; }
pause(){ read -n1 -s -p "按任意键返回菜单..." _; echo; }

# ===== 必须 root =====
check_root(){
  if [[ $(id -u) -ne 0 ]]; then
    print_error "本脚本必须以 root 运行：sudo $0"
    exit 1
  fi
}
check_root

# ===== 尝试加载 .env（不因未绑定变量退出）=====
if [[ -f "$AZTEC_DIR/.env" ]]; then
  print_info "从 $AZTEC_DIR/.env 载入环境变量…"
  set +u
  # shellcheck disable=SC1090
  source "$AZTEC_DIR/.env"
  set -u
fi

# ===== 依赖（延后到选项 1 安装）=====
ensure_deps(){
  print_step "安装通用依赖（jq、netcat、ufw、gnupg、lsb-release）…"
  apt-get update -y -o Acquire::Retries=3
  apt-get install -y ca-certificates curl gnupg lsb-release jq netcat-openbsd ufw
}

# ===== Docker（keyrings 稳定安装）=====
install_docker(){
  if command -v docker >/dev/null 2>&1; then
    print_info "Docker 已安装：$(docker --version | head -n1)"
    systemctl enable --now docker
    return 0
  fi
  print_step "安装 Docker（官方源 + keyrings）…"
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

# ===== Aztec CLI =====
ensure_aztec_path_line='export PATH="$HOME/.aztec/bin:$PATH"'
install_aztec_cli(){
  if sudo -u "${SUDO_USER:-root}" bash -lc 'command -v aztec >/dev/null 2>&1 || [[ -x "$HOME/.aztec/bin/aztec" ]]'; then
    print_info "Aztec CLI 已安装。"
    return 0
  fi
  print_step "安装 Aztec CLI（需要可用的 Docker）…"
  # 用 docker 组运行安装器，避免需要重登
  sudo -u "${SUDO_USER:-root}" -g docker bash -lc 'bash -i <(curl -s https://install.aztec.network)'
  # 确保 PATH
  local target_home; target_home="$(eval echo "~${SUDO_USER:-root}")"
  if ! grep -Fq "$ensure_aztec_path_line" "$target_home/.bashrc" 2>/dev/null; then
    echo "$ensure_aztec_path_line" >> "$target_home/.bashrc"
  fi
  sudo -u "${SUDO_USER:-root}" bash -lc 'source ~/.bashrc >/dev/null 2>&1; command -v aztec >/dev/null 2>&1' \
    || { print_error "Aztec CLI 安装失败"; return 1; }
  print_info "Aztec CLI 安装完成。"
}

# ===== 公网 IP 探测 =====
get_pub_ipv4(){ curl -4 -fsS icanhazip.com || curl -4 -fsS ifconfig.co || echo ""; }

# ===== 交互输入（安全，兼容 set -u）=====
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
  while :; do
    prompt_keep ETHEREUM_HOSTS "EL RPC URL（http/https 开头）"
    [[ "$ETHEREUM_HOSTS" =~ ^https?:// ]] && break
    print_error "URL 无效，需以 http:// 或 https:// 开头。"
  done; echo
  while :; do
    prompt_keep L1_CONSENSUS_HOST_URLS "CL RPC URL（http/https 开头）"
    [[ "$L1_CONSENSUS_HOST_URLS" =~ ^https?:// ]] && break
    print_error "URL 无效，需以 http:// 或 https:// 开头。"
  done; echo
  while :; do
    prompt_keep VALIDATOR_PRIVATE_KEY "验证者私钥（0x+64hex）" 1
    [[ "$VALIDATOR_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] && break
    print_error "私钥格式不对。"
  done; echo
  while :; do
    prompt_keep COINBASE "COINBASE 地址（0x+40hex）"
    [[ "$COINBASE" =~ ^0x[0-9a-fA-F]{40}$ ]] && break
    print_error "地址格式不对。"
  done; echo
  local detected_ip; detected_ip="$(get_pub_ipv4)"
  [[ -z "${P2P_IP-}" && -n "$detected_ip" ]] && P2P_IP="$detected_ip"
  prompt_keep P2P_IP "P2P 对外 IPv4（默认自动探测）"
  echo
}

# ===== 生成 .env 与一键启动 =====
generate_env_and_starter(){
  print_step "生成 .env 与一键启动脚本…"
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

  cat > "$AZTEC_DIR/start_aztec_cli.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set +u; source "$DIR/.env"; set -u
: "${ETHEREUM_HOSTS:?缺少 EL RPC}"; : "${L1_CONSENSUS_HOST_URLS:?缺少 CL RPC}"
: "${VALIDATOR_PRIVATE_KEY:?缺少验证者私钥}"; : "${COINBASE:?缺少 COINBASE 地址}"
P2P="${P2P_IP:-$(curl -4 -fsS icanhazip.com || true)}"
if command -v aztec >/dev/null 2>&1; then AZTEC_BIN="$(command -v aztec)";
elif [[ -x "$HOME/.aztec/bin/aztec" ]]; then AZTEC_BIN="$HOME/.aztec/bin/aztec"; else
  echo "[ERROR] aztec 未找到，请先安装 Aztec CLI。"; exit 1; fi
echo "▶ 前台启动 Aztec（Ctrl+C 停止）…"
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

# ===== 防火墙提示 =====
show_firewall_info(){
  print_step "防火墙端口提醒（请自行放行）"
  print_info "22/tcp  40400/tcp 40400/udp  8080/tcp"
  echo "ufw allow 22/tcp; ufw allow 40400/tcp; ufw allow 40400/udp; ufw allow 8080/tcp"
}

# ===== 前台启动（CLI）=====
start_node_cli(){
  print_step "以前台方式启动（CLI）"
  echo "Tips: 以后可直接执行 $AZTEC_DIR/start_aztec_cli.sh"
  echo "────────────────────────────────────────"
  cd "$AZTEC_DIR"
  ./start_aztec_cli.sh
}

# ===== 状态检查 =====
check_node_status(){
  print_step "节点健康检查"
  if ! command -v jq >/dev/null 2>&1; then
    print_warning "缺少 jq，尝试安装…"; if ! apt-get update -y || ! apt-get install -y jq; then
      print_error "安装 jq 失败，跳过详细状态。"; pause; return; fi
  fi
  if ss -tulpn | grep -q ":8080"; then echo "1. API: ✅ 8080 listening"; else echo "1. API: ❌ 未监听"; fi
  local proven latest
  proven=$(curl -sS -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":1}' http://127.0.0.1:8080 \
    | jq -r '.result.proven.number // empty' || true)
  latest=$(curl -sS -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":1}' http://127.0.0.1:8080 \
    | jq -r '.result.latest.number // empty' || true)
  if [[ -n "${proven:-}" && -n "${latest:-}" ]]; then
    local diff=$(( latest - proven ))
    if (( diff <= 5 )); then echo "2. 同步: ✅ (proven=$proven latest=$latest)";
    elif (( diff <= 20 )); then echo "2. 同步: ⚠️ (差=$diff)";
    else echo "2. 同步: 🚀 (差=$diff)"; fi
  else echo "2. 同步: ❌ 无法获取"; fi
  local t="❌" u="❌"; nc -z 127.0.0.1 40400 2>/dev/null && t="✅"; nc -uz -w1 127.0.0.1 40400 2>/dev/null && u="✅"
  echo "3. P2P 端口: TCP $t / UDP $u"
  pause
}

# ===== 删除与升级（保留为 CLI 版的简化操作）=====
delete_node(){
  print_step "彻底删除（数据/镜像）"
  read -r -p "确认删除？(y/N): " a
  [[ "$a" =~ ^[yY]$ ]] || { print_info "已取消"; pause; return; }
  rm -rf "$AZTEC_DIR" "$DATA_DIR"
  docker rmi aztecprotocol/aztec:latest 2>/dev/null || true
  docker system prune -f
  print_info "清理完成。"; pause
}
upgrade_node(){
  print_step "升级 aztec 镜像到最新…"
  if docker pull aztecprotocol/aztec:latest; then
    print_info "镜像已更新；使用 CLI 启动时会自动用本地最新镜像。"
  else
    print_warning "拉取失败（可稍后再试，或直接用 CLI 启动继续使用旧镜像）。"
  fi
  pause
}

# ===== 选项 1：安装/配置并启动 =====
install_and_start_node(){
  # 把“容易失败”的步骤各自兜底，失败不退出整个脚本
  ensure_deps || { print_error "依赖安装失败"; pause; return; }
  install_docker || { print_error "Docker 安装失败"; pause; return; }
  install_aztec_cli || { print_error "Aztec CLI 安装失败"; pause; return; }
  show_firewall_info
  get_user_input
  generate_env_and_starter
  # 可选预拉镜像（失败不致命）
  docker pull aztecprotocol/aztec:latest || print_warning "镜像预拉失败，启动时会自动拉取。"
  # 前台启动（接管当前终端；用户 Ctrl+C 停止后返回菜单）
  start_node_cli
}

# ===== 命令行直达（可选）=====
case "${1-}" in
  install|1) install_and_start_node; exit 0 ;;
  status|2)  check_node_status; exit 0 ;;
  upgrade|3) upgrade_node; exit 0 ;;
  delete|nuke|4) delete_node; exit 0 ;;
esac

# ===== 菜单 =====
main_menu(){
  while true; do
    clear
    echo -e "\033[38;5;24m┌─────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[38;5;24m│              \033[1;38;5;45m🚀 Aztec 2.0 节点部署脚本（CLI 版）🚀\033[0m\033[38;5;24m               │\033[0m"
    echo -e "\033[38;5;24m└─────────────────────────────────────────────────────────┘\033[0m"
    echo
    echo "  1. 安装/配置并生成一键启动文件（并立刻前台启动）"
    echo "  2. 查看节点状态"
    echo "  3. 升级（拉最新镜像）"
    echo "  4. 彻底删除（数据/镜像）"
    echo "  5. 退出"
    echo
    read -r -p "  请选择 [1-5]: " choice
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
