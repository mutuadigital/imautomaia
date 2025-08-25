#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------
# reset-passwords.sh
# - Reseta senha do Traefik (BasicAuth via htpasswd/bcrypt)
# - Reseta senha do Portainer (admin) usando --admin-password-file
#   *agora em TEXTO PURO, SEM newline*
# - Remove todos os volumes portainer_data pra garantir 1º boot
# - Anota tudo em CREDENCIAIS.txt (chmod 600)
# - NÃO dá 'source' no .env (evita bug com $2y$ do bcrypt)
# ----------------------------------------------------------

require() { command -v "$1" >/dev/null 2>&1 || { echo "Falta o comando '$1'."; exit 1; }; }
require docker
require openssl

# Lê um valor do .env (se existir) sem executar nada
get_env() {
  local key="$1" def="${2:-}" file="" val=""
  for f in "./.env" "/root/.env"; do [[ -f "$f" ]] && file="$f" && break; done
  [[ -z "$file" ]] && { echo "$def"; return 0; }
  val="$(awk -v k="$key" -F'=' '
    $1==k {
      $1="";
      sub(/^=/,"");
      gsub(/\r/,"");
      sub(/^[ \t]+/,"");
      sub(/[ \t]+$/,"");
      print; exit
    }' "$file" 2>/dev/null || true)"
  [[ -n "$val" ]] && echo "$val" || echo "$def"
}

# Garante que uma KEY exista no .env (se não existir, adiciona)
ensure_env_key() {
  local key="$1" val="$2" file=""
  for f in "./.env" "/root/.env"; do [[ -f "$f" ]] && file="$f" && break; done
  [[ -z "$file" ]] && return 0
  grep -qE "^${key}=" "$file" || printf '%s=%s\n' "$key" "$val" >> "$file"
}

DOMAIN_NAME="$(get_env DOMAIN_NAME "")"
TRAEFIK_HOST="$(get_env TRAEFIK_HOST "traefik.${DOMAIN_NAME:-localhost}")"
PORTAINER_HOST="$(get_env PORTAINER_HOST "portainer.${DOMAIN_NAME:-localhost}")"
TRAEFIK_USER="$(get_env TRAEFIK_USER "admin")"
[[ -z "$TRAEFIK_USER" ]] && TRAEFIK_USER="admin"
ensure_env_key "TRAEFIK_USER" "$TRAEFIK_USER"

# Helpers de hash
htpasswd_line() { docker run --rm httpd:2.4-alpine htpasswd -nbB "$1" "$2"; }

divider() { printf '\n%s\n' "----------------------------------------------------------"; }

echo "== Reset de Senhas: Traefik + Portainer =="

# =====================================================================
# 1) TRAEFIK - sobrescreve traefik/htpasswd e reinicia somente Traefik
# =====================================================================
divider
echo "1) Traefik: gerando nova senha e atualizando htpasswd…"
TRAEFIK_NEW_PASS="$(openssl rand -hex 12)"
mkdir -p traefik
printf '%s\n' "$(htpasswd_line "$TRAEFIK_USER" "$TRAEFIK_NEW_PASS")" > traefik/htpasswd
chmod 640 traefik/htpasswd
docker compose restart traefik >/dev/null || true
echo " ✓ Traefik reiniciado (user: ${TRAEFIK_USER})"

# =====================================================================
# 2) PORTAINER - 1º boot limpo + senha em TEXTO no admin_password
#     (ATENÇÃO: apaga configurações do Portainer; apenas o Portainer)
# =====================================================================
divider
echo "2) Portainer: resetando base e definindo nova senha admin (plaintext)…"
PORTAINER_NEW_PASS="$(openssl rand -hex 12)"
mkdir -p portainer
# >>> grava SENHA EM TEXTO, SEM newline <<<
printf %s "${PORTAINER_NEW_PASS}" > portainer/admin_password
chmod 600 portainer/admin_password
echo " - arquivo ./portainer/admin_password atualizado (plaintext)"

echo " - parando/removendo container portainer…"
docker stop portainer >/dev/null 2>&1 || true
docker rm portainer   >/dev/null 2>&1 || true

echo " - removendo TODOS os volumes portainer_data…"
for v in $(docker volume ls --format '{{.Name}}' | grep -E '(^|_)portainer_data$' || true); do
  docker volume rm -f "$v" >/dev/null 2>&1 || true
done

echo " - subindo Portainer novamente…"
docker compose up -d portainer >/dev/null

# Validação rápida de leitura do secret (opcional, mas útil)
echo " - checando leitura do secret (plaintext)…"
docker run --rm -v "$PWD/portainer/admin_password:/run/secrets/admin:ro" alpine:3 \
  sh -lc 'test -s /run/secrets/admin && { printf "   conteúdo (primeiros 6 chars): "; head -c6 /run/secrets/admin; echo; } || { echo "   ERRO: secret vazio/inlegível"; exit 1; }'

sleep 3
docker logs --since 10s portainer || true

# =====================================================================
# 3) GRAVAÇÃO DAS CREDENCIAIS
# =====================================================================
divider
CRED_FILE="CREDENCIAIS.txt"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
{
  echo "[$NOW]"
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
echo "Se o navegador recusar, teste primeiro a API:"
echo "  curl -sS -H 'Content-Type: application/json' --data '{\"username\":\"admin\",\"password\":\"${PORTAINER_NEW_PASS}\"}' https://${PORTAINER_HOST}/api/auth"
echo "e tente em aba anônima (cookies antigos podem atrapalhar)."
