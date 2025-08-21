#!/usr/bin/env bash
set -euo pipefail

# === util ===
randhex() { openssl rand -hex "${1:-24}"; }
ask() {
  local prompt="$1" default="${2:-}" var
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " var || true
    echo "${var:-$default}"
  else
    read -r -p "$prompt: " var || true
    echo "$var"
  fi
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Falta o comando '$1'."; exit 1; }
}

# === pré-checagens ===
require docker
require openssl

# === perguntas ===
echo "== Configuração =="
DOMAIN_NAME="$(ask "Domínio raiz (ex.: imautomaia.com.br)" "${DOMAIN_NAME:-}")"
SUBDOMAIN="$(ask "Subdomínio do n8n" "${SUBDOMAIN:-n8n}")"
EVO_SUBDOMAIN="$(ask "Subdomínio da Evolution" "${EVO_SUBDOMAIN:-wa}")"
GENERIC_TIMEZONE="$(ask "Timezone" "${GENERIC_TIMEZONE:-America/Sao_Paulo}")"
SSL_EMAIL="$(ask "Email para Let's Encrypt" "${SSL_EMAIL:-you@example.com}")"

PORTAINER_HOST="$(ask "Host do Portainer (FQDN)" "${PORTAINER_HOST:-portainer.${DOMAIN_NAME}}")"
TRAEFIK_HOST="$(ask "Host do Traefik (FQDN)" "${TRAEFIK_HOST:-traefik.${DOMAIN_NAME}}")"

N8N_DB_USER="$(ask "Postgres USER (n8n)" "${N8N_DB_USER:-n8n}")"
N8N_DB_PASS_DEFAULT="$(randhex 16)"
N8N_DB_PASS="$(ask "Postgres PASS (auto se vazio)" "${N8N_DB_PASS:-$N8N_DB_PASS_DEFAULT}")"
N8N_DB_NAME="$(ask "Postgres DB" "${N8N_DB_NAME:-n8ndb}")"

EVOLUTION_API_KEY_DEFAULT="$(randhex 16)"
EVOLUTION_API_KEY="$(ask "Evolution API Global Key (auto se vazio)" "${EVOLUTION_API_KEY:-$EVOLUTION_API_KEY_DEFAULT}")"

TRAEFIK_USER="$(ask "Usuário do painel Traefik" "${TRAEFIK_USER:-admin}")"
read -r -s -p "Senha do painel Traefik (deixe vazio p/ gerar): " TRAEFIK_PASS || true; echo
if [[ -z "${TRAEFIK_PASS:-}" ]]; then TRAEFIK_PASS="$(randhex 12)"; fi
HTPASS_HASH="$(openssl passwd -apr1 "$TRAEFIK_PASS")"

N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(randhex 24)}"

# === grava .env ===
cat > .env <<EOF
DOMAIN_NAME=${DOMAIN_NAME}
SUBDOMAIN=${SUBDOMAIN}
EVO_SUBDOMAIN=${EVO_SUBDOMAIN}
GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
SSL_EMAIL=${SSL_EMAIL}
PORTAINER_HOST=${PORTAINER_HOST}
TRAEFIK_HOST=${TRAEFIK_HOST}

# Postgres (compartilhado n8n + evolution)
N8N_DB_USER=${N8N_DB_USER}
N8N_DB_PASS=${N8N_DB_PASS}
N8N_DB_NAME=${N8N_DB_NAME}

# n8n
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

# Evolution
EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
EOF
echo "✅ .env escrito."

# === diretórios ===
mkdir -p traefik
echo "${TRAEFIK_USER}:${HTPASS_HASH}" > traefik/htpasswd
chmod 640 traefik/htpasswd
echo "✅ htpasswd criado para painel Traefik (${TRAEFIK_USER})."

