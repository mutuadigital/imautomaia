#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------
# Chatwoot Add-on Installer (one-command)
# - Não altera serviços existentes
# - Usa Postgres/Redis do stack principal
# - Gera docker-compose.chatwoot.yml separado
# - Instala chat-check (healthcheck)
# --------------------------------------------

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

ROOT="/root"
MAIN_COMPOSE="$ROOT/docker-compose.yml"

# Carrega variáveis principais se existirem
ENV_MAIN=""
for f in "$here/.env" "$ROOT/.env"; do
  [[ -f "$f" ]] && ENV_MAIN="$f" && break
done
[[ -n "$ENV_MAIN" ]] && source "$ENV_MAIN" || true

# Defaults
DOMAIN_NAME_DEFAULT="${DOMAIN_NAME:-srv.example.tld}"
CHAT_SUB_DEFAULT="chat"
TZ_DEFAULT="${GENERIC_TIMEZONE:-America/Sao_Paulo}"

PG_USER_DEFAULT="${N8N_DB_USER:-n8n}"
PG_PASS_DEFAULT="${N8N_DB_PASS:-changeme}"
PG_DB_DEFAULT="chatwoot_production"
PG_HOST_DEFAULT="postgres"
PG_PORT_DEFAULT="5432"
REDIS_URL_DEFAULT="redis://redis:6379"

# Perguntas
echo "=== Chatwoot - Configuração Rápida ==="
read -rp "Domínio raiz (ex.: imautomaia.com.br) [${DOMAIN_NAME_DEFAULT}]: " DOMAIN_NAME
DOMAIN_NAME="${DOMAIN_NAME:-$DOMAIN_NAME_DEFAULT}"

read -rp "Subdomínio do Chatwoot (ex.: chat) [${CHAT_SUB_DEFAULT}]: " CHAT_SUB
CHAT_SUB="${CHAT_SUB:-$CHAT_SUB_DEFAULT}"

read -rp "Timezone (ex.: America/Sao_Paulo) [${TZ_DEFAULT}]: " TZ
TZ="${TZ:-$TZ_DEFAULT}"

echo
echo "=== Banco de Dados (reutilizando Postgres existente) ==="
read -rp "Postgres HOST [${PG_HOST_DEFAULT}]: " PG_HOST
PG_HOST="${PG_HOST:-$PG_HOST_DEFAULT}"
read -rp "Postgres PORT [${PG_PORT_DEFAULT}]: " PG_PORT
PG_PORT="${PG_PORT:-$PG_PORT_DEFAULT}"
read -rp "Postgres USER [${PG_USER_DEFAULT}]: " PG_USER
PG_USER="${PG_USER:-$PG_USER_DEFAULT}"
read -rp "Postgres PASS [${PG_PASS_DEFAULT}]: " PG_PASS
PG_PASS="${PG_PASS:-$PG_PASS_DEFAULT}"
read -rp "Postgres DB (novo p/ Chatwoot) [${PG_DB_DEFAULT}]: " PG_DB
PG_DB="${PG_DB:-$PG_DB_DEFAULT}"

echo
echo "=== Redis (reutilizando Redis existente) ==="
read -rp "REDIS_URL [${REDIS_URL_DEFAULT}]: " REDIS_URL
REDIS_URL="${REDIS_URL:-$REDIS_URL_DEFAULT}"

echo
echo "=== Aplicação ==="
read -rp "Nome da instalação (ex.: IMAUTOMAIA Chat) [Chatwoot]: " INSTALLATION_NAME
INSTALLATION_NAME="${INSTALLATION_NAME:-Chatwoot}"
read -rp "Locale padrão (ex.: pt_BR, en) [pt_BR]: " DEFAULT_LOCALE
DEFAULT_LOCALE="${DEFAULT_LOCALE:-pt_BR}"

FRONTEND_URL="https://${CHAT_SUB}.${DOMAIN_NAME}"
BACKEND_URL="$FRONTEND_URL"
ALLOWED_HOSTS="${CHAT_SUB}.${DOMAIN_NAME}"

echo
echo "=== SMTP (opcional — pode deixar em branco e configurar depois) ==="
read -rp "SMTP_ADDRESS []: " SMTP_ADDRESS
read -rp "SMTP_PORT (ex.: 587/465) []: " SMTP_PORT
read -rp "SMTP_USERNAME []: " SMTP_USERNAME
read -rp "SMTP_PASSWORD []: " SMTP_PASSWORD
read -rp "SMTP_DOMAIN (ex.: seu-dominio.com) []: " SMTP_DOMAIN
read -rp "MAILER_SENDER_EMAIL (ex.: no-reply@${DOMAIN_NAME}) []: " MAILER_SENDER_EMAIL

