#!/bin/bash
set -e

# ==================== Telegram 配置 (请在此修改) ====================
TG_BOT_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHAT_ID="1957625818"

# ==================== 0. 自动修复 DNS (防止解析失败) ====================
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# 主菜单
while true; do
    clear
    echo "============== SSL证书管理菜单 (含TG通知) =============="
    echo "1）申请 SSL 证书"
    echo "2）重置环境（清除申请记录并重新部署）"
    echo "3）退出"
    echo "============================================"
    read -p "请输入选项（1-3）： " MAIN_OPTION

    case $MAIN_OPTION in
        1) break ;;
        2)
            echo "⚠️ 正在重置环境..."
            rm -rf /root/.acme.sh
            echo "✅ 已清空 acme.sh 目录，准备重新部署。"
            sleep 1
            # 重新执行本脚本
            bash "$0"
            exit 0
            ;;
        3) echo "👋 已退出。"; exit 0 ;;
        *) echo "❌ 无效选项"; sleep 1; continue ;;
    esac
done

# 用户输入参数
read -p "请输入域名: " DOMAIN
read -p "请输入电子邮件地址: " EMAIL

echo "请选择证书颁发机构（CA）："
echo "1）Let's Encrypt"
echo "2）Buypass"
echo "3）ZeroSSL"
read -p "输入选项（1-3）： " CA_OPTION
case $CA_OPTION in
    1) CA_SERVER="letsencrypt" ;;
    2) CA_SERVER="buypass" ;;
    3) CA_SERVER="zerossl" ;;
    *) echo "❌ 无效选项"; exit 1 ;;
esac

# 防火墙配置逻辑 (保持原样)
read -p "是否关闭防火墙？ (1:是 2:否): " FIREWALL_OPTION
if [ "$FIREWALL_OPTION" -eq 2 ]; then
    read -p "是否放行特定端口？ (1:是 2:否): " PORT_OPTION
    [ "$PORT_OPTION" -eq 1 ] && read -p "请输入端口号: " PORT
fi

# 检查系统并安装依赖
. /etc/os-release
OS=$ID
case $OS in
    ubuntu|debian)
        sudo apt update -y && sudo apt install -y curl socat git cron
        [ "$FIREWALL_OPTION" -eq 1 ] && sudo ufw disable || { [ "$PORT_OPTION" -eq 1 ] && sudo ufw allow $PORT; }
        ;;
    centos)
        sudo yum install -y curl socat git cronie
        sudo systemctl enable --now crond
        if [ "$FIREWALL_OPTION" -eq 1 ]; then
            sudo systemctl stop firewalld && sudo systemctl disable firewalld
        elif [ "$PORT_OPTION" -eq 1 ]; then
            sudo firewall-cmd --permanent --add-port=${PORT}/tcp && sudo firewall-cmd --reload
        fi
        ;;
esac

# ==================== 1. 安装与配置 acme.sh ====================
ACME_BIN="/root/.acme.sh/acme.sh"
if [ ! -f "$ACME_BIN" ]; then
    echo "📥 正在安装 acme.sh..."
    curl https://get.acme.sh | sh -s email=$EMAIL
fi

# 导出 TG 变量让 acme.sh 永久记录
export TELEGRAM_TOKEN="$TG_BOT_TOKEN"
export TELEGRAM_CHAT_ID="$TG_CHAT_ID"

echo "🔔 正在开启 Telegram 全局通知..."
$ACME_BIN --set-notify --notify-hook telegram --notify-level 2 --notify-mode 0

# 注册账户
$ACME_BIN --register-account -m $EMAIL --server $CA_SERVER

# ==================== 2. 申请与安装 ====================
echo "🚀 开始申请证书..."
if ! $ACME_BIN --issue --standalone -d $DOMAIN --server $CA_SERVER; then
    echo "❌ 申请失败！"
    exit 1
fi

# 安装证书到 /root
$ACME_BIN --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# ==================== 3. 续期任务与手动通知测试 ====================
(crontab -l 2>/dev/null; echo "0 0 * * * $ACME_BIN --cron > /dev/null") | crontab -

# 手动发送一条成功消息到 TG (可选)
curl -s -X POST "https://telegram.org" \
    -d "chat_id=$TG_CHAT_ID" \
    -d "text=✅ 证书申请成功！%0A🌐 域名: $DOMAIN%0A📅 以后续期将自动推送通知。" > /dev/null

echo "✅ 所有操作已完成！"
echo "📄 证书: /root/${DOMAIN}.crt"
echo "🔐 私钥: /root/${DOMAIN}.key"
