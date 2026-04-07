#!/bin/bash
# set -e  # 为了防止 DNS 修复失败导致脚本直接中断，这里可以视情况取消或保留

# --- 1. 内置 TG 配置 ---
TG_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHATID="7015616862"
TG_API_HOST="api.telegram.org"

# --- 2. 【核心修复】函数定义必须置顶，确保菜单和业务逻辑都能调用 ---
send_tg() {
    local message=$1
    if [[ -n "$TG_TOKEN" && -n "$TG_CHATID" ]]; then
        curl -s -X POST "https://$TG_API_HOST/bot$TG_TOKEN/sendMessage" \
            --data-urlencode "chat_id=$TG_CHATID" \
            --data-urlencode "text=$message" \
            -d "parse_mode=HTML" > /dev/null || echo "⚠️ TG 推送失败"
    fi
}

# --- 3. 脚本启动测试 ---
clear
echo "============== SSL 证书管理 (TG内置推送版) =============="
send_tg "🔔 <b>SSL 脚本已启动</b>%0A━━━━━━━━━━━━━━%0A服务器连接成功，准备进入菜单。"

# --- 4. 主菜单 ---
while true; do
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
            echo "🔧 正在强制修复 DNS 解析..."
            # 解除文件锁定并写入 DNS
            chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
            echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
            
            echo "⚠️ 正在重置环境..."
            rm -rf /tmp/acme
            echo "✅ 已清空 /tmp/acme，准备从 GitHub 重新部署..."
            sleep 1
            
            # 修正后的完整 URL 路径 + 镜像源备选
            RAW_URL="https://githubusercontent.com"
            MIRROR_URL="https://gitmirror.com"
            
            if ! bash <(curl -fsSL $RAW_URL); then
                echo "⚠️ 官方源解析失败，正在尝试加速镜像..."
                bash <(curl -fsSL $MIRROR_URL)
            fi
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

# --- 5. 业务逻辑 (域名申请) ---
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
    *) exit 1 ;;
esac

# 端口检查逻辑
if command -v lsof >/dev/null 2>&1; then
    OCCUPIED_PID=$(lsof -i:80 -t | head -n 1)
    if [ -n "$OCCUPIED_PID" ]; then
        SERVICE_NAME=$(ps -p $OCCUPIED_PID -o comm=)
        echo "⚠️ 发现 $SERVICE_NAME 占用 80 端口，正在停止..."
        systemctl stop $SERVICE_NAME || kill -9 $OCCUPIED_PID
        sleep 2
    fi
fi

# 安装 acme.sh (如未安装)
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
fi

# 注册并申请证书
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER --listen-v4; then
    send_tg "❌ <b>SSL 申请失败</b>%0A域名：$DOMAIN"
    [ -n "$SERVICE_NAME" ] && systemctl start $SERVICE_NAME
    exit 1
fi

# 恢复服务
[ -n "$SERVICE_NAME" ] && systemctl start $SERVICE_NAME

# 安装证书到 root 目录
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# 续期任务配置
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

# 完成推送
send_tg "✅ <b>SSL 签发成功！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> $DOMAIN%0A<b>位置：</b> /root/${DOMAIN}.crt"

echo "✅ 任务完成！证书已生成。"
