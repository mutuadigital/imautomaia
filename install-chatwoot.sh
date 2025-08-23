#!/usr/bin/env bash
set -euo pipefail

ROOT="/root"
CW_DIR="$ROOT/chatwoot"
mkdir -p "$CW_DIR"
cd "$CW_DIR"

# Tenta herdar credenciais do stack principal
ENV_MAIN="$ROOT/.env"
[[ -f "$ENV_MAIN" ]] && source "$ENV_MAIN" || true

DOMAIN_NAME_DEFAULT="${DOMAIN_NAME:-example.com}"
CHAT_SUB_DEFAULT="chat"
TZ_DEFAULT="${GENERIC_TIMEZONE:-America/Sao_Paulo}"

PG_HOST_DEFAULT="postgres"
PG_PORT_DEFAULT="5432"
PG_USER_DEFAULT="${N8N_DB_USER:-n8n}"
PG_PASS_DEFAULT="${N8N_DB_PASS:-changeme}"
PG_DB_DEFAULT="chatwoot_production"
REDIS_URL_DEFAULT="redis://redis:6379"

echo "=== Chatwoot - Configuração Rápida ==="
read -rp "Domínio (ex.: imautomaia.com.br) [$DOMAIN_NAME_DEFAULT]: " DOMAIN_NAME
DOMAIN_NAME="${DOMAIN_NAME:-$DOMAIN_NAME_DEFAULT}"

read -rp "Subdomínio (ex.: chat) [$CHAT_SUB_DEFAULT]: " CHAT_SUB
CHAT_SUB="${CHAT_SUB:-$CHAT_SUB_DEFAULT}"

read -rp "Timezone [$TZ_DEFAULT]: " TZ
TZ="${TZ:-$TZ_DEFAULT}"

# DB (reuso)
echo
echo "=== Postgres ==="
read -rp "HOST [$PG_HOST_DEFAULT]: " PG_HOST; PG_HOST="${PG_HOST:-$PG_HOST_DEFAULT}"
read -rp "PORT [$PG_PORT_DEFAULT]: " PG_PORT; PG_PORT="${PG_PORT:-$PG_PORT_DEFAULT}"
read -rp "USER [$PG_USER_DEFAULT]: " PG_USER; PG_USER="${PG_USER:-$PG_USER_DEFAULT}"
read -rp "PASS [$PG_PASS_DEFAULT]: " PG_PASS; PG_PASS="${PG_PASS:-$PG_PASS_DEFAULT}"
read -rp "DB   [$PG_DB_DEFAULT]: " PG_DB;   PG_DB="${PG_DB:-$PG_DB_DEFAULT}"

# Redis (reuso)
echo
echo "=== Redis ==="
read -rp "REDIS_URL [$REDIS_URL_DEFAULT]: " REDIS_URL
REDIS_URL="${REDIS_URL:-$REDIS_URL_DEFAULT}"

# SMTP (opcional)
echo
echo "=== SMTP (opcional) ==="
read -rp "SMTP_ADDRESS []: " SMTP_ADDRESS
read -rp "SMTP_PORT (587/465) []: " SMTP_PORT
read -rp "SMTP_USERNAME []: " SMTP_USERNAME
read -rp "SMTP_PASSWORD (Gmail: SEM espaços) []: " SMTP_PASSWORD
SMTP_PASSWORD="${SMTP_PASSWORD// /}"  # remove espaços
read -rp "SMTP_DOMAIN (ex.: $DOMAIN_NAME) []: " SMTP_DOMAIN
read -rp "MAILER_SENDER_EMAIL (ex.: no-reply@$DOMAIN_NAME) []: " MAILER_SENDER_EMAIL

# App
INSTALLATION_NAME_DEFAULT="Chatwoot"
read -rp "Nome da instalação [$INSTALLATION_NAME_DEFAULT]: " INSTALLATION_NAME
INSTALLATION_NAME="${INSTALLATION_NAME:-$INSTALLATION_NAME_DEFAULT}"
read -rp "Locale padrão (pt_BR/en) [pt_BR]: " DEFAULT_LOCALE
DEFAULT_LOCALE="${DEFAULT_LOCALE:-pt_BR}"

ENABLE_ACCOUNT_SIGNUP_DEFAULT="true"
read -rp "Permitir signup no primeiro acesso? (true/false) [$ENABLE_ACCOUNT_SIGNUP_DEFAULT]: " ENABLE_ACCOUNT_SIGNUP
ENABLE_ACCOUNT_SIGNUP="${ENABLE_ACCOUNT_SIGNUP:-$ENABLE_ACCOUNT_SIGNUP_DEFAULT}"

FRONTEND_URL="https://${CHAT_SUB}.${DOMAIN_NAME}"
BACKEND_URL="$FRONTEND_URL"
SECRET_KEY_BASE="$(openssl rand -hex 64)"

