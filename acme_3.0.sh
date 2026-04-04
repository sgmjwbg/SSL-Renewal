#!/bin/bash
set -e

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
        sudo apt install -y curl socat git cron
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
        sudo yum install -y curl socat git cronie
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
    echo "❌ 证书申请失败，正在清理。"
    rm -f /root/${DOMAIN}.key /root/${DOMAIN}.crt
    ~/.acme.sh/acme.sh --remove -d $DOMAIN
    rm -rf ~/.acme.sh/${DOMAIN}
    exit 1
fi

# 安装证书
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# 自动续期脚本
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
acme.sh --renew -d $DOMAIN --server $CA_SERVER
EOF
chmod +x /root/renew_cert.sh
(crontab -l 2>/dev/null; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -

# 完成提示
echo "✅ SSL证书申请完成！"
echo "📄 证书路径: /root/${DOMAIN}.crt"
echo "🔐 私钥路径: /root/${DOMAIN}.key"
