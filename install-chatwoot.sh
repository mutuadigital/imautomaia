#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------
# Chatwoot Add-on Installer (Traefik + Docker)
# - Não altera seus serviços existentes
# - Usa Postgres/Redis já existentes
# - Gera docker-compose.chatwoot.yml separado
# - Instala "chat-check"
# --------------------------------------------

# === Config in one place ===
WORKDIR="/root/chatwoot"
HC_URL="https://raw.githubusercontent.com/mutuadigital/imautomaia/refs/heads/main/chatwoot-healthcheck.sh"
WRAPPER_BIN="/usr/local/bin/chat-check"
CHATWOOT_IMAGE_TAG="${CHATWOOT_IMAGE_TAG:-latest-ce}"   # Ex.: v4.1.0, v3.15.2-ce, latest-ce

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Carrega .env principal se existir (p/ defaults)
for f in "/root/.env" "./.env"; do
  [[ -f "$f" ]] && source "$f"
done

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

echo "=== Chatwoot - Configuração Rápida ==="
read -rp "Domínio raiz (ex.: imautomaia.com.br) [${DOMAIN_NAME_DEFAULT}]: " DOMAIN_NAME
DOMAIN_NAME="${DOMAIN_NAME:-$DOMAIN_NAME_DEFAULT}"

read -rp "Subdomínio do Chatwoot (ex.: chat) [${CHAT_SUB_DEFAULT}]: " CHAT_SUB
CHAT_SUB="${CHAT_SUB:-$CHAT_SUB_DEFAULT}"

read -rp "Timezone (ex.: America/Sao_Paulo) [${TZ_DEFAULT}]: " TZ
TZ="${TZ:-$TZ_DEFAULT}"

echo
echo "=== Banco de Dados (reutilizando Postgres existente) ==="
read -rp "Postgres HOST [${PG_HOST_DEFAULT}]: " PG_HOST; PG_HOST="${PG_HOST:-$PG_HOST_DEFAULT}"
read -rp "Postgres PORT [${PG_PORT_DEFAULT}]: " PG_PORT; PG_PORT="${PG_PORT:-$PG_PORT_DEFAULT}"
read -rp "Postgres USER [${PG_USER_DEFAULT}]: " PG_USER; PG_USER="${PG_USER:-$PG_USER_DEFAULT}"
read -rp "Postgres PASS [${PG_PASS_DEFAULT}]: " PG_PASS; PG_PASS="${PG_PASS:-$PG_PASS_DEFAULT}"
read -rp "Postgres DB (novo p/ Chatwoot) [${PG_DB_DEFAULT}]: " PG_DB; PG_DB="${PG_DB:-$PG_DB_DEFAULT}"

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

echo
echo "=== SMTP (opcional — pode deixar em branco e configurar depois) ==="
read -rp "SMTP_ADDRESS []: " SMTP_ADDRESS
read -rp "SMTP_PORT (ex.: 587/465) []: " SMTP_PORT
read -rp "SMTP_USERNAME []: " SMTP_USERNAME
read -rp "SMTP_PASSWORD []: " SMTP_PASSWORD
read -rp "SMTP_DOMAIN (ex.: seu-dominio.com) []: " SMTP_DOMAIN
read -rp "MAILER_SENDER_EMAIL (ex.: no-reply@${DOMAIN_NAME}) []: " MAILER_SENDER_EMAIL

ENABLE_ACCOUNT_SIGNUP="true"
read -rp "Permitir criação de conta no primeiro acesso? (true/false) [${ENABLE_ACCOUNT_SIGNUP}]: " TMP
ENABLE_ACCOUNT_SIGNUP="${TMP:-$ENABLE_ACCOUNT_SIGNUP}"

SECRET_KEY_BASE="$(openssl rand -hex 64)"

# === .env.chatwoot ===
ENV_CW="$WORKDIR/.env.chatwoot"
cat > "$ENV_CW" <<EOF
# === Chatwoot ENV ===
RAILS_ENV=production
NODE_ENV=production
TZ=${TZ}

FRONTEND_URL=${FRONTEND_URL}
BACKEND_URL=${BACKEND_URL}
INSTALLATION_NAME=${INSTALLATION_NAME}
DEFAULT_LOCALE=${DEFAULT_LOCALE}
ENABLE_ACCOUNT_SIGNUP=${ENABLE_ACCOUNT_SIGNUP}
FORCE_SSL=true
SECRET_KEY_BASE=${SECRET_KEY_BASE}
ACTIVE_STORAGE_SERVICE=local

