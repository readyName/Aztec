#!/bin/bash
set -e

# ===== 用户与目录（用真实登录用户，而不是 root）=====
TARGET_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -z "$HOME_DIR" ] && HOME_DIR="$HOME"
AZTEC_DIR="$HOME_DIR/aztec"                 # 配置目录
DATA_DIR="$HOME_DIR/.aztec/testnet/data"    # CLI 使用 testnet

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
sudo apt install -y curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip

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

# ===== 先加组 + 让当前会话“立刻可用”，再去运行 hello-world =====
echo "正在把用户 $TARGET_USER 加入 docker 组..."
sudo groupadd -f docker
sudo usermod -aG docker "$TARGET_USER"
sudo systemctl enable docker >/dev/null 2>&1 || true
sudo systemctl restart docker

# 尝试立刻在 docker 组上下文中使用 docker；不行则给临时 ACL 以便继续脚本
if ! sudo -H -u "$TARGET_USER" sg docker -c 'docker ps >/dev/null 2>&1'; then
  echo "当前会话尚未继承 docker 组，设置临时 ACL 让本次脚本立刻可用..."
  sudo apt-get update -y >/dev/null 2>&1 || true
  sudo apt-get install -y acl >/dev/null 2>&1 || true
  sudo setfacl -m "u:${TARGET_USER}:rw" /var/run/docker.sock || true
fi

# 测试 Docker（以目标用户 + docker 组上下文）
echo "正在测试 Docker 安装（拉取/运行 hello-world）..."
sudo -H -u "$TARGET_USER" sg docker -c 'docker run --rm hello-world' && echo -e "\u2022 Docker 已安装成功 ✅"

# ===== 以目标用户身份安装 Aztec CLI（安装到该用户 HOME）=====
echo "正在安装 Aztec CLI（用户：$TARGET_USER）..."
sudo -H -u "$TARGET_USER" bash -lc '
  yes y | bash -i <(curl -s https://install.aztec.network)
  if ! grep -q ".aztec/bin" ~/.bashrc; then
    echo '\''export PATH="$HOME/.aztec/bin:$PATH"'\'' >> ~/.bashrc
  fi
  export PATH="$HOME/.aztec/bin:$PATH"
  command -v aztec >/dev/null && aztec -V || { echo "Aztec CLI 未就绪"; exit 1; }
'
echo "Aztec CLI 安装完成！"

echo "安装完成！"

# 创建 Aztec 配置目录（属主给目标用户）
echo "创建 Aztec 配置目录 $AZTEC_DIR..."
sudo -u "$TARGET_USER" mkdir -p "$AZTEC_DIR" "$DATA_DIR"
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$AZTEC_DIR" "$DATA_DIR"

# 配置防火墙（非交互）
echo "配置防火墙，开放端口 22/40400/8080..."
sudo apt install -y ufw >/dev/null 2>&1 || true
sudo ufw allow 22/tcp
sudo ufw allow ssh
sudo ufw allow 40400/tcp
sudo ufw allow 40400/udp
sudo ufw allow 8080/tcp
sudo ufw --force enable
sudo ufw reload

# 获取用户输入
echo "获取 RPC URL 和其他配置的说明："
echo "  - L1 执行客户端（EL）RPC URL（例如：Alchemy/Infura/drpc 的 Sepolia RPC）"
echo "  - L1 共识（CL）RPC URL（例如：drpc/ankr 的 Beacon RPC）"
echo "  - COINBASE：接收奖励的以太坊地址（0x...）"
read -p " L1 执行客户端（EL）RPC URL： " ETH_RPC
read -p " L1 共识（CL）RPC URL： " CONS_RPC
read -p " 验证者私钥（0x 开头的 64 位十六进制）： " VALIDATOR_PRIVATE_KEY
read -p " COINBASE 地址（0x 开头的 40 位十六进制）： " COINBASE
BLOB_URL=""

# 获取公共 IP（优先 IPv4）
echo "获取公共 IP..."
PUBLIC_IP="$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || echo 127.0.0.1)"
echo "    → $PUBLIC_IP"

# 生成 .env（写入到目标用户目录）
echo "生成 $AZTEC_DIR/.env 文件..."
sudo -u "$TARGET_USER" bash -lc "cat > '$AZTEC_DIR/.env' <<'ENVEOF'
ETHEREUM_HOSTS=\"$ETH_RPC\"
L1_CONSENSUS_HOST_URLS=\"$CONS_RPC\"
P2P_IP=\"$PUBLIC_IP\"
VALIDATOR_PRIVATE_KEY=\"$VALIDATOR_PRIVATE_KEY\"
COINBASE=\"$COINBASE\"
DATA_DIRECTORY=\"$DATA_DIR\"
LOG_LEVEL=\"debug\"
ENVEOF"
sudo chmod 600 "$AZTEC_DIR/.env"

# 生成 aztec_start.sh 启动脚本（前台运行 CLI）
echo "生成 $AZTEC_DIR/aztec_start.sh 文件..."
sudo -u "$TARGET_USER" bash -lc "cat > '$AZTEC_DIR/aztec_start.sh' <<'SHEOF'
#!/usr/bin/env bash
set -e
source \"$AZTEC_DIR/.env\"
export PATH=\"\$HOME/.aztec/bin:\$PATH\"

exec aztec start --node --archiver --sequencer \
  --network testnet \
  --l1-rpc-urls \"\$ETHEREUM_HOSTS\"  \
  --l1-consensus-host-urls \"\$L1_CONSENSUS_HOST_URLS\" \
  --sequencer.validatorPrivateKeys \"\$VALIDATOR_PRIVATE_KEY\" \
  --sequencer.coinbase \"\$COINBASE\" \
  --p2p.p2pIp \"\$P2P_IP\"
SHEOF
chmod +x '$AZTEC_DIR/aztec_start.sh'"

# 启动 Aztec 节点（以目标用户 + docker 组上下文；前台）
echo "启动 Aztec 节点（前台）..."
sudo -H -u "$TARGET_USER" sg docker -c "bash -lc '$AZTEC_DIR/aztec_start.sh'"

echo "安装并启动 Aztec 节点完成！"
