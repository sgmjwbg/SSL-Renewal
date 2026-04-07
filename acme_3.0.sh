#!/bin/bash
set -e

# --- 1. 内置 TG 配置 ---
TG_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHATID="7015616862"
TG_API_HOST="api.telegram.org"

# --- 2. 增强型推送函数 ---
send_tg_notification() {
    local message=$1
    echo "正在发送 TG 推送测试..."
    # 使用内置变量进行推送
    RESPONSE=$(curl -s -X POST "https://$TG_API_HOST/bot$TG_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TG_CHATID" \
        --data-urlencode "text=$message" \
        -d "parse_mode=HTML")
    
    if echo "$RESPONSE" | grep -q '"ok":true'; then
        echo "✅ Telegram 推送成功！"
    else
        echo "❌ Telegram 推送失败，详情: $RESPONSE"
        echo "⚠️ 请确认你是否已在 Telegram 中点击了机器人的 [START] 按钮。"
    fi
}

# --- 3. 脚本启动及环境检查 ---
clear
echo "============== SSL 证书管理 (内置推送版) =============="
# 立即测试推送
send_tg_notification "🔔 <b>SSL 脚本已启动</b>%0A━━━━━━━━━━━━━━%0A服务器已成功连接 TG 接口！%0A正在准备申请流程..."

# --- 4. 主菜单 ---
while true; do
    echo "1) 开始申请 SSL 证书"
    echo "2) 重置环境 (清除记录并重新部署)"
    echo "3) 退出"
    read -p "请输入选项 (1-3): " MAIN_OPTION
    case $MAIN_OPTION in
        1) break ;;
        2) rm -rf /tmp/acme && bash <(curl -fsSL https://githubusercontent.com); exit 0 ;;
        3) exit 0 ;;
        *) continue ;;
    esac
done

# --- 5. 获取域名与 CA ---
read -p "请输入要申请的域名: " DOMAIN
read -p "请输入注册邮箱: " EMAIL

echo "请选择 CA: 1) Let's Encrypt | 2) Buypass | 3) ZeroSSL"
read -p "选项: " CA_OPTION
case $CA_OPTION in
    1) CA_SERVER="letsencrypt" ;;
    2) CA_SERVER="buypass" ;;
    3) CA_SERVER="zerossl" ;;
    *) exit 1 ;;
esac

# --- 6. 端口冲突自动处理 ---
echo "正在检查 80 端口..."
OCCUPIED_PID=$(lsof -i:80 -t | head -n 1)
SERVICE_NAME="none"
if [ -n "$OCCUPIED_PID" ]; then
    SERVICE_NAME=$(ps -p $OCCUPIED_PID -o comm=)
    echo "⚠️ 停止 $SERVICE_NAME 以释放端口..."
    systemctl stop $SERVICE_NAME || kill -9 $OCCUPIED_PID
    sleep 2
fi

# --- 7. 安装 acme.sh 并申请 ---
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
fi
~/.acme.sh/acme.sh --upgrade --auto-upgrade 0
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

# 申请证书 (增加 --listen-v4 兼容性)
if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER --listen-v4; then
    send_tg_notification "❌ <b>SSL 申请失败</b>%0A域名：$DOMAIN%0A请检查解析是否生效。"
    [[ "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME
    exit 1
fi

# 恢复服务
[[ "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME

# --- 8. 安装证书并设置续期 ---
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file /root/${DOMAIN}.key --fullchain-file /root/${DOMAIN}.crt

# 写入包含内置变量的续期脚本
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
# 续期逻辑
OCCUPIED=\$(lsof -i:80 -t | head -n 1)
if [ -n "\$OCCUPIED" ]; then
    SVC=\$(ps -p \$OCCUPIED -o comm=)
    systemctl stop \$SVC
    if acme.sh --renew -d $DOMAIN --server $CA_SERVER --listen-v4; then
        curl -s -X POST "https://$TG_API_HOST/bot$TG_TOKEN/sendMessage" \
            -d "chat_id=$TG_CHATID" -d "parse_mode=HTML" \
            -d "text=🔄 <b>SSL 证书续期成功</b>%0A域名：$DOMAIN"
    fi
    systemctl start \$SVC
fi
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# --- 9. 完成通知 ---
send_tg_notification "✅ <b>SSL 证书签发成功！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> $DOMAIN%0A<b>路径：</b> /root/${DOMAIN}.crt"

echo "✅ 搞定！证书已签发。"