# DB
POSTGRES_HOST=${PG_HOST}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USERNAME=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DATABASE=${PG_DB}

# Redis
REDIS_URL=${REDIS_URL}

# SMTP (opcional)
SMTP_ADDRESS=${SMTP_ADDRESS}
SMTP_PORT=${SMTP_PORT}
SMTP_USERNAME=${SMTP_USERNAME}
SMTP_PASSWORD=${SMTP_PASSWORD}
SMTP_DOMAIN=${SMTP_DOMAIN}
MAILER_SENDER_EMAIL=${MAILER_SENDER_EMAIL}

# Docker infos
DOCKER_ENV=true
EOF
echo "✅ .env salvo em: $ENV_CW"

# === docker-compose.chatwoot.yml (usa placeholders para evitar conflito com crases) ===
DC="$WORKDIR/docker-compose.chatwoot.yml"
cat > "$DC" <<'YAML'
services:
  chatwoot:
    image: __CHATWOOT_IMAGE__
    container_name: chatwoot
    restart: always
    env_file:
      - .env.chatwoot
    environment:
      RAILS_LOG_TO_STDOUT: "true"
    volumes:
      - chatwoot_storage:/app/storage
    depends_on:
      - chatwoot-worker
    labels:
      - traefik.enable=true
      - traefik.http.routers.chatwoot.rule=Host(`__CHATWOOT_HOST__`)
      - traefik.http.routers.chatwoot.entrypoints=web,websecure
      - traefik.http.routers.chatwoot.tls=true
      - traefik.http.routers.chatwoot.tls.certresolver=mytlschallenge
      - traefik.http.services.chatwoot.loadbalancer.server.port=3000
    networks: [ web ]

  chatwoot-worker:
    image: __CHATWOOT_IMAGE__
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
    name: web
YAML

CHATWOOT_HOST="${CHAT_SUB}.${DOMAIN_NAME}"
CHATWOOT_IMAGE="chatwoot/chatwoot:${CHATWOOT_IMAGE_TAG}"
sed -i "s|__CHATWOOT_HOST__|${CHATWOOT_HOST}|g" "$DC"
sed -i "s|__CHATWOOT_IMAGE__|${CHATWOOT_IMAGE}|g" "$DC"
echo "✅ Compose salvo em: $DC"

# === Garante rede 'web' existente ===
if ! docker network inspect web >/dev/null 2>&1; then
  echo "ℹ️ Criando rede 'web'…"
  docker network create web >/dev/null
fi

# === Cria DB se existir container postgres ===
echo "=== Checando/criando banco '${PG_DB}' ==="
if docker ps --format '{{.Names}}' | grep -qw postgres; then
  docker compose exec -T postgres psql -U "${PG_USER}" -d postgres \
    -c "SELECT 1 FROM pg_database WHERE datname='${PG_DB}';" | grep -q 1 \
  || docker compose exec -T postgres psql -U "${PG_USER}" -d postgres -c "CREATE DATABASE ${PG_DB};"
  echo "✅ Banco OK: ${PG_DB}"
else
  echo "⚠️ Container 'postgres' não encontrado. Pulei criação automática do DB."
fi

# === Migrations (sem bash; chama rails direto) ===
echo "=== Executando migrations (db:chatwoot_prepare) ==="
docker compose -f "$DC" --project-directory "$WORKDIR" run --rm chatwoot \
  bundle exec rails db:chatwoot_prepare
echo "✅ Migrations concluídas"

# === Sobe serviços ===
docker compose -f "$DC" --project-directory "$WORKDIR" up -d chatwoot chatwoot-worker

# === Healthcheck (chat-check) ===
INSTALL_DIR="/opt/chatwoot"
mkdir -p "$INSTALL_DIR"
curl -fsSL "$HC_URL" -o "$INSTALL_DIR/chatwoot-healthcheck.sh"
chmod +x "$INSTALL_DIR/chatwoot-healthcheck.sh"

cat > "$WRAPPER_BIN" <<EOF
#!/usr/bin/env bash
ENV_CW="$ENV_CW" exec "$INSTALL_DIR/chatwoot-healthcheck.sh" "\$@"
EOF
chmod +x "$WRAPPER_BIN"

echo
echo "✔ Healthcheck instalado. Use:  chat-check"
echo
echo "=== URLs ==="
echo "Chatwoot: https://${CHATWOOT_HOST}"
echo
echo "Pronto. 🚀"
