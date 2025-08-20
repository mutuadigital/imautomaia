#!/usr/bin/env bash
# Hostinger Quick Installer — Evolution API + .env wizard + Healthcheck generator
# Uso: bash install-hostinger-override.sh
# Ambiente: VPS Hostinger com docker-compose.yml padrão (Traefik + n8n + Redis + Postgres)

set -euo pipefail

banner() {
  echo "============================================================"
  echo " Hostinger Quick Installer — Evolution API + .env Wizard"
  echo "============================================================"
  echo
}

err() { echo "❌ $*" >&2; }
pause() { read -r -p "Pressione ENTER para continuar..." _; }

# Busca diretório com docker-compose.yml
find_compose_dir() {
  local candidates=("$PWD" "/root" "/home/");
  for d in "${candidates[@]}"; do
    if [ -f "$d/docker-compose.yml" ]; then
      echo "$d"; return 0;
    fi
  done
  return 1;
}

ensure_env() {
  local key="$1"; local val="$2"; local file="$3";
  touch "$file";
  if grep -qE "^${key}=" "$file"; then
    sed -i -E "s|^(${key}=).*|
  else
    echo "${key}=${val}" >> "$file";
  fi;
}

ask() {
  local prompt="$1"; local def="${2:-}"; local ans;
  # Se stdin for um terminal usamos read normalmente; se não for, lemos de /dev/tty (se existir)
  if [ -n "$def" ]; then
    if [ -t 0 ]; then
      read -r -p "$prompt [$def]: " ans || true;
    else
      if [ -r /dev/tty ]; then
        read -r -p "$prompt [$def]: " ans < /dev/tty || true;
      else
        ans="";
      fi;
    fi;
    ans="${ans:-$def}";
  else
    if [ -t 0 ]; then
      read -r -p "$prompt: " ans || true;
    else
      if [ -r /dev/tty ]; then
        read -r -p "$prompt: " ans < /dev/tty || true;
      else
        ans="";
      fi;
    fi;
  fi;
  echo "$ans";
}

health_summary() {
  echo
  echo "=== Testes rápidos ==="
  local DOMAIN_NAME="$(grep -E '^DOMAIN_NAME=' "$ENV_FILE" | cut -d= -f2- || true)";
  local SUBDOMAIN="$(grep -E '^SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)";
  local EVO_SUBDOMAIN="$(grep -E '^EVO_SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)";
  [ -n "${SUBDOMAIN:-}" ] && echo " - n8n:       https://${SUBDOMAIN}.${DOMAIN_NAME}";
  [ -n "${EVO_SUBDOMAIN:-}" ] && echo " - Evolution: https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}";
  echo
  echo "Comandos úteis:";
  echo " - Logs Traefik:      docker logs traefik --tail=200";
  echo " - Logs n8n:          docker logs n8n --tail=200 || docker logs root-n8n-1 --tail=200";
  echo " - Logs Evolution:    docker logs evolution-api --tail=200";
  echo " - Recriar Evolution: docker compose up -d --no-deps --force-recreate evolution";
  echo
  echo "Rodar healthcheck: ./hostinger-healthcheck.sh";
}

banner

# 1) Detectar pasta do compose
COMPOSE_DIR="${BASE_DIR:-}";
if [ -z "${COMPOSE_DIR}" ]; then
  if ! COMPOSE_DIR="$(find_compose_dir)"; then
    err "Não encontrei docker-compose.yml. Coloque este script na mesma pasta do compose ou exporte BASE_DIR=/caminho e rode novamente.";
    exit 1;
  fi;
fi;
cd "$COMPOSE_DIR";
echo "📁 Diretório do compose: $COMPOSE_DIR";
echo

command -v docker >/dev/null 2>&1 || { err "Docker não encontrado."; exit 1; };
docker compose version >/dev/null 2>&1 || { err "Docker Compose plugin não encontrado (docker compose)."; exit 1; };

# 2) Wizard do .env
ENV_FILE="$COMPOSE_DIR/.env";
touch "$ENV_FILE";

