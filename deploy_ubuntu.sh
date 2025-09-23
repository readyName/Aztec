#!/bin/bash
set -e

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

# 提示：给当前用户添加 Docker 组权限
echo "正在给当前用户添加 Docker 权限..."
sudo usermod -aG docker $USER
exec newgrp docker

# 提示：安装 Aztec CLI
echo "正在安装 Aztec CLI..."
yes y | bash -i <(curl -s https://install.aztec.network)

# 设置环境变量
echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.bashrc

# 使环境变量生效
source ~/.bashrc

echo "安装完成！"
