#!/bin/bash
set -e

# --- 1. 内置 TG 配置 ---
TG_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHATID="7015616862"
TG_API_HOST="api.telegram.org"

# --- 2. 增强型推送函数 (置顶定义) ---
send_tg() {
    local message=$1
    # 使用 URL 编码发送，确保中文显示正常
    curl -s -X POST "https://$TG_API_HOST/bot$TG_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TG_CHATID" \
        --data-urlencode "text=$message" \
        -d "parse_mode=HTML" > /dev/null || echo "⚠️ TG 推送失败"
}

# --- 3. 脚本启动及环境优化 ---
clear
echo "🔧 正在优化网络解析..."
# 强制写入 DNS，解决解析 githubusercontent.com 失败的问题
echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf

echo "============== SSL 证书管理 (内置推送版) =============="
send_tg "🔔 <b>SSL 脚本已启动</b>%0A━━━━━━━━━━━━━━%0A服务器连接成功，准备开始流程。"

# --- 4. 主菜单 ---
while true; do
    clear
    echo "============== SSL证书管理菜单 =============="
    echo "1）申请 SSL 证书"
    echo "2）重置环境（清除申请记录并重新部署）"
    echo "3）退出"
    echo "============================================"
    read -p "请输入选项（1-3）： " MAIN_OPTION

    case $MAIN_OPTION in
        1)
            break
            ;;
        2)
            echo "⚠️ 正在重置环境..."
            rm -rf /tmp/acme
            echo "✅ 已清空 /tmp/acme，准备重新部署。"
            echo "📦 正在重新下载并执行脚本..."
            sleep 1
            # 使用正确的 raw 原始链接
            bash <(curl -fsSL https://raw.githubusercontent.com/sgmjwbg/SSL-Renewal/main/acme.sh)
            exit 0
            ;;
        3)
            echo "👋 已退出。"
            exit 0
            ;;
        *)
            echo "❌ 无效选项，请重新输入。"
            sleep 1
            continue
            ;;
    esac
done

# --- 5. 获取用户输入 ---
read -p "请输入域名: " DOMAIN
read -p "请输入电子邮件地址: " EMAIL

# 发送任务启动通知
send_tg "🔔 <b>SSL 任务启动</b>%0A域名：<code>$DOMAIN</code>"

echo "请选择证书颁发机构（CA）："
echo "1）Let's Encrypt"
echo "2）Buypass"
echo "3）ZeroSSL"
read -p "输入选项（1-3）： " CA_OPTION
case $CA_OPTION in
    1) CA_SERVER="letsencrypt" ;;
    2) CA_SERVER="buypass" ;;
    3) CA_SERVER="zerossl" ;;
    *) echo "❌ 无效选项"; exit 1 ;;
esac

echo "是否关闭防火墙？"
echo "1）是"
echo "2）否"
read -p "输入选项（1 或 2）：" FIREWALL_OPTION

if [ "$FIREWALL_OPTION" -eq 2 ]; then
    echo "是否放行特定端口？"
    echo "1）是"
    echo "2）否"
    read -p "输入选项（1 或 2）：" PORT_OPTION
    if [ "$PORT_OPTION" -eq 1 ]; then
        read -p "请输入要放行的端口号: " PORT
    fi
else
    PORT_OPTION=0
fi

# --- 6. 检查系统与安装依赖 ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ 无法识别操作系统"; exit 1
fi

case $OS in
    ubuntu|debian)
        sudo apt update -y
        sudo apt install -y curl socat git cron lsof
        [[ "$FIREWALL_OPTION" -eq 1 ]] && (command -v ufw >/dev/null 2>&1 && sudo ufw disable)
        [[ "$PORT_OPTION" -eq 1 ]] && (command -v ufw >/dev/null 2>&1 && sudo ufw allow $PORT)
        ;;
    centos)
        sudo yum update -y
        sudo yum install -y curl socat git cronie lsof
        sudo systemctl start crond && sudo systemctl enable crond
        [[ "$FIREWALL_OPTION" -eq 1 ]] && (sudo systemctl stop firewalld && sudo systemctl disable firewalld)
        [[ "$PORT_OPTION" -eq 1 ]] && (sudo firewall-cmd --permanent --add-port=${PORT}/tcp && sudo firewall-cmd --reload)
        ;;
esac

# --- 7. 自动处理 80 端口占用 (Nginx冲突解决) ---
OCCUPIED_PID=$(lsof -i:80 -t | head -n 1)
SERVICE_NAME="none"
if [ -n "$OCCUPIED_PID" ]; then
    SERVICE_NAME=$(ps -p $OCCUPIED_PID -o comm=)
    echo "⚠️ 发现 $SERVICE_NAME 占用 80 端口，正在停止以进行验证..."
    systemctl stop $SERVICE_NAME || kill -9 $OCCUPIED_PID
    sleep 2
fi

# --- 8. 安装 acme.sh 并申请 ---
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://get.acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
    ~/.acme.sh/acme.sh --upgrade
fi

~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

# 申请证书 (增加 --listen-v4 解决可能的 IPv6 优先导致失败的问题)
if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER --listen-v4; then
    send_tg "❌ <b>SSL 申请失败</b>%0A域名：$DOMAIN"
    echo "❌ 证书申请失败，正在清理。"
    [[ "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME
    rm -f /root/${DOMAIN}.key /root/${DOMAIN}.crt
    ~/.acme.sh/acme.sh --remove -d $DOMAIN
    exit 1
fi

# 恢复之前停止的服务
[[ "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME

# --- 9. 安装证书 ---
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# --- 10. 自动续期脚本 (包含服务停启推送) ---
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
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

# --- 11. 完成提示 ---
send_tg "✅ <b>SSL 签发成功！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> <code>$DOMAIN</code>%0A<b>路径：</b> /root/${DOMAIN}.crt"
echo "✅ SSL证书申请完成！"
echo "📄 证书路径: /root/${DOMAIN}.crt"
echo "🔐 私钥路径: /root/${DOMAIN}.key"