# === docker compose (se não existir) ===
if [[ ! -f docker-compose.yml ]]; then
cat > docker-compose.yml <<'YAML'
services:

  traefik:
    image: traefik:v3.5
    container_name: traefik
    restart: always
    ports:
      - "80:80"
      - "443:443"
    command:
      - "--api=true"
      - "--api.insecure=false"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--log.level=INFO"
      - "--certificatesresolvers.mytlschallenge.acme.email=${SSL_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.mytlschallenge.acme.httpchallenge.entrypoint=web"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_data:/letsencrypt
      - ./traefik/htpasswd:/etc/traefik/htpasswd:ro
    labels:
      - traefik.enable=true
      - traefik.http.routers.traefik.rule=Host(`${TRAEFIK_HOST}`)
      - traefik.http.routers.traefik.entrypoints=web,websecure
      - traefik.http.routers.traefik.tls=true
      - traefik.http.routers.traefik.tls.certresolver=mytlschallenge
      - traefik.http.routers.traefik.service=api@internal
      - traefik.http.middlewares.traefik-auth.basicauth.usersfile=/etc/traefik/htpasswd
      - traefik.http.routers.traefik.middlewares=traefik-auth@docker
    networks: [ web ]

  redis:
    image: redis:6
    container_name: redis
    restart: always
    volumes:
      - redis_data:/data
    networks: [ web ]

  postgres:
    image: postgres:15
    container_name: postgres
    restart: always
    environment:
      POSTGRES_USER: ${N8N_DB_USER}
      POSTGRES_PASSWORD: ${N8N_DB_PASS}
      POSTGRES_DB: ${N8N_DB_NAME}
    volumes:
      - pg_data:/var/lib/postgresql/data
    networks: [ web ]

  n8n:
    image: docker.n8n.io/n8nio/n8n
    container_name: n8n
    restart: always
    environment:
      N8N_HOST: ${SUBDOMAIN}.${DOMAIN_NAME}
      N8N_PROTOCOL: https
      N8N_PORT: 5678
      WEBHOOK_URL: https://${SUBDOMAIN}.${DOMAIN_NAME}/
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${N8N_DB_NAME}
      DB_POSTGRESDB_USER: ${N8N_DB_USER}
      DB_POSTGRESDB_PASSWORD: ${N8N_DB_PASS}
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: 6379
      N8N_RUNNERS_ENABLED: "true"
      OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS: "true"
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
    volumes:
      - n8n_data:/home/node/.n8n
      - /local-files:/files
    depends_on:
      - postgres
      - redis
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(`${SUBDOMAIN}.${DOMAIN_NAME}`)
      - traefik.http.routers.n8n.entrypoints=web,websecure
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.tls.certresolver=mytlschallenge
      - traefik.http.middlewares.n8n.headers.SSLRedirect=true
      - traefik.http.middlewares.n8n.headers.STSSeconds=315360000
      - traefik.http.middlewares.n8n.headers.browserXSSFilter=true
      - traefik.http.middlewares.n8n.headers.contentTypeNosniff=true
      - traefik.http.middlewares.n8n.headers.forceSTSHeader=true
      - traefik.http.middlewares.n8n.headers.SSLHost=${DOMAIN_NAME}
      - traefik.http.middlewares.n8n.headers.STSIncludeSubdomains=true
      - traefik.http.middlewares.n8n.headers.STSPreload=true
      - traefik.http.routers.n8n.middlewares=n8n@docker
      - traefik.http.services.n8n.loadbalancer.server.port=5678
    networks: [ web ]

  n8n-worker:
    image: docker.n8n.io/n8nio/n8n
    container_name: n8n-worker
    restart: always
    command: worker
    environment:
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: 6379
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${N8N_DB_NAME}
      DB_POSTGRESDB_USER: ${N8N_DB_USER}
      DB_POSTGRESDB_PASSWORD: ${N8N_DB_PASS}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
    depends_on:
      - redis
      - postgres
    networks: [ web ]

  evolution:
    image: evoapicloud/evolution-api
    container_name: evolution-api
    restart: always
    environment:
      AUTHENTICATION_API_KEY: ${EVOLUTION_API_KEY}
      # Banco
      DATABASE_ENABLED: "true"
      DATABASE_PROVIDER: "postgresql"
      DATABASE_CONNECTION_URI: postgresql://${N8N_DB_USER}:${N8N_DB_PASS}@postgres:5432/evolution?schema=public
      DATABASE_CONNECTION_CLIENT_NAME: evolution_v2
      # Cache
      CACHE_REDIS_ENABLED: "true"
      CACHE_REDIS_URI: redis://redis:6379/6
      CACHE_REDIS_PREFIX_KEY: evolution
      CACHE_LOCAL_ENABLED: "false"
      # Manager / WS / CORS
      SERVER_TYPE: https
      SERVER_URL: https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}
      WEBSOCKET_ENABLED: "true"
      CORS_ORIGIN: "*"
    volumes:
      - evolution_store:/evolution/store
      - evolution_instances:/evolution/instances
    depends_on:
      - postgres
      - redis
    labels:
      - traefik.enable=true
      - traefik.http.routers.evolution.rule=Host(`${EVO_SUBDOMAIN}.${DOMAIN_NAME}`)
      - traefik.http.routers.evolution.entrypoints=web,websecure
      - traefik.http.routers.evolution.tls=true
      - traefik.http.routers.evolution.tls.certresolver=mytlschallenge
      - traefik.http.services.evolution.loadbalancer.server.port=8080
    networks: [ web ]

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    labels:
      - traefik.enable=true
      - traefik.http.routers.portainer.rule=Host(`${PORTAINER_HOST}`)
      - traefik.http.routers.portainer.entrypoints=web,websecure
      - traefik.http.routers.portainer.tls=true
      - traefik.http.routers.portainer.tls.certresolver=mytlschallenge
      - traefik.http.services.portainer.loadbalancer.server.port=9000
    networks: [ web ]

