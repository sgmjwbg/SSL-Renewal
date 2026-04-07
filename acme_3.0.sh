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
echo "============== SSL 证书管理 (TG内置推送版) =============="
# 立即测试推送
send_tg_notification "🔔 <b>SSL 脚本已启动</b>%0A━━━━━━━━━━━━━━%0A服务器已成功连接 TG 接口！%0A正在准备申请流程..."


# 主菜单
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
            echo "📦 正在重新执行 acme.sh ..."
            sleep 1
            # 强制修复一次 DNS 确保下载成功
            echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
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

# 用户输入参数
read -p "请输入域名: " DOMAIN
read -p "请输入电子邮件地址: " EMAIL

# 测试推送
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

# 检查系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ 无法识别操作系统，请手动安装依赖。"
    exit 1
fi

# 安装依赖项
case $OS in
    ubuntu|debian)
        sudo apt update -y
        sudo apt install -y curl socat git cron lsof
        if [ "$FIREWALL_OPTION" -eq 1 ]; then
            command -v ufw >/dev/null 2>&1 && sudo ufw disable || echo "⚠️ 跳过关闭防火墙"
        elif [ "$PORT_OPTION" -eq 1 ]; then
            command -v ufw >/dev/null 2>&1 && sudo ufw allow $PORT || echo "⚠️ 跳过端口放行"
        fi
        ;;
    centos)
        sudo yum update -y
        sudo yum install -y curl socat git cronie lsof
        sudo systemctl start crond && sudo systemctl enable crond
        if [ "$FIREWALL_OPTION" -eq 1 ]; then
            sudo systemctl stop firewalld && sudo systemctl disable firewalld
        elif [ "$PORT_OPTION" -eq 1 ]; then
            sudo firewall-cmd --permanent --add-port=${PORT}/tcp && sudo firewall-cmd --reload
        fi
        ;;
esac

# --- 自动处理 80 端口占用 ---
OCCUPIED_PID=$(lsof -i:80 -t | head -n 1)
SERVICE_NAME="none"
if [ -n "$OCCUPIED_PID" ]; then
    SERVICE_NAME=$(ps -p $OCCUPIED_PID -o comm=)
    echo "⚠️ 发现 $SERVICE_NAME 占用 80 端口，正在停止..."
    systemctl stop $SERVICE_NAME || kill -9 $OCCUPIED_PID
    sleep 2
fi

# 安装 acme.sh
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://get.acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
fi

# 注册账户
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

# 申请证书
if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER --listen-v4; then
    send_tg "❌ <b>SSL 申请失败</b>%0A域名：$DOMAIN"
    echo "❌ 证书申请失败，正在清理。"
    [[ "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME
    rm -f /root/${DOMAIN}.key /root/${DOMAIN}.crt
    ~/.acme.sh/acme.sh --remove -d $DOMAIN
    rm -rf ~/.acme.sh/${DOMAIN}
    exit 1
fi

# 恢复服务
[[ "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME

# 安装证书
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# 自动续期脚本 (增加服务停启逻辑)
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
# 续期前停用占用 80 端口的服务
SVC=\$(lsof -i:80 -t | xargs ps -p | tail -n 1 | awk '{print \$4}')
[ -n "\$SVC" ] && systemctl stop \$SVC
if acme.sh --renew -d $DOMAIN --server $CA_SERVER --listen-v4; then
    curl -s -X POST "https://telegram.org" \
        -d "chat_id=$TG_CHATID" -d "parse_mode=HTML" \
        -d "text=🔄 <b>SSL 证书续期成功</b>%0A域名：$DOMAIN"
fi
[ -n "\$SVC" ] && systemctl start \$SVC
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# 完成提示
send_tg "✅ <b>SSL 签发成功！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> $DOMAIN%0A<b>位置：</b> /root/${DOMAIN}.crt"
echo "✅ SSL证书申请完成！"
echo "📄 证书路径: /root/${DOMAIN}.crt"
echo "🔐 私钥路径: /root/${DOMAIN}.key"
