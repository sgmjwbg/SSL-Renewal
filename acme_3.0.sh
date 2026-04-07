#!/bin/bash
set -e

# --- 1. 核心配置 (已填入你的信息) ---
TG_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHATID="7015616862"

# --- 2. 核心推送函数 (置顶定义) ---
send_tg() {
    local msg=$1
    # 打印调试信息到屏幕
    echo "正在推送 TG 通知..."
    curl -s -X POST "https://telegram.org" \
        --data-urlencode "chat_id=$TG_CHATID" \
        --data-urlencode "text=$msg" \
        -d "parse_mode=HTML" > /dev/null
}

# --- 3. 启动即测试 ---
clear
echo "============== SSL 证书管理 (TG 推送加固版) =============="
send_tg "🔔 <b>脚本已启动</b>%0A━━━━━━━━━━━━━━%0A服务器连接成功，准备进入菜单。"

# --- 4. 主菜单 ---
while true; do
    echo "1）申请 SSL 证书"
    echo "2）重置环境（清除申请记录并重新部署）"
    echo "3）退出"
    read -p "请输入选项（1-3）： " MAIN_OPTION

    case $MAIN_OPTION in
        1) break ;;
        2)
            echo "⚠️ 正在重置环境..."
            rm -rf /tmp/acme
            echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
            bash <(curl -fsSL https://raw.githubusercontent.com/sgmjwbg/SSL-Renewal/main/acme.sh)
            exit 0 ;;
        3) exit 0 ;;
        *) continue ;;
    esac
done

# --- 5. 获取域名与参数 ---
read -p "请输入域名: " DOMAIN
read -p "请输入电子邮件地址: " EMAIL

# 任务开始推送
send_tg "🚀 <b>任务开始</b>%0A域名：<code>$DOMAIN</code>"

echo "请选择 CA: 1) Let's Encrypt | 2) Buypass | 3) ZeroSSL"
read -p "选项: " CA_OPTION
case $CA_OPTION in
    1) CA_SERVER="letsencrypt" ;;
    2) CA_SERVER="buypass" ;;
    3) CA_SERVER="zerossl" ;;
    *) exit 1 ;;
esac

# --- 6. 系统依赖与防火墙 ---
. /etc/os-release
if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
    apt update -y && apt install -y curl socat git cron lsof
elif [[ "$ID" == "centos" ]]; then
    yum install -y curl socat git cronie lsof
    systemctl start crond && systemctl enable crond
fi

# --- 7. 自动处理 80 端口占用 (Nginx 冲突) ---
OCCUPIED_PID=$(lsof -i:80 -t | head -n 1)
SERVICE_NAME="none"
if [ -n "$OCCUPIED_PID" ]; then
    SERVICE_NAME=$(ps -p $OCCUPIED_PID -o comm=)
    echo "⚠️ 停止 $SERVICE_NAME (80端口)..."
    systemctl stop $SERVICE_NAME || kill -9 $OCCUPIED_PID
    sleep 2
fi

# --- 8. 安装 acme.sh ---
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
fi

# --- 9. 注册并签发 ---
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER --listen-v4; then
    send_tg "❌ <b>签发失败</b>%0A域名：$DOMAIN"
    [[ "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME
    exit 1
fi

# 恢复 Nginx
[[ "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME

# 安装证书
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file /root/${DOMAIN}.key --fullchain-file /root/${DOMAIN}.crt

# --- 10. 自动续期脚本 (内置变量) ---
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
OCCUPIED=\$(lsof -i:80 -t | head -n 1)
if [ -n "\$OCCUPIED" ]; then
    SVC=\$(ps -p \$OCCUPIED -o comm=)
    systemctl stop \$SVC
    if acme.sh --renew -d $DOMAIN --server $CA_SERVER --listen-v4; then
        curl -s -X POST "https://telegram.org" \
            -d "chat_id=$TG_CHATID" -d "parse_mode=HTML" \
            -d "text=🔄 <b>SSL 证书自动续期成功</b>%0A域名：$DOMAIN"
    fi
    systemctl start \$SVC
fi
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# --- 11. 最终成功推送 ---
send_tg "✅ <b>SSL 签发成功！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> <code>$DOMAIN</code>%0A<b>位置：</b> /root/${DOMAIN}.crt"

echo "✅ 任务完成！"
