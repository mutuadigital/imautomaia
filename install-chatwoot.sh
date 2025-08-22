#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------
# Chatwoot Add-on Installer
# - Não altera seus serviços existentes
# - Usa Postgres/Redis já existentes
# - Gera docker-compose.chatwoot.yml separado
# --------------------------------------------

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

# Carrega variáveis principais se existirem
ENV_MAIN=""
for f in "./.env" "/root/.env"; do
  [[ -f "$f" ]] && ENV_MAIN="$f" && break
done
[[ -n "$ENV_MAIN" ]] && source "$ENV_MAIN"

# Descobrir valores padrão
DOMAIN_NAME_DEFAULT="${DOMAIN_NAME:-srv.example.tld}"
CHAT_SUB_DEFAULT="chat"
TZ_DEFAULT="${GENERIC_TIMEZONE:-America/Sao_Paulo}"

# Reaproveita as credenciais do Postgres/Redis já existentes
PG_USER_DEFAULT="${N8N_DB_USER:-n8n}"
PG_PASS_DEFAULT="${N8N_DB_PASS:-changeme}"
PG_DB_DEFAULT="chatwoot_production"
PG_HOST_DEFAULT="postgres"
PG_PORT_DEFAULT="5432"
REDIS_URL_DEFAULT="redis://redis:6379"

# Perguntas (com valores padrão)
echo "=== Chatwoot - Configuração Rápida ==="
read -rp "Domínio raiz (ex.: imautomaia.com.br) [${DOMAIN_NAME_DEFAULT}]: " DOMAIN_NAME
DOMAIN_NAME="${DOMAIN_NAME:-$DOMAIN_NAME_DEFAULT}"

read -rp "Subdomínio do Chatwoot (ex.: chat) [${CHAT_SUB_DEFAULT}]: " CHAT_SUB
CHAT_SUB="${CHAT_SUB:-$CHAT_SUB_DEFAULT}"

read -rp "Timezone (ex.: America/Sao_Paulo) [${TZ_DEFAULT}]: " TZ
TZ="${TZ:-$TZ_DEFAULT}"

# Postgres (reuso)
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

# Redis (reuso)
echo
echo "=== Redis (reutilizando Redis existente) ==="
read -rp "REDIS_URL [${REDIS_URL_DEFAULT}]: " REDIS_URL
REDIS_URL="${REDIS_URL:-$REDIS_URL_DEFAULT}"

# App
echo
echo "=== Aplicação ==="
read -rp "Nome da instalação (ex.: IMAUTOMAIA Chat) [Chatwoot]: " INSTALLATION_NAME
INSTALLATION_NAME="${INSTALLATION_NAME:-Chatwoot}"
read -rp "Locale padrão (ex.: pt_BR, en) [pt_BR]: " DEFAULT_LOCALE
DEFAULT_LOCALE="${DEFAULT_LOCALE:-pt_BR}"

FRONTEND_URL="https://${CHAT_SUB}.${DOMAIN_NAME}"
BACKEND_URL="$FRONTEND_URL"

# SMTP (opcional)
echo
echo "=== SMTP (opcional — pode deixar em branco e configurar depois) ==="
read -rp "SMTP_ADDRESS []: " SMTP_ADDRESS
read -rp "SMTP_PORT (ex.: 587) []: " SMTP_PORT
read -rp "SMTP_USERNAME []: " SMTP_USERNAME
read -rp "SMTP_PASSWORD []: " SMTP_PASSWORD
read -rp "SMTP_DOMAIN (ex.: imautomaia.com.br) []: " SMTP_DOMAIN
read -rp "MAILER_SENDER_EMAIL (ex.: no-reply@${DOMAIN_NAME}) []: " MAILER_SENDER_EMAIL

ENABLE_ACCOUNT_SIGNUP_DEFAULT="true"
read -rp "Permitir criação de conta no primeiro acesso? (true/false) [${ENABLE_ACCOUNT_SIGNUP_DEFAULT}]: " ENABLE_ACCOUNT_SIGNUP
ENABLE_ACCOUNT_SIGNUP="${ENABLE_ACCOUNT_SIGNUP:-$ENABLE_ACCOUNT_SIGNUP_DEFAULT}"

