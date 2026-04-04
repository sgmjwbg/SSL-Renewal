#!/bin/bash
set -e

# ==================== Telegram 配置 ====================
TG_BOT_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHAT_ID="1957625818"

# 自动切换：如果是国内服务器请修改此域名
TG_API_DOMAIN="api.telegram.org"

send_tg() {
    local msg="$1"
    echo "📡 正在发送 TG 通知..."
    curl -s -m 10 -X POST "https://${TG_API_DOMAIN}/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${msg}" \
        -d "parse_mode=HTML" || echo "⚠️ TG 通知发送失败"
}
# ======================================================

# 启动通知
send_tg "🚀 <b>SSL 脚本已启动</b>%0A正在准备申请环境..."

# 主菜单
while true; do
    clear
    echo "============== SSL 证书管理 (集成 TG 通知) =============="
    echo "1）申请 SSL 证书"
    echo "2）重置环境（清除记录并重新部署）"
    echo "3）退出"
    echo "========================================================"
    read -p "请输入选项（1-3）： " MAIN_OPTION

    case $MAIN_OPTION in
        1) break ;;
        2)
            echo "⚠️ 正在重置环境..."
            rm -rf /root/.acme.sh
            send_tg "🔄 正在重置 acme.sh 环境..."
            # 修正后的安装命令
            curl https://get.acme.sh | sh
            echo "✅ 重置完成，请重新运行脚本。"
            exit 0
            ;;
        3) exit 0 ;;
        *) echo "❌ 无效选项"; sleep 1; continue ;;
    esac
done

# 用户输入
read -p "请输入域名: " DOMAIN
read -p "请输入电子邮件地址: " EMAIL

echo "请选择 CA 机构："
echo "1）Let's Encrypt (有频率限制)"
echo "2）Buypass"
echo "3）ZeroSSL (推荐)"
read -p "输入选项（1-3）： " CA_OPTION
case $CA_OPTION in
    1) CA_SERVER="letsencrypt" ;;
    2) CA_SERVER="buypass" ;;
    3) CA_SERVER="zerossl" ;;
    *) echo "❌ 无效选项"; exit 1 ;;
esac

# 依赖安装
. /etc/os-release
OS=$ID
echo "📦 正在安装依赖..."
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt update -y && sudo apt install -y curl socat git cron
elif [ "$OS" = "centos" ]; then
    sudo yum install -y curl socat git cronie
    sudo systemctl enable --now crond
fi

# 确保 acme.sh 路径正确
ACME_BIN="$HOME/.acme.sh/acme.sh"
if [ ! -f "$ACME_BIN" ]; then
    echo "正在安装 acme.sh..."
    curl https://get.acme.sh | sh
fi

# 注册并申请
$ACME_BIN --register-account -m $EMAIL --server $CA_SERVER

echo "🚀 正在向 ${CA_SERVER} 申请证书..."
send_tg "⏳ 正在申请证书: <code>$DOMAIN</code>"

# 尝试申请 (standalone 模式)
if ! $ACME_BIN --issue --standalone -d $DOMAIN --server $CA_SERVER; then
    echo "❌ 申请失败！"
    send_tg "<b>❌ SSL 申请失败</b>%0A域名: <code>$DOMAIN</code>%0A原因: 请检查 80 端口是否被 Nginx 占用。"
    exit 1
fi

# 安装证书到 root 目录
$ACME_BIN --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# 自动续期脚本
cat << EOF > /root/renew_cert.sh
#!/bin/bash
ACME_BIN="\$HOME/.acme.sh/acme.sh"
if \$ACME_BIN --renew -d $DOMAIN --server $CA_SERVER; then
    curl -s -X POST "https://${TG_API_DOMAIN}/bot${TG_BOT_TOKEN}/sendMessage" -d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" -d "text=<b>✅ SSL 自动续期成功</b>%0A域名: <code>$DOMAIN</code>"
else
    curl -s -X POST "https://${TG_API_DOMAIN}/bot${TG_BOT_TOKEN}/sendMessage" -d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" -d "text=<b>⚠️ SSL 自动续期失败</b>%0A域名: <code>$DOMAIN</code>"
fi
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# 最终提示
echo "✅ 证书申请成功！"
send_tg "<b>✅ SSL 部署完成</b>%0A域名: <code>$DOMAIN</code>%0A证书: <code>/root/${DOMAIN}.crt</code>"