ENABLE_ACCOUNT_SIGNUP_DEFAULT="true"
read -rp "Permitir criação de conta no primeiro acesso? (true/false) [${ENABLE_ACCOUNT_SIGNUP_DEFAULT}]: " ENABLE_ACCOUNT_SIGNUP
ENABLE_ACCOUNT_SIGNUP="${ENABLE_ACCOUNT_SIGNUP:-$ENABLE_ACCOUNT_SIGNUP_DEFAULT}"

# Função pra gravar valores .env com aspas seguras
q() { printf '%s' "$1" | sed 's/"/\\"/g'; }

# Segredos
SECRET_KEY_BASE="$(openssl rand -hex 64)"
LOCKBOX_MASTER_KEY="$(openssl rand -hex 32)"

# Diretório isolado do Chatwoot
CW_DIR="$ROOT/chatwoot"
mkdir -p "$CW_DIR"

# Gera .env.chatwoot
ENV_CW="$CW_DIR/.env.chatwoot"
cat > "$ENV_CW" <<EOF
# === Chatwoot ENV (isolado) ===
RAILS_ENV=production
NODE_ENV=production
TZ=${TZ}

FRONTEND_URL=${FRONTEND_URL}
BACKEND_URL=${BACKEND_URL}
ALLOWED_HOSTS=${ALLOWED_HOSTS}
INSTALLATION_NAME="$(q "$INSTALLATION_NAME")"
DEFAULT_LOCALE=${DEFAULT_LOCALE}
ENABLE_ACCOUNT_SIGNUP=${ENABLE_ACCOUNT_SIGNUP}
FORCE_SSL=true

# Logs/estáticos
RAILS_LOG_TO_STDOUT=true
RAILS_SERVE_STATIC_FILES=true

# Segredos
SECRET_KEY_BASE=${SECRET_KEY_BASE}
LOCKBOX_MASTER_KEY=${LOCKBOX_MASTER_KEY}
ACTIVE_STORAGE_SERVICE=local

# DB (reuso)
POSTGRES_HOST=${PG_HOST}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USERNAME=${PG_USER}
POSTGRES_PASSWORD="$(q "$PG_PASS")"
POSTGRES_DATABASE=${PG_DB}

# Redis (reuso)
REDIS_URL=${REDIS_URL}

# SMTP (opcional)
SMTP_ADDRESS=${SMTP_ADDRESS}
SMTP_PORT=${SMTP_PORT}
SMTP_USERNAME=${SMTP_USERNAME}
SMTP_PASSWORD="$(q "$SMTP_PASSWORD")"
SMTP_DOMAIN=${SMTP_DOMAIN}
MAILER_SENDER_EMAIL=${MAILER_SENDER_EMAIL}

# Docker infos
DOCKER_ENV=true
EOF
echo "✅ .env salvo em: $ENV_CW"

# Descobre a rede do Postgres (ou do Traefik) para plugar o Chatwoot
NET_NAME="$(docker inspect postgres --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' 2>/dev/null | head -n1 || true)"
if [[ -z "${NET_NAME:-}" ]]; then
  NET_NAME="$(docker inspect traefik --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' 2>/dev/null | head -n1 || true)"
fi
[[ -z "${NET_NAME:-}" ]] && NET_NAME="root_web"
docker network inspect "$NET_NAME" >/dev/null 2>&1 || docker network create "$NET_NAME" >/dev/null

CHATWOOT_HOST="${CHAT_SUB}.${DOMAIN_NAME}"

