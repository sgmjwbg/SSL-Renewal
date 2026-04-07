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
    echo "1) 申请新的 SSL 证书"
    echo "2) 重置环境 (清除记录并重新部署)"
    echo "3) 测试 Telegram 推送排版"
    echo "4) 退出脚本"
    echo "======================================================"
    read -p "请输入选项 (1-4): " MAIN_OPTION
    case $MAIN_OPTION in
        1) break ;;
        2) 
            echo "⚠️ 正在重置环境..."
            rm -rf /tmp/acme
            bash <(curl -fsSL https://raw.githubusercontent.com/sgmjwbg/SSL-Renewal/main/acme.sh)
            exit 0 ;;
        3)
            echo "🔔 正在发送中文排版测试..."
            # 使用真实换行，手机端显示效果最佳
            TEST_MSG="🧪 <b>Telegram 推送测试成功！</b>
━━━━━━━━━━━━━━
<b>测试域名：</b> <code>://example.com</code>
<b>换行功能：</b> 正常换行
<b>代码块：</b> <code>点击内容可直接复制</code>
<b>当前时间：</b> $(date '+%Y-%m-%d %H:%M:%S')"
            send_tg "$TEST_MSG"
            echo "✅ 已发送测试，请查看手机 Telegram。"
            sleep 2
            clear
            continue ;;
        4) exit 0 ;;
        *) continue ;;
    esac
done

# --- 4. 获取参数 ---
read -p "请输入要申请的域名 (例如 example.com): " DOMAIN
read -p "请输入联系电子邮件: " EMAIL

# --- 5. 安装依赖与端口检查 ---
. /etc/os-release
if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
    apt update -y && apt install -y curl socat git cron lsof
elif [[ "$ID" == "centos" ]]; then
    yum install -y curl socat git cronie lsof
    systemctl start crond && systemctl enable crond
fi

OCCUPIED_PID=$(lsof -i:80 -t | head -n 1)
SERVICE_NAME="none"
if [ -n "$OCCUPIED_PID" ]; then
    SERVICE_NAME=$(ps -p $OCCUPIED_PID -o comm=)
    echo "⚠️ 发现 $SERVICE_NAME 占用 80 端口，正在停止以释放环境..."
    systemctl stop $SERVICE_NAME || kill -9 $OCCUPIED_PID
    sleep 2
fi

# --- 6. 安装 acme.sh ---
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://acme.sh | sh -s email=$EMAIL
    export PATH="$HOME/.acme.sh:$PATH"
fi

# 注册账户与签发证书
~/.acme.sh/acme.sh --register-account -m $EMAIL --server letsencrypt

if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server letsencrypt --listen-v4; then
    FAILURE_MSG="❌ <b>SSL 证书签发失败</b>
━━━━━━━━━━━━━━
<b>域名：</b> <code>$DOMAIN</code>
<b>原因：</b> 验证未通过，请检查 DNS 解析或 80 端口。"
    send_tg "$FAILURE_MSG"
    [ -n "$SERVICE_NAME" ] && systemctl start $SERVICE_NAME
    exit 1
fi

# 恢复服务
[ -n "$SERVICE_NAME" ] && systemctl start $SERVICE_NAME

# 安装证书到 /root 目录
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file /root/${DOMAIN}.key --fullchain-file /root/${DOMAIN}.crt

# --- 7. 设置全量自动续期脚本 (支持多域名汇总通知) ---
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
# 1. 自动处理 80 端口冲突
OCCUPIED=\$(lsof -i:80 -t | head -n 1)
if [ -n "\$OCCUPIED" ]; then
    SVC=\$(ps -p \$OCCUPIED -o comm=)
    systemctl stop \$SVC
fi

# 2. 执行全量续期任务
if acme.sh --cron --home "\$HOME/.acme.sh"; then
    RENEW_MSG="🔄 <b>SSL 证书自动续期任务完成</b>
━━━━━━━━━━━━━━
<b>执行时间：</b> \$(date '+%Y-%m-%d %H:%M:%S')
<b>状态：</b> 符合条件的证书已全部更新。"
    
    curl -4 -s -X POST "https://$TG_API_HOST/bot$TG_TOKEN/sendMessage" \\
        --data-urlencode "chat_id=$TG_CHATID" \\
        --data-urlencode "text=\$RENEW_MSG" \\
        -d "parse_mode=HTML"
fi

# 3. 恢复服务启动
[ -n "\$SVC" ] && systemctl start \$SVC
EOF
chmod +x /root/renew_cert.sh

# 设置每月 1 号执行全量续期检查
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 1 * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# --- 8. 完成推送 (中文排版) ---
SUCCESS_MSG="✅ <b>SSL 证书签发成功！</b>
━━━━━━━━━━━━━━
<b>域名：</b> <code>$DOMAIN</code>
<b>有效期：</b> 90天 (已设每月 1 号自动续期)
<b>证书位置：</b> <code>/root/${DOMAIN}.crt</code>
<b>私钥位置：</b> <code>/root/${DOMAIN}.key</code>
<b>签发时间：</b> $(date '+%Y-%m-%d %H:%M:%S')"

send_tg "$SUCCESS_MSG"

echo "✅ 任务完成！证书已保存在 /root 目录。"
echo "📄 证书路径: /root/${DOMAIN}.crt"
echo "🔐 私钥路径: /root/${DOMAIN}.key"
