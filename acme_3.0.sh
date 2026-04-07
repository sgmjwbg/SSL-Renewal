#!/bin/bash
set -e

# --- 1. 推送函数定义 ---
send_tg_notification() {
    local message=$1
    if [[ -n "$TG_TOKEN" && -n "$TG_CHATID" ]]; then
        # 使用 curl 推送至 Telegram，消息经过 URL 编码以支持中文和换行
        curl -s -X POST "https://telegram.org" \
            -d "chat_id=$TG_CHATID" \
            -d "text=$message" \
            -d "parse_mode=HTML" > /dev/null
    else
        echo "⚠️ 未配置 TG 机器人信息，跳过推送。"
    fi
}

# --- 2. 主菜单 ---
while true; do
    clear
    echo "============== SSL 证书管理菜单 (含中文推送) =============="
    echo "1) 申请 SSL 证书"
    echo "2) 重置环境 (清除申请记录并重新部署)"
    echo "3) 退出"
    echo "=========================================================="
    read -p "请输入选项 (1-3): " MAIN_OPTION

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

# --- 3. 用户输入 ---
read -p "请输入域名: " DOMAIN
read -p "请输入电子邮件地址: " EMAIL
read -p "请输入 TG Bot Token (直接回车跳过): " TG_TOKEN
read -p "请输入 TG Chat ID (直接回车跳过): " TG_CHATID

echo "请选择证书颁发机构 (CA):"
echo "1) Let's Encrypt"
echo "2) Buypass"
echo "3) ZeroSSL"
read -p "输入选项 (1-3): " CA_OPTION
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

# --- 4. 系统依赖安装 ---
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

# --- 5. acme.sh 安装 ---
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
    ~/.acme.sh/acme.sh --upgrade
fi

# --- 6. 证书申请 ---
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER; then
    # 失败推送
    MSG="❌ <b>SSL 证书申请失败！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> $DOMAIN%0A<b>原因：</b> 签发过程出错，请检查日志。%0A<b>时间：</b> $(date '+%Y-%m-%d %H:%M:%S')"
    send_tg_notification "$MSG"
    
    rm -f /root/${DOMAIN}.key /root/${DOMAIN}.crt
    ~/.acme.sh/acme.sh --remove -d $DOMAIN
    exit 1
fi

# --- 7. 安装证书 ---
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# --- 8. 自动续期脚本 (含中文推送) ---
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
if acme.sh --renew -d $DOMAIN --server $CA_SERVER; then
    curl -s -X POST "https://telegram.org" \
        -d "chat_id=$TG_CHATID" \
        -d "text=🔄 <b>SSL 证书续期成功</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> $DOMAIN%0A<b>状态：</b> 证书已更新并应用。" \
        -d "parse_mode=HTML"
fi
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# --- 9. 完成提示 ---
# 成功推送
MSG="✅ <b>SSL 证书申请成功！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> $DOMAIN%0A<b>机构：</b> $CA_SERVER%0A<b>续期：</b> 已开启每日检测%0A<b>时间：</b> $(date '+%Y-%m-%d %H:%M:%S')"
send_tg_notification "$MSG"

echo "✅ 恭喜！SSL 证书已成功签发。"
echo "📄 证书位置: /root/${DOMAIN}.crt"
echo "🔐 私钥位置: /root/${DOMAIN}.key"
