#!/bin/bash
set -e

# --- 1. 环境准备与函数定义 ---
send_tg_notification() {
    local message=$1
    if [[ -n "$TG_TOKEN" && -n "$TG_CHATID" ]]; then
        curl -s -X POST "https://telegram.org" \
            -d "chat_id=$TG_CHATID" \
            -d "text=$message" \
            -d "parse_mode=HTML" > /dev/null
    else
        echo "⚠️ 跳过 TG 推送（未配置 Token 或 Chat ID）"
    fi
}

# --- 2. 主菜单 ---
while true; do
    clear
    echo "============== SSL 证书管理菜单 (含 TG 推送) =============="
    echo "1) 申请 SSL 证书"
    echo "2) 重置环境（清除申请记录并重新部署）"
    echo "3) 退出"
    echo "=========================================================="
    read -p "请输入选项（1-3）： " MAIN_OPTION

    case $MAIN_OPTION in
        1) break ;;
        2)
            echo "⚠️ 正在重置环境..."
            rm -rf /tmp/acme
            echo "✅ 已清空 /tmp/acme，准备重新部署。"
            bash <(curl -fsSL https://githubusercontent.com)
            exit 0
            ;;
        3) echo "👋 已退出。"; exit 0 ;;
        *) echo "❌ 无效选项"; sleep 1; continue ;;
    esac
done

# --- 3. 获取用户输入 ---
read -p "请输入域名: " DOMAIN
read -p "请输入电子邮件地址: " EMAIL
read -p "请输入 Telegram Bot Token (直接回车跳过): " TG_TOKEN
read -p "请输入 Telegram Chat ID (直接回车跳过): " TG_CHATID

echo "请选择证书颁发机构（CA）："
echo "1) Let's Encrypt"
echo "2) Buypass"
echo "3) ZeroSSL"
read -p "输入选项（1-3）： " CA_OPTION
case $CA_OPTION in
    1) CA_SERVER="letsencrypt" ;;
    2) CA_SERVER="buypass" ;;
    3) CA_SERVER="zerossl" ;;
    *) echo "❌ 无效选项"; exit 1 ;;
esac

echo "是否关闭防火墙？(1.是 / 2.否)"
read -p "输入选项: " FIREWALL_OPTION

if [ "$FIREWALL_OPTION" -eq 2 ]; then
    read -p "是否放行特定端口？(1.是 / 2.否): " PORT_OPTION
    if [ "$PORT_OPTION" -eq 1 ]; then
        read -p "请输入要放行的端口号: " PORT
    fi
fi

# --- 4. 安装依赖与配置防火墙 ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ 无法识别操作系统"; exit 1
fi

case $OS in
    ubuntu|debian)
        sudo apt update -y && sudo apt install -y curl socat git cron
        [[ "$FIREWALL_OPTION" -eq 1 ]] && sudo ufw disable || { [[ "$PORT_OPTION" -eq 1 ]] && sudo ufw allow $PORT; }
        ;;
    centos)
        sudo yum update -y && sudo yum install -y curl socat git cronie
        sudo systemctl start crond && sudo systemctl enable crond
        [[ "$FIREWALL_OPTION" -eq 1 ]] && { sudo systemctl stop firewalld; sudo systemctl disable firewalld; } || \
        { [[ "$PORT_OPTION" -eq 1 ]] && { sudo firewall-cmd --permanent --add-port=${PORT}/tcp; sudo firewall-cmd --reload; }; }
        ;;
    *) echo "❌ 不支持的操作系统: $OS"; exit 1 ;;
esac

# --- 5. 安装 acme.sh ---
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
    ~/.acme.sh/acme.sh --upgrade
fi

# --- 6. 注册账户与申请证书 ---
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER; then
    MSG="❌ <b>SSL 申请失败</b>%0A<b>域名:</b> $DOMAIN%0A<b>原因:</b> 签发过程出错，请检查日志。"
    send_tg_notification "$MSG"
    rm -f /root/${DOMAIN}.key /root/${DOMAIN}.crt
    ~/.acme.sh/acme.sh --remove -d $DOMAIN
    exit 1
fi

# --- 7. 安装证书 ---
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# --- 8. 自动续期脚本 (带通知) ---
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
if acme.sh --renew -d $DOMAIN --server $CA_SERVER; then
    curl -s -X POST "https://telegram.org" \
        -d "chat_id=$TG_CHATID" \
        -d "text=🔄 <b>SSL 证书自动续期成功</b>%0A<b>域名:</b> $DOMAIN" \
        -d "parse_mode=HTML"
fi
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# --- 9. 完成提示 ---
MSG="✅ <b>SSL 证书申请成功</b>%0A<b>域名:</b> $DOMAIN%0A<b>路径:</b> /root/${DOMAIN}.crt%0A<b>自动续期:</b> 已开启"
send_tg_notification "$MSG"

echo "✅ SSL证书申请完成！"
echo "📄 证书路径: /root/${DOMAIN}.crt"
echo "🔐 私钥路径: /root/${DOMAIN}.key"