# Segredo
SECRET_KEY_BASE="$(openssl rand -hex 64)"

# Gera .env.chatwoot (isolado)
ENV_CW="$here/.env.chatwoot"
cat > "$ENV_CW" <<EOF
# === Chatwoot ENV (isolado do stack principal) ===
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

# DB (reuso)
POSTGRES_HOST=${PG_HOST}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USERNAME=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DATABASE=${PG_DB}

# Redis (reuso)
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
echo "✅ Arquivo gerado: $ENV_CW"

# docker-compose.chatwoot.yml (separado)
DC="$here/docker-compose.chatwoot.yml"
cat > "$DC" <<'YAML'
services:
  chatwoot:
    image: chatwoot/chatwoot:latest
    container_name: chatwoot
    restart: always
    env_file:
      - .env.chatwoot
    environment:
      # Garante que use as variáveis do env_file
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
    image: chatwoot/chatwoot:latest
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
echo "✅ Arquivo gerado: $DC"

# Substitui placeholder de host nas labels
CHATWOOT_HOST="${CHAT_SUB}.${DOMAIN_NAME}"
sed -i "s|\`${CHATWOOT_HOST//\//\\/}\`|\`${CHATWOOT_HOST}\`|g" "$DC"

# Se por algum motivo não substituiu (fresh file), força com uma troca direta:
if ! grep -q "Host(\`${CHATWOOT_HOST}\`)" "$DC"; then
  sed -i "s|\`\\\${CHATWOOT_HOST}\`|\`${CHATWOOT_HOST}\`|g" "$DC"
fi

# Garante rede 'web' existente (não reinicia nada)
if ! docker network inspect web >/dev/null 2>&1; then
  echo "ℹ️ Criando rede 'web' (externa) para uso do Traefik..."
  docker network create web >/dev/null
fi

# Cria DB se não existir (usando o mesmo container 'postgres' do stack principal)
echo "=== Criando banco (se necessário) ==="
docker compose exec -T postgres \
  psql -U "${PG_USER}" -d postgres \
  -c "SELECT 1 FROM pg_database WHERE datname='${PG_DB}';" | grep -q 1 \
  || docker compose exec -T postgres \
       psql -U "${PG_USER}" -d postgres -c "CREATE DATABASE ${PG_DB};"
echo "✅ Banco OK: ${PG_DB}"

# Prepara DB (migrations + assets) usando o container web (one-off)
echo "=== Rodando migrations (db:chatwoot_prepare) ==="
docker compose -f "$DC" run --rm chatwoot bash -lc \
  "bundle exec rails db:chatwoot_prepare" >/dev/null
echo "✅ Migrations concluídas"

# Sobe serviços (sem afetar o stack principal)
docker compose -f "$DC" up -d chatwoot chatwoot-worker

# === Instalação do healthcheck (chat-check) ===
set -e
HC_URL="https://raw.githubusercontent.com/mutuadigital/imautomaia/refs/heads/main/chatwoot-healthcheck.sh"
INSTALL_DIR="/opt/chatwoot"
BIN="/usr/local/bin/chat-check"

mkdir -p "$INSTALL_DIR"
curl -fsSL "$HC_URL" -o "$INSTALL_DIR/chatwoot-healthcheck.sh"
chmod +x "$INSTALL_DIR/chatwoot-healthcheck.sh"

# Wrapper simples no PATH do sistema
cat > "$BIN" <<'EOF'
#!/usr/bin/env bash
# Wrapper para rodar o healthcheck de qualquer lugar
# Usa /root/.env.chatwoot se existir; caso não, o script se vira sozinho.
ENV_CW="/root/.env.chatwoot" exec /opt/chatwoot/chatwoot-healthcheck.sh "$@"
EOF
chmod +x "$BIN"

echo
echo "✔ Healthcheck instalado. Use:  chat-check"
echo
echo "=== URLs ==="
echo "Chatwoot: https://${CHATWOOT_HOST}"
echo
echo "Se o Traefik já estiver emitindo certificados, o acesso será HTTPS válido."
echo "Caso a página abra mas você precise criar o primeiro usuário,"
echo "mantenha ENABLE_ACCOUNT_SIGNUP=true (já está no .env.chatwoot)."
echo
echo "Pronto. 🚀"
