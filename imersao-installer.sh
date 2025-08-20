#!/usr/bin/env bash
# Hostinger Quick Installer v3 — Evolution API + Portainer + Traefik dashboard
# Uso: bash imersao-installer-v3.sh
# Requisitos: VPS Hostinger com docker-compose.yml padrão (Traefik + n8n/Redis/Postgres)

set -euo pipefail

banner() {
  printf '%s\n' "============================================================"
  printf '%s\n' " Hostinger Quick Installer — Evolution + Portainer + Traefik"
  printf '%s\n\n' "============================================================"
}

err() { printf '❌ %s\n' "$*" >&2; }

ask() {
  # ask "Pergunta" "default"
  local prompt="$1"; local def="${2:-}"; local ans=""
  if [ -t 0 ]; then
    if [ -n "$def" ]; then
      read -r -p "$prompt [$def]: " ans || true
      ans="${ans:-$def}"
    else
      read -r -p "$prompt: " ans || true
    fi
  else
    ans="$def"
  fi
  printf '%s\n' "$ans"
}

yesno() {
  # yesno "Pergunta" "y|n"
  local prompt="$1"; local def="${2:-y}"; local ans=""
  local defShow; defShow="$(printf '%s' "$def" | tr yYnN Yy)"
  if [ -t 0 ]; then
    read -r -p "$prompt [$defShow]: " ans || true
    ans="${ans:-$def}"
  else
    ans="$def"
  fi
  case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

find_compose_dir() {
  if [ -n "${BASE_DIR:-}" ] && [ -f "${BASE_DIR}/docker-compose.yml" ]; then
    printf '%s\n' "$BASE_DIR"; return 0
  fi
  for d in "$PWD" "/root" "/home/$(whoami)" "/opt" "/srv"; do
    if [ -f "$d/docker-compose.yml" ]; then
      printf '%s\n' "$d"; return 0
    fi
  done
  return 1
}

ensure_env() {
  # ensure_env KEY VALUE FILE
  local key="$1"; local val="$2"; local file="$3"
  touch "$file"
  if grep -qE "^${key}=" "$file"; then
    sed -i -E "s|^(${key}=).*|\1${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

health_summary() {
  echo
  echo "=== Endpoints esperados ==="
  local DOMAIN_NAME SUBDOMAIN EVO_SUBDOMAIN P_HOST T_HOST
  DOMAIN_NAME="$(grep -E '^DOMAIN_NAME=' "$ENV_FILE" | cut -d= -f2- || true)"
  SUBDOMAIN="$(grep -E '^SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)"
  EVO_SUBDOMAIN="$(grep -E '^EVO_SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)"
  P_HOST="$(grep -E '^PORTAINER_HOST=' "$ENV_FILE" | cut -d= -f2- || true)"
  T_HOST="$(grep -E '^TRAEFIK_HOST=' "$ENV_FILE" | cut -d= -f2- || true)"

  [ -n "$SUBDOMAIN" ]     && echo " - n8n:       https://${SUBDOMAIN}.${DOMAIN_NAME}"
  [ -n "$EVO_SUBDOMAIN" ] && echo " - Evolution: https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}"
  [ -n "$P_HOST" ]        && echo " - Portainer: https://${P_HOST}"
  [ -n "$T_HOST" ]        && echo " - Traefik:   https://${T_HOST}"
  echo
  echo "Comandos úteis:"
  echo " - Logs Traefik:      docker logs traefik --tail=200"
  echo " - Logs n8n:          docker logs n8n --tail=200 || docker logs root-n8n-1 --tail=200"
  echo " - Logs Evolution:    docker logs evolution-api --tail=200"
  echo " - Logs Portainer:    docker logs portainer --tail=200"
  echo " - Recriar serviço:   docker compose up -d --no-deps --force-recreate <servico>"
  echo
  echo "Healthcheck: ./hostinger-healthcheck.sh"
}

### INÍCIO
banner

# 0) Pré-checagens
command -v docker >/dev/null 2>&1 || { err "Docker não encontrado."; exit 1; }
docker compose version >/dev/null 2>&1 || { err "Docker Compose plugin não encontrado (docker compose)."; exit 1; }

# 1) Encontrar diretório do compose
COMPOSE_DIR="${BASE_DIR:-}"
if [ -z "$COMPOSE_DIR" ]; then
  if ! COMPOSE_DIR="$(find_compose_dir)"; then
    err "Não encontrei docker-compose.yml. Coloque este script na mesma pasta do compose ou exporte BASE_DIR=/caminho e rode novamente."
    exit 1
  fi
fi
cd "$COMPOSE_DIR"
echo "📁 Diretório do compose: $COMPOSE_DIR"
echo

# 2) Wizard de variáveis (.env)
ENV_FILE="$COMPOSE_DIR/.env"
touch "$ENV_FILE"

CUR_DOMAIN="$(grep -E '^DOMAIN_NAME=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_SUB="$(grep -E '^SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_TZ="$(grep -E '^GENERIC_TIMEZONE=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_SSL_EMAIL="$(grep -E '^SSL_EMAIL=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_EVO_SUB="$(grep -E '^EVO_SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_EVO_KEY="$(grep -E '^EVOLUTION_API_KEY=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_P_HOST="$(grep -E '^PORTAINER_HOST=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_T_HOST="$(grep -E '^TRAEFIK_HOST=' "$ENV_FILE" | cut -d= -f2- || true)"

DEFAULT_TZ="${CUR_TZ:-America/Sao_Paulo}"
DEFAULT_SUB="${CUR_SUB:-n8n}"
DEFAULT_EVO_SUB="${CUR_EVO_SUB:-wa}"
DEFAULT_P_HOST="${CUR_P_HOST:-portainer.${CUR_DOMAIN:-SEU_DOMINIO}}"
DEFAULT_T_HOST="${CUR_T_HOST:-traefik.${CUR_DOMAIN:-SEU_DOMINIO}}"

echo "== Configuração dos domínios e chaves =="
DOMAIN_NAME="$(ask 'Domínio raiz (ex.: imautomaia.com.br)' "${CUR_DOMAIN:-}")"
SUBDOMAIN="$(ask 'Subdom
