#!/bin/bash
set -e

# ==================== Telegram 配置 ====================
TG_BOT_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHAT_ID="1957625818"
TG_API_DOMAIN="api.telegram.org"

# ==================== 0. 修复 DNS 解析 (新增) ====================
echo "🔧 正在优化 DNS 配置以确保下载成功..."
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# ==================== 1. 环境准备 ====================
. /etc/os-release
OS=$ID
echo "📦 正在安装基础依赖..."
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt update -y && sudo apt install -y curl socat cron
elif [ "$OS" = "centos" ]; then
    sudo yum install -y curl socat cronie
    sudo systemctl enable --now crond
fi

# ==================== 2. 安装 acme.sh (改进版) ====================
ACME_BIN="/root/.acme.sh/acme.sh"
if [ ! -f "$ACME_BIN" ]; then
    echo "📥 未检测到 acme.sh，正在从网络安装..."
    # 使用 get.acme.sh 备用链接，成功率更高
    curl https://get.acme.sh | sh || { echo "❌ 下载 acme.sh 失败，请检查网络！"; exit 1; }
    # 强制让当前环境识别 acme.sh
    source ~/.bashrc || true
fi

# 确保脚本有执行权限
chmod +x "$ACME_BIN"

# ==================== 3. 配置原生 TG 通知 ====================
export TELEGRAM_TOKEN="$TG_BOT_TOKEN"
export TELEGRAM_CHAT_ID="$TG_CHAT_ID"

echo "🔔 正在配置 Telegram 通知..."
"$ACME_BIN" --set-notify --notify-hook telegram \
    --notify-level 2 \
    --notify-mode 0

echo "✅ Telegram 通知功能已开启"

# ==================== 4. 申请逻辑 ====================
read -p "请输入域名 (例如 example.com): " DOMAIN
read -p "请输入电子邮件地址: " EMAIL

echo "请选择 CA 机构：1) Let's Encrypt  2) Buypass  3) ZeroSSL"
read -p "输入选项 (默认 3): " CA_OPTION
case $CA_OPTION in
    1) CA_SERVER="letsencrypt" ;;
    2) CA_SERVER="buypass" ;;
    *) CA_SERVER="zerossl" ;;
esac

# 注册账号
"$ACME_BIN" --register-account -m "$EMAIL" --server "$CA_SERVER"

echo "🚀 正在申请证书 (Standalone 模式)..."
# 自动尝试停止可能占用 80 端口的服务（可选）
# systemctl stop nginx || true 

if ! "$ACME_BIN" --issue --standalone -d "$DOMAIN" --server "$CA_SERVER"; then
    echo "❌ 申请失败！原因可能：1. 80端口被占用  2. 防火墙未开启80端口  3. 域名未解析到此IP"
    exit 1
fi

# 安装证书
"$ACME_BIN" --installcert -d "$DOMAIN" \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

echo "🎉 证书申请成功！"
echo "证书位置: /root/${DOMAIN}.crt"
echo "私钥位置: /root/${DOMAIN}.key"