# ==== .env.chatwoot ====
ENV_CW="$CW_DIR/.env.chatwoot"
cat > "$ENV_CW" <<EOF
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

POSTGRES_HOST=${PG_HOST}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USERNAME=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DATABASE=${PG_DB}

REDIS_URL=${REDIS_URL}

SMTP_ADDRESS=${SMTP_ADDRESS}
SMTP_PORT=${SMTP_PORT}
SMTP_USERNAME=${SMTP_USERNAME}
SMTP_PASSWORD=${SMTP_PASSWORD}
SMTP_DOMAIN=${SMTP_DOMAIN}
MAILER_SENDER_EMAIL=${MAILER_SENDER_EMAIL}

DOCKER_ENV=true
EOF
echo "✅ .env salvo em: $ENV_CW"

# ==== docker-compose.chatwoot.yml ====
DC="$CW_DIR/docker-compose.chatwoot.yml"
cat > "$DC" <<'YAML'
services:
  chatwoot:
    image: chatwoot/chatwoot:latest-ce
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
      - traefik.http.routers.chatwoot.rule=Host(`${CHATWOOT_HOST}`)
      - traefik.http.routers.chatwoot.entrypoints=web,websecure
      - traefik.http.routers.chatwoot.tls=true
      - traefik.http.routers.chatwoot.tls.certresolver=mytlschallenge
      - traefik.http.services.chatwoot.loadbalancer.server.port=3000
    networks: [ web ]

  chatwoot-worker:
    image: chatwoot/chatwoot:latest-ce
    container_name: chatwoot-worker
    restart: always
    env_file:
      - .env.chatwoot
    command: sh -lc "bundle exec sidekiq -C config/sidekiq.yml"
    volumes:
      - chatwoot_storage:/app/storage
    networks: [ web ]

volumes:
  chatwoot_storage:

networks:
  web:
    external: true
    name: root_web
YAML
# Substitui host nas labels
CHATWOOT_HOST="${CHAT_SUB}.${DOMAIN_NAME}"
sed -i "s|\`${CHATWOOT_HOST//\//\\/}\`|\`${CHATWOOT_HOST}\`|g" "$DC" || true
if ! grep -q "Host(\`${CHATWOOT_HOST}\`)" "$DC"; then
  sed -i "s|\`\\\${CHATWOOT_HOST}\`|\`${CHATWOOT_HOST}\`|g" "$DC"
fi
echo "✅ Compose salvo em: $DC"

# ==== Rede web externa ====
docker network inspect root_web >/dev/null 2>&1 || docker network create root_web >/dev/null

# ==== Garante pgvector no Postgres do stack ====
echo "=== Ativando pgvector no Postgres do stack ==="
PG_MAJOR=$(docker exec -i postgres psql -V | awk '{print $3}' | cut -d. -f1)
docker exec -i postgres bash -lc "apt-get update >/dev/null && apt-get install -y postgresql-${PG_MAJOR}-pgvector >/dev/null"
docker exec -i postgres psql -U "${PG_USER}" -d "${PG_DB}" -c 'CREATE EXTENSION IF NOT EXISTS vector;' >/dev/null \
  || true
echo "✅ pgvector OK"

# ==== Migrations ====
echo "=== Executando migrations (db:chatwoot_prepare) ==="
export DOCKER_CLIENT_TIMEOUT=300 COMPOSE_HTTP_TIMEOUT=300
docker compose -f "$DC" --project-directory "$CW_DIR" run --rm chatwoot \
  sh -lc "bundle exec rails db:chatwoot_prepare" >/dev/null
echo "✅ Migrations concluídas"

# ==== Sobe serviços ====
docker compose -f "$DC" --project-directory "$CW_DIR" up -d chatwoot chatwoot-worker

# ==== Healthcheck instalador ====
HC_URL="https://raw.githubusercontent.com/mutuadigital/imautomaia/refs/heads/main/chatwoot-healthcheck.sh"
INSTALL_DIR="/opt/chatwoot"; BIN="/usr/local/bin/chat-check"
mkdir -p "$INSTALL_DIR"
curl -fsSL "$HC_URL" -o "$INSTALL_DIR/chatwoot-healthcheck.sh"
chmod +x "$INSTALL_DIR/chatwoot-healthcheck.sh"
cat > "$BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ENV_CW="/root/chatwoot/.env.chatwoot" exec /opt/chatwoot/chatwoot-healthcheck.sh "$@"
EOF
chmod +x "$BIN"

echo
echo "Pronto! ✅"
echo "Chatwoot: https://${CHATWOOT_HOST}"
echo "Healthcheck: chat-check"
echo
echo "Dica: gere um Personal Access Token (Perfil → Access tokens)."
echo "No canal API, use Webhook URL: https://${EVO_SUBDOMAIN:-wa}.${DOMAIN_NAME}/chatwoot/webhook/<NOME-DA-INSTANCIA-NA-EVOLUTION>"