# docker-compose.chatwoot.yml
DC="$CW_DIR/docker-compose.chatwoot.yml"
cat > "$DC" <<YAML
services:
  chatwoot:
    image: chatwoot/chatwoot:latest-ce
    container_name: chatwoot
    restart: always
    env_file:
      - .env.chatwoot
    environment:
      RAILS_LOG_TO_STDOUT: "true"
      RAILS_SERVE_STATIC_FILES: "true"
    command: sh -lc "bundle exec rails s -p 3000 -b 0.0.0.0"
    volumes:
      - chatwoot_storage:/app/storage
    depends_on:
      - chatwoot-worker
    labels:
      - traefik.enable=true
      - traefik.http.routers.chatwoot.rule=Host(\`${CHATWOOT_HOST}\`)
      - traefik.http.routers.chatwoot.entrypoints=web,websecure
      - traefik.http.routers.chatwoot.tls=true
      - traefik.http.routers.chatwoot.tls.certresolver=mytlschallenge
      - traefik.http.services.chatwoot.loadbalancer.server.port=3000
      - traefik.http.services.chatwoot.loadbalancer.server.scheme=http
    healthcheck:
      test: ["CMD-SHELL", "code=\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/health || echo 000); case \$code in 2*|3*) exit 0;; *) exit 1;; esac"]
      interval: 15s
      timeout: 5s
      retries: 20
    networks: [ web ]

  chatwoot-worker:
    image: chatwoot/chatwoot:latest-ce
    container_name: chatwoot-worker
    restart: always
    env_file:
      - .env.chatwoot
    command: bundle exec sidekiq -C config/sidekiq.yml
    volumes:
      - chatwoot_storage:/app/storage
    networks: [ web ]

volumes:
  chatwoot_storage:

networks:
  web:
    external: true
    name: ${NET_NAME}
YAML
echo "✅ Compose salvo em: $DC"

# Pré-requisitos do Postgres: instalar pgvector e criar DB/EXTENSION
echo "=== Preparando Postgres (pgvector + DB) ==="
# instala pgvector dentro do container postgres
PG_MAJOR="$(docker exec -i postgres psql -V | awk '{print $3}' | cut -d. -f1)"
docker exec -i postgres bash -lc "apt-get update && apt-get install -y postgresql-${PG_MAJOR}-pgvector >/dev/null"

# cria DB se faltar + extension vector
if [[ -f "$MAIN_COMPOSE" ]]; then
  docker compose -f "$MAIN_COMPOSE" --project-directory "$ROOT" exec -T postgres \
    psql -U "$PG_USER" -d postgres -c "SELECT 1 FROM pg_database WHERE datname='${PG_DB}';" | grep -q 1 \
    || docker compose -f "$MAIN_COMPOSE" --project-directory "$ROOT" exec -T postgres \
         psql -U "$PG_USER" -d postgres -c "CREATE DATABASE ${PG_DB};"
  docker compose -f "$MAIN_COMPOSE" --project-directory "$ROOT" exec -T postgres \
    psql -U "$PG_USER" -d "$PG_DB" -c 'CREATE EXTENSION IF NOT EXISTS vector;'
else
  # fallback (sem compose principal)
  docker exec -i postgres psql -U "$PG_USER" -d postgres -c "SELECT 1 FROM pg_database WHERE datname='${PG_DB}';" | grep -q 1 \
    || docker exec -i postgres psql -U "$PG_USER" -d postgres -c "CREATE DATABASE ${PG_DB};"
  docker exec -i postgres psql -U "$PG_USER" -d "$PG_DB" -c 'CREATE EXTENSION IF NOT EXISTS vector;'
fi
echo "✅ Postgres OK"

# Migrations (one-off)
export DOCKER_CLIENT_TIMEOUT=300 COMPOSE_HTTP_TIMEOUT=300
docker compose -f "$DC" --project-directory "$CW_DIR" run --rm chatwoot bundle exec rails db:chatwoot_prepare >/dev/null || true

# Sobe serviços
docker compose -f "$DC" --project-directory "$CW_DIR" up -d chatwoot chatwoot-worker

# Instala chat-check
HC_URL="https://raw.githubusercontent.com/mutuadigital/imautomaia/refs/heads/main/chatwoot-healthcheck.sh"
INSTALL_DIR="/opt/chatwoot"; BIN="/usr/local/bin/chat-check"
mkdir -p "$INSTALL_DIR"
curl -fsSL "$HC_URL" -o "$INSTALL_DIR/chatwoot-healthcheck.sh"
# força usar 'sh -lc' em qualquer trecho do healthcheck
sed -i 's/bash -lc/sh -lc/g' "$INSTALL_DIR/chatwoot-healthcheck.sh"
chmod +x "$INSTALL_DIR/chatwoot-healthcheck.sh"

cat > "$BIN" <<'EOF'
#!/usr/bin/env bash
ENV_CW="/root/chatwoot/.env.chatwoot" exec /opt/chatwoot/chatwoot-healthcheck.sh "$@"
EOF
chmod +x "$BIN"

# Aviso opcional sobre Traefik (não modifica nada)
if docker inspect traefik >/dev/null 2>&1; then
  if ! docker inspect traefik --format '{{range .Args}}{{println .}}{{end}}' | grep -q 'acme.httpchallenge'; then
    echo
    echo "⚠️  Seu Traefik não parece ter o ACME http-01 habilitado."
    echo "   Sem isso o certificado Let's Encrypt pode falhar."
    echo "   Ajuste no /root/docker-compose.yml do Traefik (exemplo):"
    echo '      - "--certificatesresolvers.mytlschallenge.acme.httpchallenge=true"'
    echo '      - "--certificatesresolvers.mytlschallenge.acme.httpchallenge.entrypoint=web"'
  fi
fi

# Dica DNS
SERVER_IP="$(curl -s https://ipv4.icanhazip.com || true)"
echo
echo "=== Finalizado 🚀 ==="
echo "URL: https://${CHATWOOT_HOST}"
echo "Se precisar testar agora:  chat-check"
echo "Certifique-se de que ${CHATWOOT_HOST} -> ${SERVER_IP} no DNS."
