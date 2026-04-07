#!/bin/bash
set -e

# --- 1. 增强型推送函数 ---
send_tg_notification() {
    local message=$1
    if [[ -n "$TG_TOKEN" && -n "$TG_CHATID" ]]; then
        # 转换换行符并进行 URL 编码处理（简单处理）
        RESPONSE=$(curl -s -X POST "https://api.telegram.org" \
            --data-urlencode "chat_id=$TG_CHATID" \
            --data-urlencode "text=$message" \
            -d "parse_mode=HTML")
        
        if echo "$RESPONSE" | grep -q '"ok":true'; then
            echo "✅ Telegram 推送成功"
        else
            echo "❌ Telegram 推送失败: $RESPONSE"
            echo "请检查 Token 是否正确，或是否已向机器人发送过 /start"
        fi
    fi
}

# --- 2. 主菜单 ---
while true; do
    clear
    echo "============== SSL 证书管理 (海外服务器专用版) =============="
    echo "1) 申请 SSL 证书 (包含端口检测与 TG 推送)"
    echo "2) 重置环境 (清除记录并重新部署)"
    echo "3) 退出"
    echo "=========================================================="
    read -p "请输入选项 (1-3): " MAIN_OPTION

    case $MAIN_OPTION in
        1) break ;;
        2)
            rm -rf /tmp/acme
            bash <(curl -fsSL https://githubusercontent.com)
            exit 0
            ;;
        3) exit 0 ;;
        *) sleep 1; continue ;;
    esac
done

# --- 3. 配置输入 ---
read -p "请输入域名: " DOMAIN
read -p "请输入电子邮件: " EMAIL
read -p "请输入 TG Bot Token: " TG_TOKEN
read -p "请输入 TG Chat ID: " TG_CHATID

# 立即进行推送测试
echo "🔔 正在发送配置测试推送..."
send_tg_notification "🔔 <b>SSL 脚本配置测试</b>%0A━━━━━━━━━━━━━━%0A服务器已成功连接 TG 接口！%0A正在开始为 <code>$DOMAIN</code> 申请证书。"

echo "请选择 CA 机构: 1) Let's Encrypt | 2) Buypass | 3) ZeroSSL"
read -p "选项: " CA_OPTION
case $CA_OPTION in
    1) CA_SERVER="letsencrypt" ;;
    2) CA_SERVER="buypass" ;;
    3) CA_SERVER="zerossl" ;;
    *) exit 1 ;;
esac

# --- 4. 依赖安装 ---
. /etc/os-release
if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
    apt update -y && apt install -y curl socat git cron lsof
elif [[ "$ID" == "centos" ]]; then
    yum install -y curl socat git cronie lsof
    systemctl start crond && systemctl enable crond
fi

# --- 5. acme.sh 准备 ---
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
fi
~/.acme.sh/acme.sh --upgrade --auto-upgrade 0

# --- 6. 端口冲突自动处理 ---
echo "正在检查端口占用..."
OCCUPIED_PID=$(lsof -i:80 -t | head -n 1)
SERVICE_NAME="none"

if [ -n "$OCCUPIED_PID" ]; then
    SERVICE_NAME=$(ps -p $OCCUPIED_PID -o comm=)
    echo "⚠️ 发现 $SERVICE_NAME 占用 80 端口，尝试停止..."
    systemctl stop $SERVICE_NAME || kill -9 $OCCUPIED_PID
    sleep 2
fi

# --- 7. 执行申请 ---
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

# 申请命令增加 --listen-v4 解决可能的 IPv6 优先导致的 Connection Refused
if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER --listen-v4; then
    send_tg_notification "❌ <b>SSL 申请失败</b>%0A━━━━━━━━━━━━━━%0A域名：$DOMAIN%0A状态：验证未通过，请检查 DNS 解析或防火墙。"
    [[ "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME
    exit 1
fi

# 恢复服务
[[ "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME

# --- 8. 安装证书 ---
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# --- 9. 写入自动续期脚本 ---
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
# 续期前自动处理端口占用
OCCUPIED=\$(lsof -i:80 -t | head -n 1)
if [ -n "\$OCCUPIED" ]; then
    SVC=\$(ps -p \$OCCUPIED -o comm=)
    systemctl stop \$SVC
    if acme.sh --renew -d $DOMAIN --server $CA_SERVER --listen-v4; then
        curl -s -X POST "https://telegram.org" \
            -d "chat_id=$TG_CHATID" \
            -d "parse_mode=HTML" \
            -d "text=🔄 <b>SSL 证书自动续期成功</b>%0A域名：$DOMAIN"
    fi
    systemctl start \$SVC
fi
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# --- 10. 完成推送 ---
send_tg_notification "✅ <b>SSL 证书签发成功！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> $DOMAIN%0A<b>证书位置：</b> /root/${DOMAIN}.crt%0A<b>私钥位置：</b> /root/${DOMAIN}.key%0A<b>续期状态：</b> 已开启每日自动检测"

echo "✅ 搞定！证书已签发并开启自动续期。"
