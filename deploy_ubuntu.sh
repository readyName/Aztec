#!/bin/bash
set -euo pipefail

# 获取当前用户名
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

# 函数：安装包
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

# 安装依赖
install_dependencies() {
  print_info "安装 curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip..."
  install_package "curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip"
}

# 安装 Docker 和 Docker Compose
install_docker() {
  if check_command docker; then
    local version
    version=$(docker --version | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    print_info "Docker 已安装，版本 $version"
  else
    print_info "未找到 Docker，正在安装..."
    update_apt

    install_package "apt-transport-https ca-certificates curl gnupg lsb-release"
    sudo install -m 0755 -d /etc/apt/keyrings

    . /etc/os-release
    repo_url="https://download.docker.com/linux/$ID"
    curl -fsSL "$repo_url/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $repo_url $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update -y
    install_package "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
  fi
}

# 给用户添加 Docker 权限
add_docker_permissions() {
  sudo usermod -aG docker $USER
  newgrp docker
}

# 安装 Aztec CLI
install_aztec_cli() {
  print_info "安装 Aztec CLI 并准备 alpha 测试网..."
  echo "y" | bash -i <(curl -s https://install.aztec.network)  # 自动输入 y 确认安装
  echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.bashrc
  source ~/.bashrc
}

# 主逻辑：安装和启动 Aztec 节点
install_and_start_node() {
  # 清理旧配置
  print_info "清理旧的 Aztec 配置（如果存在）..."
  rm -rf "$AZTEC_DIR/.env" "$AZTEC_DIR/aztec_start.sh"
  docker stop aztec-sequencer 2>/dev/null || true
  docker rm aztec-sequencer 2>/dev/null || true

  # 安装依赖
  install_dependencies
  install_docker
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
