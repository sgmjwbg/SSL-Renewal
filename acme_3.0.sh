#!/bin/bash
# set -e

# --- 1. 内置 TG 配置 ---
TG_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHATID="7015616862"
TG_API_HOST="api.telegram.org"

# --- 2. 强制 IPv4 推送函数 (核心加固) ---
send_tg() {
    local msg=$1
    echo "正在通过 $TG_API_HOST 推送 TG 通知..."
    # 使用 -4 强制走 IPv4，避免部分服务器 IPv6 路由不通导致丢包
    RESPONSE=$(curl -4 -s --connect-timeout 10 -X POST "https://$TG_API_HOST/bot$TG_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TG_CHATID" \
        --data-urlencode "text=$msg" \
        -d "parse_mode=HTML")
    
    if echo "$RESPONSE" | grep -q '"ok":true'; then
        echo "✅ Telegram 推送成功！"
    else
        echo "❌ 推送失败: $RESPONSE"
        echo "💡 提示：如果显示 chat not found，请务必先在 TG 机器人点 [START]！"
    fi
}

# --- 3. 启动修复与测试 ---
clear
# 强制重置 DNS 环境
chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf

echo "============== SSL 证书管理 (TG 内置推送版) =============="
send_tg "🔔 <b>SSL 脚本已启动</b>%0A━━━━━━━━━━━━━━%0A服务器已连接 $TG_API_HOST！"

# --- 4. 主菜单 ---
while true; do
    echo "1）申请 SSL 证书"
    echo "2）重置环境（清除申请记录并重新部署）"
    echo "3）退出"
    echo "============================================"
    read -p "请输入选项（1-3）： " MAIN_OPTION

    case $MAIN_OPTION in
        1) break ;;
        2)
            echo "⚠️ 正在重置环境..."
            rm -rf /tmp/acme
            echo "✅ 已清空 /tmp/acme，准备重新部署。"
            echo "📦 正在重新执行 acme.sh ..."
            sleep 1
            # 强制修复一次 DNS 确保下载成功
            bash <(curl -fsSL https://raw.githubusercontent.com/sgmjwbg/SSL-Renewal/main/acme.sh)
            exit 0 ;;
        3) exit 0 ;;
        *) continue ;;
    esac
done

# --- 5. 获取参数 ---
read -p "请输入域名: " DOMAIN
read -p "请输入电子邮件地址: " EMAIL
send_tg "🚀 <b>任务开始</b>%0A域名：<code>$DOMAIN</code>"

# --- 6. 自动处理 80 端口占用 ---
if command -v lsof >/dev/null 2>&1; then
    OCCUPIED_PID=$(lsof -i:80 -t | head -n 1)
    if [ -n "$OCCUPIED_PID" ]; then
        SERVICE_NAME=$(ps -p $OCCUPIED_PID -o comm=)
        echo "⚠️ 停止 $SERVICE_NAME (80端口)..."
        systemctl stop $SERVICE_NAME || kill -9 $OCCUPIED_PID
        sleep 2
    fi
fi

# --- 7. 安装 acme.sh ---
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh -s email=$EMAIL
    export PATH="$HOME/.acme.sh:$PATH"
fi

# --- 8. 申请证书 ---
~/.acme.sh/acme.sh --register-account -m $EMAIL --server letsencrypt

if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server letsencrypt --listen-v4; then
    send_tg "❌ <b>SSL 签发失败</b>%0A域名：$DOMAIN"
    [ -n "$SERVICE_NAME" ] && systemctl start $SERVICE_NAME
    exit 1
fi

# 恢复服务
[ -n "$SERVICE_NAME" ] && systemctl start $SERVICE_NAME

# 安装证书
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file /root/${DOMAIN}.key --fullchain-file /root/${DOMAIN}.crt

# --- 9. 自动续期脚本 ---
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
OCCUPIED=\$(lsof -i:80 -t | head -n 1)
if [ -n "\$OCCUPIED" ]; then
    SVC=\$(ps -p \$OCCUPIED -o comm=)
    systemctl stop \$SVC
    if acme.sh --renew -d $DOMAIN --server letsencrypt --listen-v4; then
        curl -4 -s -X POST "https://$TG_API_HOST/bot$TG_TOKEN/sendMessage" \
            -d "chat_id=$TG_CHATID" -d "parse_mode=HTML" \
            -d "text=🔄 <b>SSL 证书自动续期成功</b>%0A域名：$DOMAIN"
    fi
    systemctl start \$SVC
fi
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 1 * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# --- 10. 完成推送 ---
send_tg "✅ <b>SSL 签发成功！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> <code>$DOMAIN</code>"
echo "✅ 证书签发完成，已开启自动续期。"
