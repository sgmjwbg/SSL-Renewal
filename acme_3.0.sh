#!/bin/bash
set -e

# --- 1. 推送函数定义 ---
send_tg_notification() {
    local message=$1
    if [[ -n "$TG_TOKEN" && -n "$TG_CHATID" ]]; then
        curl -s -X POST "https://telegram.org" \
            -d "chat_id=$TG_CHATID" \
            -d "text=$message" \
            -d "parse_mode=HTML" > /dev/null
    fi
}

# --- 2. 主菜单 ---
while true; do
    clear
    echo "============== SSL 证书管理 (自动处理端口冲突) =============="
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
read -p "请输入 TG Bot Token (跳过请回车): " TG_TOKEN
read -p "请输入 TG Chat ID (跳过请回车): " TG_CHATID

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

# --- 4. 系统环境准备 ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ 无法识别操作系统"; exit 1
fi

case $OS in
    ubuntu|debian)
        sudo apt update -y && sudo apt install -y curl socat git cron lsof
        ;;
    centos)
        sudo yum update -y && sudo yum install -y curl socat git cronie lsof
        sudo systemctl start crond && sudo systemctl enable crond
        ;;
    *) echo "❌ 不支持的操作系统: $OS"; exit 1 ;;
esac

# --- 5. acme.sh 安装/检查 ---
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
fi
~/.acme.sh/acme.sh --upgrade --auto-upgrade 0

# --- 6. 端口冲突自动处理与申请 ---
echo "正在检查 80 端口占用情况..."
OCCUPIED_BY=$(lsof -i:80 -t | head -n 1)
WAS_SERVICE_STOPPED=0

if [ -n "$OCCUPIED_BY" ]; then
    SERVICE_NAME=$(ps -p $OCCUPIED_BY -o comm=)
    echo "⚠️ 80 端口被 $SERVICE_NAME (PID: $OCCUPIED_BY) 占用，正在尝试停止..."
    systemctl stop $SERVICE_NAME || kill -9 $OCCUPIED_BY
    WAS_SERVICE_STOPPED=$SERVICE_NAME
    sleep 2
fi

# 注册账户
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

# 申请证书
if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER; then
    # 失败推送
    MSG="❌ <b>SSL 证书申请失败！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> $DOMAIN%0A<b>错误：</b> 请检查 80 端口或域名解析 (DNS/AAAA)。"
    send_tg_notification "$MSG"
    
    # 恢复服务
    [ "$WAS_SERVICE_STOPPED" != "0" ] && systemctl start $WAS_SERVICE_STOPPED
    exit 1
fi

# 申请成功，恢复之前停止的服务
if [ "$WAS_SERVICE_STOPPED" != "0" ]; then
    echo "正在恢复 $WAS_SERVICE_STOPPED 服务..."
    systemctl start $WAS_SERVICE_STOPPED
fi

# --- 7. 安装证书 ---
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# --- 8. 自动续期脚本 (包含服务重启逻辑) ---
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
# 续期时同样需要先停掉占用 80 端口的服务
if [ -n "\$(lsof -i:80)" ]; then
    SERVICE=\$(lsof -i:80 -t | xargs ps -p | tail -n 1 | awk '{print \$4}')
    systemctl stop \$SERVICE
    if acme.sh --renew -d $DOMAIN --server $CA_SERVER; then
        curl -s -X POST "https://telegram.org" \
            -d "chat_id=$TG_CHATID" \
            -d "text=🔄 <b>SSL 证书自动续期成功</b>%0A<b>域名：</b> $DOMAIN" \
            -d "parse_mode=HTML"
    fi
    systemctl start \$SERVICE
fi
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# --- 9. 完成推送 ---
MSG="✅ <b>SSL 证书申请成功！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> $DOMAIN%0A<b>状态：</b> 证书已保存在 /root/ 目录"
send_tg_notification "$MSG"

echo "✅ 证书签发成功！"
echo "📄 证书：/root/${DOMAIN}.crt"
echo "🔐 私钥：/root/${DOMAIN}.key"
