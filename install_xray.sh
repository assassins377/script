#!/usr/bin/env bash
# ==============================================================
#  install_xray.sh – один раз запускает установку Xray‑Core,
#  генерирует сертификаты (Let’s Encrypt) если есть домен, 
#  создаёт конфигурацию VLESS+Reality и стартует как systemd‑сервис.
#
#  Требования:
#    * Ubuntu 22.04 LTS
#    * root или sudo‑права
#    * доступ к интернету и открытый порт 443 (или указанный в переменной PORT)
#
#  Внимание: скрипт меняет UFW, создаёт сервис Xray, генерирует RSA‑ключи Reality,
#  а также самоподписанный сертификат (если certbot не установлен) или
#  берёт LetsEncrypt (если домен доступен).
# ==============================================================

set -euo pipefail

#########################
# ── Параметры, можно менять перед запуском ───────────────────────
#########################
DOMAIN=${1:-""}            # пример: vpn.example.com
PORT=${2:-443}
REALITY_SHORTIDS=("1234" "abcd")   # массив строк – минимум 1

#########################
# ── Вспомогательные функции ─────────────────────────────────────
#########################

log() { printf "\e[32m▶︎ %s\e[0m\n" "$*"; }

fail() { echo -e "\e[31m $*\e[0m"; exit 1; }

install_package() {
    local pkg=$1
    if ! dpkg -l | grep -q "^ii\s*$pkg\s"; then
        log "Устанавливаем пакет: $pkg"
        sudo apt-get install -y "$pkg" || fail "Не удалось установить $pkg"
    else
        log "Пакет $pkg уже установлен."
    fi
}

#########################
# ── Обновляем систему и базу пакетов ─────────────────────────────
#########################
log "Обновление системы..."
sudo apt-get update -y && sudo apt-get upgrade -y

install_package curl wget jq ufw git gnupg ca-certificates lsof

#########################
# ── Настройка UFW (порт 443, 80 при наличии домена) ─────────────────
#########################
log "Настраиваем UFW..."
sudo ufw --force delete allow 443/tcp || true
if [[ -n "$DOMAIN" ]]; then
    sudo ufw --force allow 443/tcp
    sudo ufw --force allow 80/tcp   # нужен только для certbot
else
    sudo ufw --force allow 443/tcp
fi
sudo ufw --force enable

#########################
# ── Xray‑Core (с официального репозитория) ───────────────────────
#########################
log "Устанавливаем Xray‑Core..."
install_package curl

if ! command -v xray &>/dev/null; then
    # Скрипт-установщик от XTLS
    sudo bash <(curl -s https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) --install-dir /usr/local/bin
fi

#########################
# ── Генерируем RSA‑ключи Reality ────────────────────────────────
#########################
log "Создаём RSA‑ключи для Reality..."
sudo mkdir -p /etc/xray/keys
openssl genrsa -out /etc/xray/keys/reality.key 2048
openssl rsa -in /etc/xray/keys/reality.key -pubout -out /etc/xray/keys/reality.pub

REALITY_PUB=$(cat /etc/xray/keys/reality.pub | tr -d '\n')
#########################
# ── Сертификаты TLS (самоподписанный или LetsEncrypt) ───────
#########################
if [[ -z "$DOMAIN" ]]; then
    log "Домен не задан – создаём самоподписанный сертификат..."
    sudo mkdir -p /etc/xray/cert
    openssl req -newkey rsa:2048 -nodes -days 365 \
        -x509 -subj "/CN=localhost" \
        -out /etc/xray/cert.crt \
        -keyout /etc/xray/key.key
else
    log "Пытаемся получить сертификат Let’s Encrypt для $DOMAIN..."
    install_package certbot python3-certbot-nginx
    sudo systemctl stop nginx || true     # если Nginx запущен
    certbot certonly --standalone -d "$DOMAIN" || fail "Let’s Encrypt failed"
    sudo mkdir -p /etc/xray/cert
    sudo cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"  /etc/xray/cert.crt
    sudo cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem"     /etc/xray/key.key
fi

#########################
# ── Генерируем UUID клиенту и готовим конфиг Xray ───────────────
#########################
CLIENT_UUID=$(uuidgen)

cat <<EOF | sudo tee /etc/xray/config.json >/dev/null
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },

  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$CLIENT_UUID",
            "alterId": 0,
            "email": "client@$DOMAIN"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [
            {
              "certificateFile": "/etc/xray/cert.crt",
              "keyFile": "/etc/xray/key.key"
            }
          ]
        },
        "realitySettings": {
          "publicKey": "$REALITY_PUB",
          "shortId": ${REALTITY_SHORTIDS[@]/#/"\""}${REALTITY_SHORTIDS[@]#/}\"",
          "fallbacks": [
            { "dest": "127.0.0.1:80", "xver": 0 }
          ]
        }
      }
    }
  ],

  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ],

  "dns": {"servers":["114.114.114.114","1.1.1.1"]},
  "routing": {"domainStrategy":"IPIfNonMatch","rules":[]}
}
EOF

#########################
# ── Systemd‑сервис Xray ───────────────────────────────────────
#########################
cat <<'EOS' | sudo tee /etc/systemd/system/xray.service >/dev/null
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOS

sudo systemctl daemon-reload
sudo systemctl enable --now xray.service
log "Xray запущен, статус:"
systemctl status xray.service | head -n 5

#########################
# ── Авто‑обновление Let’s Encrypt (если домен) ───────────────
#########################
if [[ -n "$DOMAIN" ]]; then
    log "Создаём cron для автообновления сертификатов..."
    cat <<'CRON' | sudo tee /etc/cron.d/xray-letsencrypt >/dev/null
0 3 * * * root certbot renew --quiet && systemctl reload xray.service
CRON
fi

#########################
# ── Финальные сообщения ───────────────────────────────────────
#########################
echo -e "\n\e[32m Установка завершена!\e[0m"
echo "———————————————————————————"
echo "UUID клиента: $CLIENT_UUID"
echo "Домен/порт: ${DOMAIN:-localhost} :$PORT"
if [[ -n "$DOMAIN" ]]; then
    echo "Сертификат: /etc/xray/cert.crt и /etc/xray/key.key (Let's Encrypt)"
else
    echo "Самоподписанный сертификат в /etc/xray/cert.*"
fi
echo "Публичный ключ Reality:"
cat /etc/xray/keys/reality.pub | fold -w 32
echo "-----------------------------------------------------------"
echo "Клиентский профиль (VLESS+Reality):"
cat <<EOF

{
  "v":"2",
  "ps":"Xray Server",
  "add":"${DOMAIN:-localhost}",
  "port":$PORT,
  "id":"$CLIENT_UUID",
  "aid":"0",
  "net":"tcp",
  "type":"none",
  "host":"",
  "path":"/",
  "tls":"tls",
  "skip-cert-verify":false,
  "alpn":["http/1.1"],
  "security":"reality",
  "reauth":"none",
  "shortid":[${REALTITY_SHORTIDS[@]/#/"\""}${REALTITY_SHORTIDS[@]#/}\""},
  "publickey":"$REALITY_PUB",
  "servername":"${DOMAIN:-localhost}",
  "flow":"",
  "udp":false
}
EOF

echo -e "\n\e[33m Инструкция по подключению:\e[0m"
echo "• В клиенте VLESS+Reality укажите:"
echo "  • Адрес: $DOMAIN (или IP) и порт $PORT"
echo "  • UUID: $CLIENT_UUID"
echo "  • ShortID: ${REALTITY_SHORTIDS[*]}"
echo "  • PublicKey: $REALITY_PUB"
echo "Готово! 🚀"
