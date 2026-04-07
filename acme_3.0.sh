#!/bin/bash
set -e

# --- 1. 内置 TG 配置 ---
TG_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHATID="7015616862"
TG_API_HOST="api.telegram.org"

# --- 2. 核心推送函数 (确保中文与排版正常) ---
send_tg() {
    local msg="$1"
    # 使用 --data-urlencode 确保中文不乱码，且换行符生效
    RESPONSE=$(curl -4 -s --connect-timeout 10 -X POST "https://$TG_API_HOST/bot$TG_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TG_CHATID" \
        --data-urlencode "text=$msg" \
        -d "parse_mode=HTML")
    
    if echo "$RESPONSE" | grep -q '"ok":true'; then
        echo "✅ Telegram 推送成功！"
    else
        echo "❌ 推送失败: $RESPONSE"
    fi
}

# --- 3. 环境优化与主菜单 ---
clear
chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf

while true; do
    echo "============== SSL 证书管理 (中文完美版) =============="
    echo "1) 申请新的 SSL 证书 (HTTP 模式 - 需停 80 端口)"
    echo "2) 申请新的 SSL 证书 (DNS 模式 - 不停服务/支持通配符)"
    echo "3) 重置环境 (清除记录并重新部署)"
    echo "4) 测试 Telegram 推送排版"
    echo "5) 退出脚本"
    echo "======================================================"
    read -p "请输入选项 (1-5): " MAIN_OPTION
    case $MAIN_OPTION in
        1|2) break ;;
        3) 
            echo "⚠️ 正在重置环境..."
            rm -rf /tmp/acme
            bash <(curl -fsSL https://raw.githubusercontent.com/sgmjwbg/SSL-Renewal/main/acme.sh)
            exit 0 ;;
        4)
            echo "🔔 正在发送中文排版测试..."
            TEST_MSG="🧪 <b>Telegram 推送测试成功！</b>
━━━━━━━━━━━━━━
<b>测试域名：</b> <code>test.example.com</code>
<b>换行功能：</b> 正常换行
<b>代码块：</b> <code>点击内容可直接复制</code>
<b>发送时间：</b> $(date '+%Y-%m-%d %H:%M:%S')"
            send_tg "$TEST_MSG"
            echo "✅ 已发送测试，请查看手机 Telegram。"
            sleep 2; clear; continue ;;
        5) exit 0 ;;
        *) continue ;;
    esac
done

# --- 4. 获取通用参数 ---
read -p "请输入要申请的域名 (例如 example.com): " DOMAIN
read -p "请输入联系电子邮件: " EMAIL

# 如果是 DNS 模式，额外获取 Cloudflare 密钥
if [ "$MAIN_OPTION" -eq 2 ]; then
    echo "--- Cloudflare DNS API 配置 ---"
    read -p "请输入 Cloudflare 账号邮箱: " CF_Email
    read -p "请输入 Cloudflare Global API Key: " CF_Key
    export CF_Email="$CF_Email"
    export CF_Key="$CF_Key"
fi

# --- 5. 安装依赖与端口检查 ---
. /etc/os-release
if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
    apt update -y && apt install -y curl socat git cron lsof
elif [[ "$ID" == "centos" ]]; then
    yum install -y curl socat git cronie lsof
    systemctl start crond && systemctl enable crond
fi

# --- 6. 申请逻辑 ---
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh -s email=$EMAIL
    export PATH="$HOME/.acme.sh:$PATH"
fi

# 注册账户
~/.acme.sh/acme.sh --register-account -m $EMAIL --server letsencrypt

if [ "$MAIN_OPTION" -eq 1 ]; then
    # HTTP 模式原有逻辑：检查并停止 80 端口
    OCCUPIED_PID=$(lsof -i:80 -t | head -n 1)
    SERVICE_NAME="none"
    if [ -n "$OCCUPIED_PID" ]; then
        SERVICE_NAME=$(ps -p $OCCUPIED_PID -o comm=)
        echo "⚠️ 发现 $SERVICE_NAME 占用 80 端口，正在停止..."
        systemctl stop $SERVICE_NAME || kill -9 $OCCUPIED_PID
        sleep 2
    fi
    # HTTP 签发
    ISSUE_CMD="~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server letsencrypt --listen-v4"
else
    # DNS 模式逻辑：直接签发，不检查端口
    ISSUE_CMD="~/.acme.sh/acme.sh --issue --dns dns_cf -d $DOMAIN --server letsencrypt"
fi

# 执行签发
if ! eval $ISSUE_CMD; then
    FAILURE_MSG="❌ <b>SSL 证书签发失败</b>
━━━━━━━━━━━━━━
<b>域名：</b> <code>$DOMAIN</code>
<b>原因：</b> 验证未通过。请检查 DNS 解析(HTTP模式)或 API Key(DNS模式)。"
    send_tg "$FAILURE_MSG"
    [[ "$MAIN_OPTION" -eq 1 && "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME
    exit 1
fi

# 恢复服务 (仅 HTTP 模式)
[[ "$MAIN_OPTION" -eq 1 && "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME

# 安装证书
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file /root/${DOMAIN}.key --fullchain-file /root/${DOMAIN}.crt

# --- 7. 设置全量自动续期脚本 ---
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
# 自动持久化保存 CF 密钥（如果是 DNS 模式）
export CF_Email="$CF_Email"
export CF_Key="$CF_Key"

# 1. 尝试释放 80 端口 (确保 HTTP 模式也能续期)
OCCUPIED=\$(lsof -i:80 -t | head -n 1)
if [ -n "\$OCCUPIED" ]; then
    SVC=\$(ps -p \$OCCUPIED -o comm=)
    systemctl stop \$SVC
fi

# 2. 执行续期
if acme.sh --cron --home "\$HOME/.acme.sh"; then
    RENEW_MSG="🔄 <b>SSL 证书自动续期任务完成</b>
━━━━━━━━━━━━━━
<b>执行时间：</b> \$(date '+%Y-%m-%d %H:%M:%S')
<b>状态：</b> 所有符合条件的证书已自动更新。"
    
    curl -4 -s -X POST "https://$TG_API_HOST/bot$TG_TOKEN/sendMessage" \\
        --data-urlencode "chat_id=$TG_CHATID" \\
        --data-urlencode "text=\$RENEW_MSG" \\
        -d "parse_mode=HTML"
fi

# 3. 恢复服务
[ -n "\$SVC" ] && systemctl start \$SVC
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 1 * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# --- 8. 完成推送 ---
SUCCESS_MSG="✅ <b>SSL 证书签发成功！</b>
━━━━━━━━━━━━━━
<b>域名：</b> <code>$DOMAIN</code>
<b>验证：</b> $([ "$MAIN_OPTION" -eq 1 ] && echo "HTTP (Standalone)" || echo "DNS (Cloudflare API)")
<b>证书路径：</b> <code>/root/${DOMAIN}.crt</code>
<b>签发时间：</b> $(date '+%Y-%m-%d %H:%M:%S')"

send_tg "$SUCCESS_MSG"

echo "✅ 任务完成！证书已保存在 /root 目录。"
echo "📄 证书路径: /root/${DOMAIN}.crt"
echo "🔐 私钥路径: /root/${DOMAIN}.key"