CUR_DOMAIN="$(grep -E '^DOMAIN_NAME=' "$ENV_FILE" | cut -d= -f2- || true)";
CUR_SUB="$(grep -E '^SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)";
CUR_TZ="$(grep -E '^GENERIC_TIMEZONE=' "$ENV_FILE" | cut -d= -f2- || true)";
CUR_SSL_EMAIL="$(grep -E '^SSL_EMAIL=' "$ENV_FILE" | cut -d= -f2- || true)";
CUR_EVO_SUB="$(grep -E '^EVO_SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)";
CUR_EVO_KEY="$(grep -E '^EVOLUTION_API_KEY=' "$ENV_FILE" | cut -d= -f2- || true)";

DEFAULT_TZ="${CUR_TZ:-America/Sao_Paulo}";
DEFAULT_SUB="${CUR_SUB:-n8n}";
DEFAULT_EVO_SUB="${CUR_EVO_SUB:-wa}";

echo "== Preenchendo variáveis do .env ==";
DOMAIN_NAME="$(ask 'Domínio principal (DOMAIN_NAME) ex.: imautomaia.com.br' "${CUR_DOMAIN:-}")";
SUBDOMAIN="$(ask 'Subdomínio do n8n (SUBDOMAIN) ex.: n8n' "${DEFAULT_SUB}")";
GENERIC_TIMEZONE="$(ask 'Timezone (GENERIC_TIMEZONE) ex.: America/Sao_Paulo' "${DEFAULT_TZ}")";
SSL_EMAIL="$(ask 'E-mail para certificados (SSL_EMAIL)' "${CUR_SSL_EMAIL:-}")";
EVO_SUBDOMAIN="$(ask 'Subdomínio da Evolution API (EVO_SUBDOMAIN) ex.: wa' "${DEFAULT_EVO_SUB}")";

if [ -z "${CUR_EVO_KEY:-}" ]; then
  if command -v openssl >/dev/null 2>&1; then
    EVOLUTION_API_KEY="$(openssl rand -hex 16)";
  else
    EVOLUTION_API_KEY="change-me-
  fi;
else
  EVOLUTION_API_KEY="${CUR_EVO_KEY}";
fi;

ensure_env "DOMAIN_NAME" "$DOMAIN_NAME" "$ENV_FILE";
ensure_env "SUBDOMAIN" "$SUBDOMAIN" "$ENV_FILE";
ensure_env "GENERIC_TIMEZONE" "$GENERIC_TIMEZONE" "$ENV_FILE";
ensure_env "SSL_EMAIL" "$SSL_EMAIL" "$ENV_FILE";
ensure_env "EVO_SUBDOMAIN" "$EVO_SUBDOMAIN" "$ENV_FILE";
ensure_env "EVOLUTION_API_KEY" "$EVOLUTION_API_KEY" "$ENV_FILE";

echo "✅ .env atualizado em: $ENV_FILE";
echo;
echo "Resumo .env:";
grep -E '^(DOMAIN_NAME|SUBDOMAIN|GENERIC_TIMEZONE|SSL_EMAIL|EVO_SUBDOMAIN|EVOLUTION_API_KEY)=' "$ENV_FILE" | sed -E 's/(EVOLUTION_API_KEY=).+/

# 3) docker-compose.override.yml (Evolution API)
OVERRIDE_FILE="$COMPOSE_DIR/docker-compose.override.yml";
if [ -f "$OVERRIDE_FILE" ]; then
  cp -f "$OVERRIDE_FILE" "$OVERRIDE_FILE.bak.$(date +%Y%m%d%H%M%S)";
  echo "ℹ️  Backup criado: $OVERRIDE_FILE.bak.$(date +%Y%m%d%H%M%S)";
fi;