volumes:
  traefik_data:
  redis_data:
  pg_data:
  n8n_data:
  portainer_data:
  evolution_store:
  evolution_instances:

networks:
  web:
    driver: bridge
YAML
  echo "✅ docker-compose.yml criado."
fi

# opcional: override de middleware apikey (comentado por padrão)
if [[ ! -f docker-compose.override.yml ]]; then
cat > docker-compose.override.yml <<'YAML'
# Descomente as 3 linhas de middleware abaixo caso o Manager acuse "Unauthorized".
services:
  evolution:
    labels:
      # - traefik.http.middlewares.evo-apikey.headers.customrequestheaders.apikey=${EVOLUTION_API_KEY}
      # - traefik.http.routers.evolution.middlewares=evo-apikey@docker
      # (mantenha também as labels do router definidas no compose principal)
YAML
  echo "✅ docker-compose.override.yml criado (opcional)."
fi

# === sobe serviços base ===
echo "== Subindo Traefik =="
docker compose up -d traefik

echo "== Subindo Postgres + Redis =="
docker compose up -d postgres redis

# === cria DB evolution (se necessário) ===
echo "== Criando DB 'evolution' se não existir =="
export PGPASSWORD="${N8N_DB_PASS}"
docker compose exec -T postgres psql -U "${N8N_DB_USER}" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='evolution'" | grep -q 1 \
  || docker compose exec -T postgres psql -U "${N8N_DB_USER}" -d postgres -c "CREATE DATABASE evolution OWNER ${N8N_DB_USER};"

# === sobe apps ===
echo "== Subindo n8n / worker / Portainer =="
docker compose up -d n8n n8n-worker portainer

echo "== Subindo Evolution =="
docker compose up -d evolution

# === prints úteis ===
echo
echo "🎉 Concluído!"
echo "Traefik:   https://${TRAEFIK_HOST}   (user: ${TRAEFIK_USER} / pass: ${TRAEFIK_PASS})"
echo "Portainer: https://${PORTAINER_HOST}"
echo "n8n:       https://${SUBDOMAIN}.${DOMAIN_NAME}"
echo "Evolution: https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}  (manager em /manager)"
