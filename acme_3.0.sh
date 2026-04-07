#!/bin/bash
set -e

# --- 1. 内置 TG 配置 ---
TG_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHATID="7015616862"
TG_API_HOST="api.telegram.org"

# --- 2. 增强型推送函数 ---
send_tg() {
    local msg=$1
    echo "正在发送 TG 通知..."
    
    # 强制 IPv4 并增加超时检测，处理后的响应存入 RESPONSE
    RESPONSE=$(curl -4 -s --connect-timeout 10 -X POST "https://$TG_API_HOST/bot$TG_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TG_CHATID" \
        --data-urlencode "text=$msg" \
        -d "parse_mode=HTML")

    if echo "$RESPONSE" | grep -q '"ok":true'; then
        echo "✅ Telegram 推送成功！"
    else
        echo "❌ 推送失败，详情: $RESPONSE"
        # 常见错误快速诊断
        if echo "$RESPONSE" | grep -q "400"; then
            echo "💡 提示：请确认你是否已在 Telegram 中点击了机器人的 [START] 按钮。"
        elif echo "$RESPONSE" | grep -q "401"; then
            echo "💡 提示：Token 无效，请检查是否填写正确。"
        fi
    fi
}

        
# --- 3. 启动优化环境 ---
clear
echo "🔧 优化网络解析环境..."
chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf

echo "============== SSL 证书管理 (多域名全量续期版)(tg推送) =============="
send_tg "🔔 <b>SSL 管理脚本已启动</b>%0A━━━━━━━━━━━━━━%0A服务器已连接 $TG_API_HOST"

# --- 4. 主菜单 ---
while true; do
    echo "1）申请新的 SSL 证书"
    echo "2）重置环境（清除申请记录并重新部署）"
    echo "3）退出"
    echo "=========================================================="
    read -p "请输入选项（1-3）： " MAIN_OPTION

    case $MAIN_OPTION in
        1) break ;;
        2)
            echo "⚠️ 正在重置环境..."
            rm -rf /tmp/acme
            bash <(curl -fsSL https://raw.githubusercontent.com/sgmjwbg/SSL-Renewal/main/acme.sh)
            exit 0 ;;
        3) exit 0 ;;
        *) continue ;;
    esac
done

# --- 5. 获取参数 ---
read -p "请输入要申请的域名: " DOMAIN
read -p "请输入联系电子邮件: " EMAIL

# --- 6. 系统依赖与端口检查 ---
. /etc/os-release
if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
    apt update -y && apt install -y curl socat git cron lsof
elif [[ "$ID" == "centos" ]]; then
    yum install -y curl socat git cronie lsof
    systemctl start crond && systemctl enable crond
fi

# 检查 80 端口占用
OCCUPIED_PID=$(lsof -i:80 -t | head -n 1)
SERVICE_NAME="none"
if [ -n "$OCCUPIED_PID" ]; then
    SERVICE_NAME=$(ps -p $OCCUPIED_PID -o comm=)
    echo "⚠️ 停止 $SERVICE_NAME (80端口) 以便验证域名..."
    systemctl stop $SERVICE_NAME || kill -9 $OCCUPIED_PID
    sleep 2
fi

# --- 7. 安装 acme.sh ---
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh -s email=$EMAIL
    export PATH="$HOME/.acme.sh:$PATH"
fi

# --- 8. 签发当前域名证书 ---
~/.acme.sh/acme.sh --register-account -m $EMAIL --server letsencrypt

if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server letsencrypt --listen-v4; then
    send_tg "❌ <b>SSL 签发失败</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> <code>$DOMAIN</code>%0A<b>原因：</b> 验证未通过，请检查解析。"
    [ -n "$SERVICE_NAME" ] && systemctl start $SERVICE_NAME
    exit 1
fi

# 恢复服务
[ -n "$SERVICE_NAME" ] && systemctl start $SERVICE_NAME

# 安装证书
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file /root/${DOMAIN}.key --fullchain-file /root/${DOMAIN}.crt

# --- 9. 【核心修改】设置全量自动续期脚本 ---
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"

# 1. 检查并停止占用 80 端口的服务
OCCUPIED=\$(lsof -i:80 -t | head -n 1)
if [ -n "\$OCCUPIED" ]; then
    SVC=\$(ps -p \$OCCUPIED -o comm=)
    systemctl stop \$SVC
fi

# 2. 执行全量续期任务 (检查所有已存在的证书)
if acme.sh --cron --home "\$HOME/.acme.sh"; then
    # 汇总通知
    curl -4 -s -X POST "https://$TG_API_HOST/bot$TG_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TG_CHATID" \
        --data-urlencode "text=🔄 <b>SSL 证书全量续期任务完成</b>%0A━━━━━━━━━━━━━━%0A<b>时间：</b> \$(date '+%Y-%m-%d %H:%M:%S')%0A<b>状态：</b> 所有符合条件的证书已自动更新。" \
        -d "parse_mode=HTML"
fi

# 3. 恢复服务启动
[ -n "\$SVC" ] && systemctl start \$SVC
EOF
chmod +x /root/renew_cert.sh

# 设置每月 1 号执行全量检查
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 1 * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# --- 10. 完成推送 (排版美化) ---
send_tg "✅ <b>SSL 证书签发成功！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> <code>$DOMAIN</code>%0A<b>有效期：</b> 90天 (已设全量自动续期)%0A<b>证书位置：</b> <code>/root/${DOMAIN}.crt</code>%0A<b>签发时间：</b> $(date '+%Y-%m-%d %H:%M:%S')"

echo "✅ 任务完成！您可以继续运行此脚本为其他域名申请证书。"
echo "✅ 证书签发完成，已开启自动续期。"
echo "📄 证书路径: /root/${DOMAIN}.crt"
echo "🔐 私钥路径: /root/${DOMAIN}.key"
