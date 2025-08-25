#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------
# reset-passwords.sh
# - Reseta senha do Traefik (BasicAuth via htpasswd)
# - Reseta senha do Portainer (zerando o volume de dados)
# - Anota as novas credenciais em CREDENCIAIS.txt (chmod 600)
# - NÃO altera sua stack além do necessário
# ----------------------------------------------------------

require() { command -v "$1" >/dev/null 2>&1 || { echo "Falta o comando '$1'."; exit 1; }; }
require docker
require openssl

# Tenta carregar variáveis úteis do .env (se existir)
ENV_FILE=""
for f in "./.env" "/root/.env"; do
  [[ -f "$f" ]] && ENV_FILE="$f" && break
done
if [[ -n "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Valores padrão (usados se não vierem do .env)
TRAEFIK_USER="${TRAEFIK_USER:-admin}"
TRAEFIK_HOST="${TRAEFIK_HOST:-traefik.${DOMAIN_NAME:-localhost}}"
PORTAINER_HOST="${PORTAINER_HOST:-portainer.${DOMAIN_NAME:-localhost}}"

# Helpers
htpasswd_line() {
  # Gera UMA linha de htpasswd (user:hash) com bcrypt usando imagem httpd
  local user="$1" pass="$2"
  docker run --rm httpd:2.4-alpine htpasswd -nbB "$user" "$pass"
}

bcrypt_hash_only() {
  # Gera APENAS o hash (sem "user:") com apache2-utils (em Alpine)
  local pass="$1"
  docker run --rm alpine:3 sh -lc \
    'apk add --no-cache apache2-utils >/dev/null && htpasswd -nbB admin "$1" | cut -d: -f2-' -- "$pass"
}

divider() { printf '\n%s\n' "----------------------------------------------------------"; }

echo "== Reset de Senhas: Traefik + Portainer =="

# =====================================================================
# 1) TRAEFIK - sobrescreve traefik/htpasswd e reinicia somente Traefik
# =====================================================================
divider
echo "1) Traefik: gerando nova senha e atualizando htpasswd…"
TRAEFIK_NEW_PASS="$(openssl rand -hex 12)"
mkdir -p traefik
# linha no formato "user:hash"
HTPASSWD_LINE="$(htpasswd_line "$TRAEFIK_USER" "$TRAEFIK_NEW_PASS")"
printf '%s\n' "$HTPASSWD_LINE" > traefik/htpasswd
chmod 640 traefik/htpasswd
echo " - htpasswd atualizado (usuario: ${TRAEFIK_USER})"
echo " - reiniciando Traefik…"
docker compose restart traefik >/dev/null
echo " ✓ Traefik reiniciado"

# =====================================================================
# 2) PORTAINER - zera volume de dados e sobe novamente com novo hash
#     (ATENÇÃO: apaga configurações do Portainer; apenas o Portainer)
# =====================================================================
divider
echo "2) Portainer: resetando base e definindo nova senha admin…"
PORTAINER_NEW_PASS="$(openssl rand -hex 12)"
mkdir -p portainer
PORTAINER_HASH="$(bcrypt_hash_only "$PORTAINER_NEW_PASS")"
printf '%s\n' "$PORTAINER_HASH" > portainer/admin_password
chmod 600 portainer/admin_password
echo " - arquivo ./portainer/admin_password atualizado"

# Descobre volume de dados do Portainer (ex.: <projeto>_portainer_data)
PORTAINER_VOL="$(docker volume ls --format '{{.Name}}' | grep -E '_portainer_data$|^portainer_data$' | head -n1 || true)"
if [[ -z "${PORTAINER_VOL}" ]]; then
  echo " ! Volume do Portainer não encontrado automaticamente."
  echo "   Tentando subir e deixar o Docker recriar com o arquivo de senha novo…"
else
  echo " - parando/removendo container portainer…"
  docker stop portainer >/dev/null 2>&1 || true
  docker rm portainer >/dev/null 2>&1 || true
  echo " - removendo volume ${PORTAINER_VOL}… (reset)"
  docker volume rm "${PORTAINER_VOL}" >/dev/null 2>&1 || true
fi

echo " - subindo Portainer novamente…"
docker compose up -d portainer >/dev/null
echo " ✓ Portainer reiniciado (leu a nova senha admin da primeira inicialização)"

# =====================================================================
# 3) GRAVAÇÃO DAS CREDENCIAIS
# =====================================================================
divider
CRED_FILE="CREDENCIAIS.txt"
{
  echo "[${(date +%F' '%T) 2>/dev/null || date}]"
  echo "Traefik:"
  echo "  - URL : https://${TRAEFIK_HOST}"
  echo "  - user: ${TRAEFIK_USER}"
  echo "  - pass: ${TRAEFIK_NEW_PASS}"
  echo
  echo "Portainer:"
  echo "  - URL : https://${PORTAINER_HOST}"
  echo "  - user: admin"
  echo "  - pass: ${PORTAINER_NEW_PASS}"
} > "${CRED_FILE}"
chmod 600 "${CRED_FILE}"

echo "✓ Credenciais anotadas em ${CRED_FILE} (chmod 600)"

divider
echo "Feito!"
echo "Traefik   → https://${TRAEFIK_HOST}   (user: ${TRAEFIK_USER} / pass: ${TRAEFIK_NEW_PASS})"
echo "Portainer → https://${PORTAINER_HOST}   (user: admin / pass: ${PORTAINER_NEW_PASS})"
echo "Arquivo   → ${CRED_FILE}"
divider
echo "Dica: se o navegador estiver guardando cache de auth, abra em aba anônima."
