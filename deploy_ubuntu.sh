#!/bin/bash
set -e

# 获取当前用户目录
USER_NAME=$(whoami)
AZTEC_DIR="/home/$USER_NAME/aztec"  # 使用当前用户的目录
DATA_DIR="/home/$USER_NAME/.aztec/alpha-testnet/data"

# 检查是否为 Ubuntu 或 Debian 系统
if [ ! -f /etc/os-release ]; then
  echo "不是 Ubuntu 或 Debian 系统，退出安装。"
  exit 1
fi

# 提示：更新系统
echo "正在更新系统..."
sudo apt update -y && sudo apt upgrade -y

# 安装必要的依赖包
echo "正在安装必要的依赖包..."
sudo apt install curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip libleveldb-dev -y

# 提示：删除已有的 Docker 相关包
echo "正在删除已有的 Docker 包..."
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin; do
  sudo apt-get remove --purge -y $pkg 2>/dev/null || true
done

# 提示：自动清理不需要的包
echo "正在清理不需要的包..."
sudo apt-get autoremove -y
sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg

# 更新 apt 源
echo "正在更新 apt 源..."
sudo apt-get update

# 安装 Docker 安装依赖
echo "正在安装 Docker 安装依赖..."
sudo apt-get install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings

# 获取操作系统版本并设置 Docker 官方源
echo "正在设置 Docker 官方源..."
. /etc/os-release
repo_url="https://download.docker.com/linux/$ID"
curl -fsSL "$repo_url/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $repo_url $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 更新 apt 源并安装 Docker
echo "正在安装 Docker..."
sudo apt update -y && sudo apt upgrade -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 测试 Docker 是否安装成功
echo "正在测试 Docker 安装..."
if sudo docker run hello-world; then
  sudo docker rm $(sudo docker ps -a --filter "ancestor=hello-world" --format "{{.ID}}") --force 2>/dev/null || true
  sudo docker image rm hello-world 2>/dev/null || true
  sudo systemctl enable docker
  sudo systemctl restart docker
  clear
  echo -e "\u2022 Docker 已安装成功 ✅"
fi

echo "正在给当前用户添加 Docker 权限..."
sudo usermod -aG docker $USER

newgrp docker <<EOF
echo "正在安装 Aztec CLI..."
yes y | bash -i <(curl -s https://install.aztec.network)
EOF

echo "Aztec CLI 安装完成！"

# 设置环境变量
echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.bashrc

# 使环境变量生效
source ~/.bashrc

echo "安装完成！"

# 创建 Aztec 配置目录
echo "创建 Aztec 配置目录 $AZTEC_DIR..."
mkdir -p "$AZTEC_DIR"
chmod -R 755 "$AZTEC_DIR"

# 配置防火墙
echo "配置防火墙，开放端口 40400 和 8080..."
sudo apt install -y ufw
# Firewall
sudo ufw allow 22
sudo ufw allow ssh
sudo ufw enable
# Sequencer
sudo ufw allow 40400/tcp
sudo ufw allow 40400/udp
sudo ufw allow 8080
sudo ufw reload
# If asked y/n ..Enter "y"

# 获取用户输入
echo "获取 RPC URL 和其他配置的说明："
echo "  - L1 执行客户端（EL）RPC URL："
echo "    1. 在 https://dashboard.alchemy.com/ 获取 Sepolia 的 RPC (http://xxx)"
echo ""
echo "  - L1 共识（CL）RPC URL："
echo "    1. 在 https://drpc.org/ 获取 Beacon Chain Sepolia 的 RPC (http://xxx)"
echo ""
echo "  - COINBASE：接收奖励的以太坊地址（格式：0x...）"
echo ""
read -p " L1 执行客户端（EL）RPC URL： " ETH_RPC
read -p " L1 共识（CL）RPC URL： " CONS_RPC
read -p " 验证者私钥（0x 开头的 64 位十六进制）： " VALIDATOR_PRIVATE_KEY
read -p " EVM钱包 地址（以太坊地址，0x 开头）： " COINBASE
BLOB_URL="" # 默认跳过 Blob Sink URL

# 获取公共 IP
echo "获取公共 IP..."
PUBLIC_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
echo "    → $PUBLIC_IP"

# 生成 .env 文件
echo "生成 $AZTEC_DIR/.env 文件..."
cat > "$AZTEC_DIR/.env" <<EOF
ETHEREUM_HOSTS="$ETH_RPC"
L1_CONSENSUS_HOST_URLS="$CONS_RPC"
P2P_IP="$PUBLIC_IP"
VALIDATOR_PRIVATE_KEY="$VALIDATOR_PRIVATE_KEY"
COINBASE="$COINBASE"
DATA_DIRECTORY="/data"
LOG_LEVEL="debug"
EOF
if [ -n "$BLOB_URL" ]; then
  echo "BLOB_SINK_URL=\"$BLOB_URL\"" >> "$AZTEC_DIR/.env"
fi
chmod 600 "$AZTEC_DIR/.env"

# 设置 BLOB_FLAG
BLOB_FLAG=""
if [ -n "$BLOB_URL" ]; then
  BLOB_FLAG="--sequencer.blobSinkUrl \$BLOB_SINK_URL"
fi

# 生成 aztec_start.sh 启动脚本
echo "生成 $AZTEC_DIR/aztec_start.sh 文件..."
cat > "$AZTEC_DIR/aztec_start.sh" <<EOF
#!/bin/bash
source "$AZTEC_DIR/.env"
aztec start --node --archiver --sequencer \
  --network testnet \
  --l1-rpc-urls \$ETHEREUM_HOSTS  \
  --l1-consensus-host-urls \$L1_CONSENSUS_HOST_URLS \
  --sequencer.validatorPrivateKeys \$VALIDATOR_PRIVATE_KEY \
  --sequencer.coinbase \$COINBASE \
  --p2p.p2pIp \$P2P_IP
EOF

chmod +x "$AZTEC_DIR/aztec_start.sh"

# 启动 Aztec 节点
echo "启动 Aztec 节点..."
"$AZTEC_DIR/aztec_start.sh"

echo "安装并启动 Aztec 节点完成！"
