#!/usr/bin/env bash
set -Eeuo pipefail

# =========[ Chatwoot Add-on Installer ]=========
# - Não altera seu stack principal (Traefik/Redis/Postgres/n8n)
# - Usa Postgres/Redis existentes
# - Cria artefatos em /root/chatwoot
# - Funciona mesmo via: bash <(curl -fsSL URL)
# ===============================================

trap 'echo "❌ Erro na linha $LINENO"; exit 1' ERR

# Diretório persistente para arquivos do Chatwoot
CHAT_DIR="${CHAT_DIR:-/root/chatwoot}"
mkdir -p "$CHAT_DIR"
cd "$CHAT_DIR"

ENV_MAIN=""
for f in "/root/.env" "./.env"; do [[ -f "$f" ]] && ENV_MAIN="$f" && break; done
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

echo "=== Chatwoot - Configuração Rápida ==="
read -rp "Domínio raiz (ex.: imautomaia.com.br) [${DOMAIN_NAME_DEFAULT}]: " DOMAIN_NAME
DOMAIN_NAME="${DOMAIN_NAME:-$DOMAIN_NAME_DEFAULT}"

read -rp "Subdomínio do Chatwoot (ex.: chat) [${CHAT_SUB_DEFAULT}]: " CHAT_SUB
CHAT_SUB="${CHAT_SUB:-$CHAT_SUB_DEFAULT}"

read -rp "Timezone (ex.: America/Sao_Paulo) [${TZ_DEFAULT}]: " TZ
TZ="${TZ:-$TZ_DEFAULT}"

echo
echo "=== Banco de Dados (reutilizando Postgres existente) ==="
read -rp "Postgres HOST [${PG_HOST_DEFAULT}]: " PG_HOST;  PG_HOST="${PG_HOST:-$PG_HOST_DEFAULT}"
read -rp "Postgres PORT [${PG_PORT_DEFAULT}]: " PG_PORT;  PG_PORT="${PG_PORT:-$PG_PORT_DEFAULT}"
read -rp "Postgres USER [${PG_USER_DEFAULT}]: " PG_USER;  PG_USER="${PG_USER:-$PG_USER_DEFAULT}"
read -rp "Postgres PASS [${PG_PASS_DEFAULT}]: " PG_PASS;  PG_PASS="${PG_PASS:-$PG_PASS_DEFAULT}"
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

ENABLE_ACCOUNT_SIGNUP_DEFAULT="true"
read -rp "Permitir criação de conta no primeiro acesso? (true/false) [${ENABLE_ACCOUNT_SIGNUP_DEFAULT}]: " ENABLE_ACCOUNT_SIGNUP
ENABLE_ACCOUNT_SIGNUP="${ENABLE_ACCOUNT_SIGNUP:-$ENABLE_ACCOUNT_SIGNUP_DEFAULT}"

SECRET_KEY_BASE="$(openssl rand -hex 64)"

# ---------- .env.chatwoot ----------
ENV_CW="$CHAT_DIR/.env.chatwoot"
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

DOCKER_ENV=true
EOF
echo "✅ .env salvo em: $ENV_CW"

# ---------- docker-compose.chatwoot.yml ----------
DC="$CHAT_DIR/docker-compose.chatwoot.yml"
cat > "$DC" <<YAML
services:
  chatwoot:
    image: chatwoot/chatwoot:latest
    container_name: chatwoot
    restart: always
    env_file:
      - $ENV_CW
    environment:
      RAILS_LOG_TO_STDOUT: "true"
    volumes:
      - chatwoot_storage:/app/storage
    depends_on:
      - chatwoot-worker
    labels:
      - traefik.enable=true
      - traefik.http.routers.chatwoot.rule=Host(\`${CHAT_SUB}.${DOMAIN_NAME}\`)
      - traefik.http.routers.chatwoot.entrypoints=web,websecure
      - traefik.http.routers.chatwoot.tls=true
      - traefik.http.routers.chatwoot.tls.certresolver=mytlschallenge
      - traefik.http.services.chatwoot.loadbalancer.server.port=3000
    networks: [ web ]

  chatwoot-worker:
    image: chatwoot/chatwoot:latest
    container_name: chatwoot-worker
    restart: always
    env_file:
      - $ENV_CW
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
echo "✅ Compose salvo em: $DC"

# ---------- Rede 'web' ----------
if ! docker network inspect web >/dev/null 2>&1; then
  echo "ℹ️ Criando rede 'web'…"
  docker network create web >/dev/null
fi

# ---------- Criação do banco (idempotente) ----------
echo "=== Checando/criando banco '${PG_DB}' ==="
PG_CONT="$(docker ps --format '{{.Names}}' | grep -E '^postgres$' || true)"
if [[ -z "${PG_CONT}" ]]; then
  echo "⚠️  Container 'postgres' não encontrado. Pulei criação automática do banco."
else
  docker exec -i "$PG_CONT" psql -U "$PG_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" | grep -q 1 \
    || docker exec -i "$PG_CONT" psql -U "$PG_USER" -d postgres -c "CREATE DATABASE ${PG_DB};"
  echo "✅ Banco OK: ${PG_DB}"
fi

# ---------- Migrations / prepare ----------
echo "=== Executando migrations (db:chatwoot_prepare) ==="
docker compose -f "$DC" run --rm chatwoot bash -lc "bundle exec rails db:chatwoot_prepare" >/dev/null
echo "✅ Migrations concluídas"

# ---------- Sobe serviços ----------
docker compose -f "$DC" up -d chatwoot chatwoot-worker

# ---------- Healthcheck como comando (chat-check) ----------
HC_URL="https://raw.githubusercontent.com/mutuadigital/imautomaia/refs/heads/main/chatwoot-healthcheck.sh"
install -d "$CHAT_DIR"
curl -fsSL "$HC_URL" -o "$CHAT_DIR/chatwoot-healthcheck.sh"
chmod +x "$CHAT_DIR/chatwoot-healthcheck.sh"

cat > /usr/local/bin/chat-check <<EOF
#!/usr/bin/env bash
ENV_CW="$ENV_CW" exec "$CHAT_DIR/chatwoot-healthcheck.sh" "\$@"
EOF
chmod +x /usr/local/bin/chat-check

echo
echo "🎉 Pronto!"
echo "URL:  https://${CHAT_SUB}.${DOMAIN_NAME}"
echo "Healthcheck a qualquer momento:  chat-check"
echo
echo "Obs.: se SMTP ficou em branco, envio de e-mails (confirmação/senha) fica desativado até configurar."