cat > "$OVERRIDE_FILE" <<'YAML'
version: "3.7"
services:
  evolution:
    image: atendai/evolution-api:latest
    container_name: evolution-api
    restart: always
    environment:
      AUTHENTICATION_API_KEY: ${EVOLUTION_API_KEY}
    volumes:
      - evolution_store:/evolution/store
      - evolution_instances:/evolution/instances
    labels:
      - traefik.enable=true
      - traefik.http.routers.evolution.rule=Host(`${EVO_SUBDOMAIN}.${DOMAIN_NAME}`)
      - traefik.http.routers.evolution.entrypoints=web,websecure
      - traefik.http.routers.evolution.tls=true
      - traefik.http.routers.evolution.tls.certresolver=mytlschallenge
      - traefik.http.services.evolution.loadbalancer.server.port=8080

volumes:
  evolution_store:
  evolution_instances:
YAML

echo "✅ docker-compose.override.yml criado/atualizado.";
echo;

# 4) Subir/atualizar serviços
echo "Baixando/atualizando imagem da Evolution...";
docker compose pull evolution || true;

echo "Subindo Evolution (e garantindo n8n up)...";
docker compose up -d evolution;
docker compose up -d n8n || true;
echo;
echo "Aguardando serviços ficarem prontos (certificado pode levar ~1-2 min)...";
sleep 5;

# 5) Testes básicos
echo "=== Verificando Traefik/n8n/Evolution ===";
if curl -sSf -m 5 http://localhost:80 >/dev/null ; then
  echo "✅ Traefik porta 80 OK (local)";
else
  echo "❌ Traefik porta 80 falhou. Dicas:";
  echo "   docker logs traefik --tail=200";
fi;

if curl -sSf -m 5 "https://${SUBDOMAIN}.${DOMAIN_NAME}/rest/healthz" >/dev/null ; then
  echo "✅ n8n healthz OK: https://${SUBDOMAIN}.${DOMAIN_NAME}/rest/healthz";
else
  echo "❌ n8n falhou em https://${SUBDOMAIN}.${DOMAIN_NAME}/rest/healthz";
  echo "   docker logs n8n --tail=200 || docker logs root-n8n-1 --tail=200";
fi;

if curl -sSf -m 5 "https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/" >/dev/null ; then
  echo "✅ Evolution acessível: https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/";
else
  echo "❌ Evolution não respondeu em https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/";
  echo "   docker logs evolution-api --tail=200";
  echo "   docker compose up -d --no-deps --force-recreate evolution";
fi;

# 6) Criar hostinger-healthcheck.sh
HEALTH_FILE="$COMPOSE_DIR/hostinger-healthcheck.sh";
cat > "$HEALTH_FILE" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="${BASE_DIR:-$PWD}"
ENV_FILE="$BASE_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "❌ .env não encontrado em $BASE_DIR"; exit 1;
fi;
DOMAIN_NAME="$(grep -E '^DOMAIN_NAME=' "$ENV_FILE" | cut -d= -f2-)";
SUBDOMAIN="$(grep -E '^SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2-)";
EVO_SUBDOMAIN="$(grep -E '^EVO_SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- )";

echo "=== Healthcheck Hostinger Stack ===";
echo "n8n:       https://${SUBDOMAIN}.${DOMAIN_NAME}/rest/healthz";
echo "evolution: https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/";
echo;

check() {
  local name="$1"; local url="$2";
  if curl -sSf -m 6 "$url" >/dev/null; then
    echo "✅ $name OK";
  else
    echo "❌ $name FAIL → $url";
    echo "   Logs: docker logs $name --tail=200 || true";
    echo "   Restart: docker restart $name || true";
    echo "   Recreate: docker compose up -d --no-deps --force-recreate $name || true";
    echo;
  fi;
}

if curl -sSf -m 5 http://localhost:80 >/dev/null ; then
  echo "✅ Traefik (porta 80) OK";
else
  echo "❌ Traefik (porta 80) FAIL";
  echo "   docker logs traefik --tail=200";
fi;

check "n8n" "https://${SUBDOMAIN}.${DOMAIN_NAME}/rest/healthz";
check "evolution-api" "https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/";
echo "=== Done ===";
EOS
chmod +x "$HEALTH_FILE";
echo "✅ Criado script de healthcheck: $HEALTH_FILE";

health_summary;
echo "Concluído. 🚀";