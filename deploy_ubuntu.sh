#!/usr/bin/env bash
set -euo pipefail

# 获取当前用户目录
USER_NAME=$(whoami)
AZTEC_DIR="/home/$USER_NAME/aztec"  # 使用当前用户的目录
DATA_DIR="/home/$USER_NAME/.aztec/alpha-testnet/data"

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo "本脚本必须以 root 权限运行。"
  exit 1
fi

# 函数：打印信息
print_info() {
  echo "$1"
}

# 函数：检查命令是否存在
check_command() {
  command -v "$1" &> /dev/null
}

# 函数：比较版本号
version_ge() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# 函数：安装依赖
install_package() {
  local pkg=$1
  print_info "安装 $pkg..."
  apt-get install -y "$pkg"
}

# 更新 apt 源（确保源更新）
update_apt() {
  if [ -z "${APT_UPDATED:-}" ]; then
    print_info "更新 apt 源..."
    apt-get update
    APT_UPDATED=1
  fi
}

# 确保 apt 源配置正确
update_sources_list() {
  print_info "检查并更新 apt 源..."
  
  # 如果是 Ubuntu 20.04 (Focal)，使用默认源
  if grep -q "Ubuntu 20.04" /etc/os-release; then
    if ! grep -q "archive.ubuntu.com" /etc/apt/sources.list; then
      echo "deb http://archive.ubuntu.com/ubuntu/ focal main restricted universe multiverse" | tee -a /etc/apt/sources.list
      echo "deb http://archive.ubuntu.com/ubuntu/ focal-updates main restricted universe multiverse" | tee -a /etc/apt/sources.list
      echo "deb http://archive.ubuntu.com/ubuntu/ focal-security main restricted universe multiverse" | tee -a /etc/apt/sources.list
    fi
  # 如果是 Ubuntu 22.04 (Jammy)，使用默认源
  elif grep -q "Ubuntu 22.04" /etc/os-release; then
    if ! grep -q "archive.ubuntu.com" /etc/apt/sources.list; then
      echo "deb http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse" | tee -a /etc/apt/sources.list
      echo "deb http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse" | tee -a /etc/apt/sources.list
      echo "deb http://archive.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse" | tee -a /etc/apt/sources.list
    fi
  else
    echo "未识别的 Ubuntu 版本，自动更新源可能失败。请手动检查并更新源配置。"
  fi
}

