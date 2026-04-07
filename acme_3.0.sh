#!/bin/bash
set -e

# --- 1. 内置 TG 配置 ---
TG_TOKEN="2103490652:AAHr_Z3LKZIX-3fv4gvP28HnfldADjrp9os"
TG_CHATID="7015616862"

# 推送函数 (内置置顶)
send_tg() {
    local msg=$1
    curl -s -X POST "https://telegram.org" \
        --data-urlencode "chat_id=$TG_CHATID" \
        --data-urlencode "text=$msg" \
        -d "parse_mode=HTML" > /dev/null
}

# 主菜单
while true; do
    clear
    echo "============== SSL证书管理菜单TG =============="
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

# 启动推送
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

# 安装依赖项，配置防火墙
case $OS in
    ubuntu|debian)
        sudo apt update -y
        sudo apt upgrade -y
        sudo apt install -y curl socat git cron lsof
        if [ "$FIREWALL_OPTION" -eq 1 ]; then
            if command -v ufw >/dev/null 2>&1; then
                sudo ufw disable
            else
                echo "⚠️ UFW 未安装，跳过关闭防火墙。"
            fi
        elif [ "$PORT_OPTION" -eq 1 ]; then
            if command -v ufw >/dev/null 2>&1; then
                sudo ufw allow $PORT
            else
                echo "⚠️ UFW 未安装，跳过端口放行。"
            fi
        fi
        ;;
    centos)
        sudo yum update -y
        sudo yum install -y curl socat git cronie lsof
        sudo systemctl start crond
        sudo systemctl enable crond
        if [ "$FIREWALL_OPTION" -eq 1 ]; then
            sudo systemctl stop firewalld
            sudo systemctl disable firewalld
        elif [ "$PORT_OPTION" -eq 1 ]; then
            sudo firewall-cmd --permanent --add-port=${PORT}/tcp
            sudo firewall-cmd --reload
        fi
        ;;
    *)
        echo "❌ 不支持的操作系统：$OS"
        exit 1
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

# 安装 acme.sh（如未装）
if ! command -v acme.sh >/dev/null 2>&1; then
    curl https://get.acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
    ~/.acme.sh/acme.sh --upgrade
fi

# 注册账户
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

# 申请证书
if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER; then
    send_tg "❌ <b>SSL 签发失败</b>%0A域名：$DOMAIN"
    echo "❌ 证书申请失败，正在清理。"
    [[ "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME
    rm -f /root/${DOMAIN}.key /root/${DOMAIN}.crt
    ~/.acme.sh/acme.sh --remove -d $DOMAIN
    rm -rf ~/.acme.sh/${DOMAIN}
    exit 1
fi

# 恢复之前停止的服务
[[ "$SERVICE_NAME" != "none" ]] && systemctl start $SERVICE_NAME

# 安装证书
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# 自动续期脚本 (注入停启服务和推送逻辑)
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
# 续期前停用服务
OCCUPIED=\$(lsof -i:80 -t | head -n 1)
if [ -n "\$OCCUPIED" ]; then
    SVC=\$(ps -p \$OCCUPIED -o comm=)
    systemctl stop \$SVC
    if acme.sh --renew -d $DOMAIN --server $CA_SERVER; then
        curl -s -X POST "https://telegram.org" \
            -d "chat_id=$TG_CHATID" -d "parse_mode=HTML" \
            -d "text=🔄 <b>SSL 证书续期成功</b>%0A域名：$DOMAIN"
    fi
    systemctl start \$SVC
fi
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# 完成提示
send_tg "✅ <b>SSL 签发成功！</b>%0A━━━━━━━━━━━━━━%0A<b>域名：</b> <code>$DOMAIN</code>"
echo "✅ SSL证书申请完成！"
echo "📄 证书路径: /root/${DOMAIN}.crt"
echo "🔐 私钥路径: /root/${DOMAIN}.key"
