#!/bin/bash
set -e

# ==================== Telegram 配置 ====================
# 1. 找 @BotFather 获取 Token
# 2. 找 @userinfobot 获取 Chat ID
TG_BOT_TOKEN="你的_BOT_TOKEN"
TG_CHAT_ID="你的_CHAT_ID"

# 如果服务器在国内，请修改下方的域名为反代地址（例如：tgproxy.librespeed.org）
TG_API_DOMAIN="api.telegram.org"

# TG 发送函数 (增加了超时检测和错误输出)
send_tg() {
    local msg="$1"
    echo "📡 正在发送 TG 通知..."
    curl -s -m 10 -X POST "https://${TG_API_DOMAIN}/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${msg}" \
        -d "parse_mode=HTML" || echo "⚠️ TG 通知发送失败，请检查网络或 Token。"
}
# ======================================================

# 启动即测试通知
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
            rm -rf /tmp/acme
            send_tg "🔄 正在重置 acme 环境..."
            bash <(curl -fsSL https://githubusercontent.com)
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

# 依赖与防火墙 (自动识别并处理)
. /etc/os-release
OS=$ID
echo "📦 正在安装依赖..."
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt update -y && sudo apt install -y curl socat git cron
elif [ "$OS" = "centos" ]; then
    sudo yum install -y curl socat git cronie
    sudo systemctl enable --now crond
fi

# 安装 acme.sh
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
fi

# 注册并申请
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

echo "🚀 正在向 ${CA_SERVER} 申请证书..."
if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER; then
    echo "❌ 申请失败！"
    send_tg "<b>❌ SSL 申请失败</b>%0A域名: <code>$DOMAIN</code>%0A原因: 验证失败，请检查 80 端口是否被占用。"
    exit 1
fi

# 安装证书到 root 目录
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# 自动续期脚本 (含 TG 通知)
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
if acme.sh --renew -d $DOMAIN --server $CA_SERVER; then
    curl -s -X POST "https://${TG_API_DOMAIN}/bot${TG_BOT_TOKEN}/sendMessage" -d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" -d "text=<b>✅ SSL 自动续期成功</b>%0A域名: <code>$DOMAIN</code>"
else
    curl -s -X POST "https://${TG_API_DOMAIN}/bot${TG_BOT_TOKEN}/sendMessage" -d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" -d "text=<b>⚠️ SSL 自动续期失败</b>%0A域名: <code>$DOMAIN</code>"
fi
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# 最终提示
echo "✅ 证书申请成功！"
send_tg "<b>✅ SSL 部署完成</b>%0A域名: <code>$DOMAIN</code>%0A证书: <code>/root/${DOMAIN}.crt</code>%0A私钥: <code>/root/${DOMAIN}.key</code>"