# 检查并安装 Docker
install_docker() {
  if check_command docker; then
    local version
    version=$(docker --version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    if version_ge "$version" "$MIN_DOCKER_VERSION"; then
      print_info "Docker 已安装，版本 $version，满足要求（>= $MIN_DOCKER_VERSION）。"
      return
    else
      print_info "Docker 版本 $version 过低（要求 >= $MIN_DOCKER_VERSION），将重新安装..."
    fi
  else
    print_info "未找到 Docker，正在安装..."
  fi
  update_apt
  install_package "curl gnupg lsb-release ca-certificates software-properties-common"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  update_apt
  install_package "docker-ce docker-ce-cli containerd.io"
}

# 检查并安装 Docker Compose
install_docker_compose() {
  if check_command docker-compose || docker compose version &> /dev/null; then
    local version
    version=$(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || docker compose version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    if version_ge "$version" "$MIN_COMPOSE_VERSION"; then
      print_info "Docker Compose 已安装，版本 $version，满足要求（>= $MIN_COMPOSE_VERSION）。"
      return
    else
      print_info "Docker Compose 版本 $version 过低（要求 >= $MIN_COMPOSE_VERSION），将重新安装..."
    fi
  else
    print_info "未找到 Docker Compose，正在安装..."
  fi
  update_apt
  install_package docker-compose-plugin
}

# 检查并安装 Node.js
install_nodejs() {
  if check_command node; then
    print_info "Node.js 已安装。"
    return
  fi
  print_info "未找到 Node.js，正在安装最新版本..."
  curl -fsSL https://deb.nodesource.com/setup_current.x | bash -
  update_apt
  install_package nodejs
}

# 安装 Aztec CLI
install_aztec_cli() {
  print_info "安装 Aztec CLI 并准备 alpha 测试网..."
  if ! curl -sL "$AZTEC_CLI_URL" | bash; then
    echo "Aztec CLI 安装失败。"
    exit 1
  fi
  export PATH="$HOME/.aztec/bin:$PATH"
  if ! check_command aztec-up; then
    echo "Aztec CLI 安装失败，未找到 aztec-up 命令。"
    exit 1
  fi
  aztec-up alpha-testnet
}

# 验证 RPC URL 格式（检查是否以 http:// 或 https:// 开头）
validate_url() {
  local url=$1
  local name=$2
  if [[ ! "$url" =~ ^https?:// ]]; then
    echo "错误：$name 格式无效，必须以 http:// 或 https:// 开头。"
    exit 1
  fi
}

# 验证以太坊地址格式
validate_address() {
  local address=$1
  local name=$2
  if [[ ! "$address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    echo "错误：$name 格式无效，必须是有效的以太坊地址（0x 开头的 40 位十六进制）。"
    exit 1
  fi
}

# 主逻辑：安装和启动 Aztec 节点
install_and_start_node() {
  # 清理旧配置
  print_info "清理旧的 Aztec 配置（如果存在）..."
  rm -rf "$AZTEC_DIR/.env" "$AZTEC_DIR/aztec_start.sh"
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true

  # 安装依赖
  install_docker
  install_docker_compose
  install_nodejs
  install_aztec_cli

  # 创建 Aztec 配置目录
  print_info "创建 Aztec 配置目录 $AZTEC_DIR..."
  mkdir -p "$AZTEC_DIR"
  chmod -R 755 "$AZTEC_DIR"

  # 获取用户输入
  print_info "获取 RPC URL 和其他配置的说明："
  read -p " L1 执行客户端（EL）RPC URL： " ETH_RPC
  read -p " L1 共识（CL）RPC URL： " CONS_RPC
  read -p " 验证者私钥（0x 开头的 64 位十六进制）： " VALIDATOR_PRIVATE_KEY
  read -p " EVM钱包 地址（以太坊地址，0x 开头）： " COINBASE

  # 验证输入
  validate_url "$ETH_RPC" "L1 执行客户端（EL）RPC URL"
  validate_url "$CONS_RPC" "L1 共识（CL）RPC URL"
  if [ -z "$VALIDATOR_PRIVATE_KEY" ]; then
    echo "错误：验证者私钥不能为空。"
    exit 1
  fi
  validate_address "$COINBASE" "COINBASE 地址"

  # 获取公共 IP
  print_info "获取公共 IP..."
  PUBLIC_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
  print_info "    → $PUBLIC_IP"

  # 生成 .env 文件
  print_info "生成 $AZTEC_DIR/.env 文件..."
  cat > "$AZTEC_DIR/.env" <<EOF
ETHEREUM_HOSTS="$ETH_RPC"
L1_CONSENSUS_HOST_URLS="$CONS_RPC"
P2P_IP="$PUBLIC_IP"
VALIDATOR_PRIVATE_KEY="$VALIDATOR_PRIVATE_KEY"
COINBASE="$COINBASE"
DATA_DIRECTORY="/data"
LOG_LEVEL="debug"
EOF
  chmod 600 "$AZTEC_DIR/.env"

  # 生成启动脚本
  print_info "生成启动脚本 aztec_start.sh..."
  cat > "$AZTEC_DIR/aztec_start.sh" <<EOF
#!/bin/bash
source "$AZTEC_DIR/.env"
aztec start --node --archiver --sequencer \
  --network testnet \
  --l1-rpc-urls \$ETHEREUM_HOSTS  \
  --l1-consensus-host-urls \$L1_CONSENSUS_HOST_URLS \
  --sequencer.validatorPrivateKey \$VALIDATOR_PRIVATE_KEY \
  --sequencer.coinbase \$COINBASE \
  --p2p.p2pIp \$P2P_IP
EOF
  chmod +x "$AZTEC_DIR/aztec_start.sh"

  # 启动节点
  print_info "启动 Aztec 节点..."
  "$AZTEC_DIR/aztec_start.sh"
}

# 执行主逻辑
install_and_start_node
