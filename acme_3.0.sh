#!/bin/bash
set -e

# ==================== Telegram 配置 ====================
TG_BOT_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHAT_ID="1957625818"
# 如果是国内服务器，acme.sh 原生支持代理，或者你可以保持 API 域名设置
TG_API_DOMAIN="api.telegram.org"

# ==================== 1. 环境准备 ====================
. /etc/os-release
OS=$ID
echo "📦 正在安装依赖..."
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt update -y && sudo apt install -y curl socat cron
elif [ "$OS" = "centos" ]; then
    sudo yum install -y curl socat cronie
    sudo systemctl enable --now crond
fi

# 安装 acme.sh (如果没安装)
ACME_BIN="/root/.acme.sh/acme.sh"
if [ ! -f "$ACME_BIN" ]; then
    curl https://acme.sh | sh
fi

# ==================== 2. 配置原生 TG 通知 ====================
# 这一步非常重要：让 acme.sh 记住你的 TG 信息
export TELEGRAM_TOKEN="$TG_BOT_TOKEN"
export TELEGRAM_CHAT_ID="$TG_CHAT_ID"

$ACME_BIN --set-notify --notify-hook telegram \
    --notify-level 2 \
    --notify-mode 0

echo "✅ Telegram 通知功能已全局开启（续期成功/失败都会推送）"

# ==================== 3. 申请逻辑 ====================
read -p "请输入域名: " DOMAIN
read -p "请输入电子邮件地址: " EMAIL

echo "请选择 CA 机构：1) Let's Encrypt  2) Buypass  3) ZeroSSL"
read -p "输入选项: " CA_OPTION
case $CA_OPTION in
    1) CA_SERVER="letsencrypt" ;;
    2) CA_SERVER="buypass" ;;
    *) CA_SERVER="zerossl" ;;
esac

# 注册账号
$ACME_BIN --register-account -m $EMAIL --server $CA_SERVER

echo "🚀 正在申请证书 (Standalone 模式)..."
# 注意：如果 80 端口被 Nginx 占用，这里会报错
if ! $ACME_BIN --issue --standalone -d $DOMAIN --server $CA_SERVER; then
    echo "❌ 申请失败！请确保 80 端口未被占用。"
    exit 1
fi

# 安装证书
$ACME_BIN --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

echo "🎉 证书申请成功！"
echo "证书位置: /root/${DOMAIN}.crt"
echo "私钥位置: /root/${DOMAIN}.key"
