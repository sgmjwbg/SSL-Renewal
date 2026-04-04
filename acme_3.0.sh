#!/bin/bash
set -e

# ==================== Telegram 配置 ====================
# 请在这里填写你的机器人 Token 和 用户 ID
TG_BOT_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHAT_ID="1957625818"

# TG 发送函数
send_tg() {
    local msg="$1"
    curl -s -X POST "https://telegram.org{TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${msg}" \
        -d "parse_mode=HTML" > /dev/null
}
# ======================================================

# 主菜单
while true; do
    clear
    echo "============== SSL证书管理菜单 (含TG通知) =============="
    echo "1）申请 SSL 证书"
    echo "2）重置环境（清除申请记录并重新部署）"
    echo "3）退出"
    echo "========================================================"
    read -p "请输入选项（1-3）： " MAIN_OPTION

    case $MAIN_OPTION in
        1) break ;;
        2)
            echo "⚠️ 正在重置环境..."
            rm -rf /tmp/acme
            echo "✅ 已清空 /tmp/acme。"
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

echo "请选择证书颁发机构（CA）："
echo "1）Let's Encrypt (注意频率限制)"
echo "2）Buypass"
echo "3）ZeroSSL (推荐)"
read -p "输入选项（1-3）： " CA_OPTION
case $CA_OPTION in
    1) CA_SERVER="letsencrypt" ;;
    2) CA_SERVER="buypass" ;;
    3) CA_SERVER="zerossl" ;;
    *) echo "❌ 无效选项"; exit 1 ;;
esac

# 防火墙逻辑
read -p "是否关闭防火墙？(1.是 2.否): " FIREWALL_OPTION
if [ "$FIREWALL_OPTION" -eq 2 ]; then
    read -p "是否放行特定端口？(1.是 2.否): " PORT_OPTION
    [ "$PORT_OPTION" -eq 1 ] && read -p "请输入端口号: " PORT
fi

# 依赖安装 (简略逻辑)
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
        [ "$FIREWALL_OPTION" -eq 1 ] && { sudo systemctl stop firewalld; sudo systemctl disable firewalld; } || { [ "$PORT_OPTION" -eq 1 ] && { sudo firewall-cmd --permanent --add-port=${PORT}/tcp; sudo firewall-cmd --reload; }; }
        ;;
esac

# 安装 acme.sh
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
fi

# 注册并申请
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

echo "🚀 正在申请证书，请稍候..."
if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER; then
    echo "❌ 证书申请失败！"
    send_tg "<b>❌ SSL 申请失败</b>%0A域名: <code>$DOMAIN</code>%0A原因: 验证未通过，请检查端口占用或解析。"
    exit 1
fi

# 安装证书
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# 自动续期脚本 (集成 TG 通知)
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
if acme.sh --renew -d $DOMAIN --server $CA_SERVER; then
    curl -s -X POST "https://telegram.org{TG_BOT_TOKEN}/sendMessage" -d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" -d "text=<b>✅ SSL 自动续期成功</b>%0A域名: <code>$DOMAIN</code>"
else
    curl -s -X POST "https://telegram.org{TG_BOT_TOKEN}/sendMessage" -d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" -d "text=<b>⚠️ SSL 自动续期失败</b>%0A域名: <code>$DOMAIN</code>%0A请检查服务器 80 端口是否被占用。"
fi
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# 最终提示
echo "✅ 申请成功！"
send_tg "<b>✅ SSL 证书已部署</b>%0A域名: <code>$DOMAIN</code>%0A证书路径: <code>/root/${DOMAIN}.crt</code>%0A续期任务已加入 crontab。"
