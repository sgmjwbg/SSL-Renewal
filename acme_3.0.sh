#!/bin/bash
set -e

# ==================== Telegram 配置 ====================
# 请确保以下信息准确，acme.sh 会将其永久保存在 account.conf 中
TG_BOT_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHAT_ID="1957625818"

# ==================== 1. 环境准备 ====================
. /etc/os-release
OS=$ID
echo "📦 正在安装基础依赖..."
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt update -y && sudo apt install -y curl socat cron
elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
    sudo yum install -y curl socat cronie
    sudo systemctl enable --now crond
fi

# 安装 acme.sh (如果没安装)
ACME_BIN="/root/.acme.sh/acme.sh"
if [ ! -f "$ACME_BIN" ]; then
    echo "📥 正在安装 acme.sh 核心..."
    curl https://acme.sh | sh
fi

# ==================== 2. 配置 Telegram 通知 ====================
# 修正为 acme.sh 官方识别的标准变量名
export TELEGRAM_BOT_APITOKEN="$TG_BOT_TOKEN"
export TELEGRAM_BOT_CHATID="$TG_CHAT_ID"

echo "🔔 正在关联 Telegram 通知钩子..."
$ACME_BIN --set-notify --notify-hook telegram --notify-level 2 --notify-mode 0

# ==================== 3. 申请逻辑 ====================
read -p "请输入域名 (例如 example.com): " DOMAIN
read -p "请输入联系邮箱 (用于证书过期提醒): " EMAIL

echo "请选择 CA 机构：1) Let's Encrypt  2) Buypass  3) ZeroSSL (默认)"
read -p "输入选项 [1-3]: " CA_OPTION
case $CA_OPTION in
    1) CA_SERVER="letsencrypt" ;;
    2) CA_SERVER="buypass" ;;
    *) CA_SERVER="zerossl" ;;
esac

# 检查并临时停止 Nginx (Standalone 模式必须占用 80 端口)
NGINX_RUNNING=false
if pgrep -x "nginx" > /dev/null; then
    echo "🛑 检测到 Nginx 正在运行，正在尝试临时停止以释放 80 端口..."
    systemctl stop nginx
    NGINX_RUNNING=true
fi

# 注册账号
$ACME_BIN --register-account -m $EMAIL --server $CA_SERVER

echo "🚀 正在通过 Standalone 模式申请证书..."
if ! $ACME_BIN --issue --standalone -d $DOMAIN --server $CA_SERVER; then
    echo "❌ 申请失败！"
    # 如果失败了也要记得把 Nginx 开启回来
    [ "$NGINX_RUNNING" = true ] && systemctl start nginx
    exit 1
fi

# 安装证书到指定路径
$ACME_BIN --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# 恢复 Nginx 运行
if [ "$NGINX_RUNNING" = true ]; then
    echo "▶️ 正在重新启动 Nginx..."
    systemctl start nginx
fi

echo "🎉 证书申请成功并已开启自动续期！"
echo "✅ 证书路径: /root/${DOMAIN}.crt"
echo "✅ 私钥路径: /root/${DOMAIN}.key"
echo "📬 如果配置正确，你的 Telegram 现在应该已经收到了通知。"
