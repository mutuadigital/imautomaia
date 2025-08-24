#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# install.sh - Traefik v3 + Postgres + Redis + n8n (+ worker) + Evolution API + Portainer
# Dashboards SEMPRE ativos:
#   - Traefik (api@internal) com Basic Auth
#   - Portainer com admin via --admin-password-file
#
# Este instalador:
#   - Reescreve o docker-compose.yml (faz backup do antigo)
#   - Coloca TODOS os serviços na mesma rede "web"
#   - Corrige o problema do n8n ("Command start not found") com:
#       * N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
#       * fix de permissões no volume do n8n (se já existir)
# -----------------------------------------------------------------------------
set -euo pipefail

# ========================= util =========================
randhex() { openssl rand -hex "${1:-24}"; }
ask() {
  local prompt="$1" default="${2:-}" var
  if [[ -n "$default" ]]; then read -r -p "$prompt [$default]: " var || true; echo "${var:-$default}";
  else read -r -p "$prompt: " var || true; echo "$var"; fi
}
require() { command -v "$1" >/dev/null 2>&1 || { echo "Falta o comando '$1'."; exit 1; }; }
bcrypt_hash() {
  docker run --rm alpine:3 sh -lc 'apk add --no-cache apache2-utils >/dev/null && htpasswd -nbB admin "$1"' -- "$1" | cut -d: -f2-
}

# ===================== pré-checagens ====================
require docker
require openssl
require curl

# ====================== perguntas =======================
echo "== Configuração =="
DOMAIN_NAME="$(ask "Domínio raiz (ex.: imautomaia.com.br)" "${DOMAIN_NAME:-mutua.digital}")"
SUBDOMAIN="$(ask "Subdomínio do n8n" "${SUBDOMAIN:-n8n}")"
EVO_SUBDOMAIN="$(ask "Subdomínio da Evolution" "${EVO_SUBDOMAIN:-wa}")"
GENERIC_TIMEZONE="$(ask "Timezone" "${GENERIC_TIMEZONE:-America/Sao_Paulo}")"
SSL_EMAIL="$(ask "Email para Let's Encrypt" "${SSL_EMAIL:-sourenato@gmail.com}")"

PORTAINER_HOST="$(ask "Host do Portainer (FQDN)" "${PORTAINER_HOST:-portainer.${DOMAIN_NAME}}")"
TRAEFIK_HOST="$(ask "Host do Traefik (FQDN)" "${TRAEFIK_HOST:-traefik.${DOMAIN_NAME}}")"

N8N_DB_USER="$(ask "Postgres USER (n8n/evolution)" "${N8N_DB_USER:-n8n}")"
N8N_DB_PASS_DEFAULT="$(randhex 16)"
N8N_DB_PASS="$(ask "Postgres PASS (auto se vazio)" "${N8N_DB_PASS:-$N8N_DB_PASS_DEFAULT}")"
N8N_DB_NAME="$(ask "Postgres DB (n8n)" "${N8N_DB_NAME:-n8ndb}")"

EVOLUTION_API_KEY_DEFAULT="$(randhex 16)"
EVOLUTION_API_KEY="$(ask "Evolution API Global Key (auto se vazio)" "${EVOLUTION_API_KEY:-$EVOLUTION_API_KEY_DEFAULT}")"

TRAEFIK_USER="$(ask "Usuário do painel Traefik" "${TRAEFIK_USER:-admin}")"
read -r -s -p "Senha do painel Traefik (deixe vazio p/ gerar): " TRAEFIK_PASS || true; echo
[[ -z "${TRAEFIK_PASS:-}" ]] && TRAEFIK_PASS="$(randhex 12)"
HTPASS_HASH="$(openssl passwd -apr1 "$TRAEFIK_PASS")"

read -r -s -p "Senha do Portainer (admin) (deixe vazio p/ gerar): " PORTAINER_ADMIN_PASS || true; echo
[[ -z "${PORTAINER_ADMIN_PASS:-}" ]] && PORTAINER_ADMIN_PASS="$(randhex 12)"
PORTAINER_ADMIN_HASH="$(bcrypt_hash "$PORTAINER_ADMIN_PASS")"

N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(randhex 24)}"

# ======================= grava .env =====================
cat > .env <<EOF
DOMAIN_NAME=${DOMAIN_NAME}
SUBDOMAIN=${SUBDOMAIN}
EVO_SUBDOMAIN=${EVO_SUBDOMAIN}
GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
SSL_EMAIL=${SSL_EMAIL}
PORTAINER_HOST=${PORTAINER_HOST}
TRAEFIK_HOST=${TRAEFIK_HOST}

# Postgres
N8N_DB_USER=${N8N_DB_USER}
N8N_DB_PASS=${N8N_DB_PASS}
N8N_DB_NAME=${N8N_DB_NAME}

# n8n
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

# Evolution
EVOLUTION_API_KEY=${EVOLUTION_API_KEY}

# Portainer
PORTAINER_ADMIN_HASH=${PORTAINER_ADMIN_HASH}
EOF
echo "✅ .env escrito."

# ======== arquivos auxiliares (auth/secret) ============
mkdir -p traefik portainer

# Traefik BasicAuth
echo "${TRAEFIK_USER}:${HTPASS_HASH}" > traefik/htpasswd
chmod 640 traefik/htpasswd
echo "✅ htpasswd criado para painel Traefik (${TRAEFIK_USER})."

# Portainer admin password (hash bcrypt) via arquivo
printf '%s\n' "${PORTAINER_ADMIN_HASH}" > portainer/admin_password
chmod 600 portainer/admin_password
echo "✅ arquivo de senha do Portainer criado."

# ============ docker-compose.yml (sempre novo) =========
if [[ -f docker-compose.yml ]]; then
  cp docker-compose.yml "docker-compose.yml.bak.$(date +%F-%H%M%S)"
  echo "ℹ️ Backup do docker-compose.yml criado."
fi

cat > docker-compose.yml <<'YAML'
services:

  traefik:
    image: traefik:v3.5
    container_name: traefik
    restart: always
    ports: ["80:80", "443:443"]
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
      - "--certificatesresolvers.mytlschallenge.acme.email=\${SSL_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.mytlschallenge.acme.httpchallenge.entrypoint=web"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_data:/letsencrypt
      - ./traefik/htpasswd:/etc/traefik/htpasswd:ro
    labels:
      - traefik.enable=true
      - traefik.http.routers.traefik.rule=Host(`\${TRAEFIK_HOST}`)
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
    volumes: [ "redis_data:/data" ]
    networks: [ web ]

  postgres:
    image: postgres:15
    container_name: postgres
    restart: always
    environment:
      POSTGRES_USER: \${N8N_DB_USER}
      POSTGRES_PASSWORD: \${N8N_DB_PASS}
      POSTGRES_DB: \${N8N_DB_NAME}
    volumes: [ "pg_data:/var/lib/postgresql/data" ]
    networks: [ web ]

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: always
    environment:
      # Base URL
      N8N_HOST: \${SUBDOMAIN}.\${DOMAIN_NAME}
      N8N_PROTOCOL: https
      N8N_PORT: 5678
      WEBHOOK_URL: https://\${SUBDOMAIN}.\${DOMAIN_NAME}/

      # DB (Postgres)
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: \${N8N_DB_NAME}
      DB_POSTGRESDB_USER: \${N8N_DB_USER}
      DB_POSTGRESDB_PASSWORD: \${N8N_DB_PASS}

      # Queue (Redis)
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: 6379

      # Segurança/Permissões
      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: "true"
      GENERIC_TIMEZONE: \${GENERIC_TIMEZONE}
      N8N_ENCRYPTION_KEY: \${N8N_ENCRYPTION_KEY}
      N8N_DIAGNOSTICS_ENABLED: "false"
    volumes:
      - n8n_data:/home/node/.n8n
      - /local-files:/files
    depends_on: [ postgres, redis ]
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(`\${SUBDOMAIN}.\${DOMAIN_NAME}`)
      - traefik.http.routers.n8n.entrypoints=web,websecure
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.tls.certresolver=mytlschallenge
      - traefik.http.middlewares.n8n.headers.SSLRedirect=true
      - traefik.http.middlewares.n8n.headers.STSSeconds=315360000
      - traefik.http.middlewares.n8n.headers.browserXSSFilter=true
      - traefik.http.middlewares.n8n.headers.contentTypeNosniff=true
      - traefik.http.middlewares.n8n.headers.forceSTSHeader=true
      - traefik.http.middlewares.n8n.headers.SSLHost=\${DOMAIN_NAME}
      - traefik.http.middlewares.n8n.headers.STSIncludeSubdomains=true
      - traefik.http.middlewares.n8n.headers.STSPreload=true
      - traefik.http.routers.n8n.middlewares=n8n@docker
      - traefik.http.services.n8n.loadbalancer.server.port=5678
    networks: [ web ]

  n8n-worker:
    image: n8nio/n8n:latest
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
      DB_POSTGRESDB_DATABASE: \${N8N_DB_NAME}
      DB_POSTGRESDB_USER: \${N8N_DB_USER}
      DB_POSTGRESDB_PASSWORD: \${N8N_DB_PASS}
      N8N_ENCRYPTION_KEY: \${N8N_ENCRYPTION_KEY}
      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: "true"
    depends_on: [ redis, postgres ]
    networks: [ web ]

  evolution:
    image: evoapicloud/evolution-api:v2.3.1
    container_name: evolution-api
    restart: always
    environment:
      TZ: \${GENERIC_TIMEZONE}
      LOG_LEVEL: debug
      AUTHENTICATION_API_KEY: \${EVOLUTION_API_KEY}

      # Banco (persistência)
      DATABASE_ENABLED: "true"
      DATABASE_PROVIDER: "postgresql"
      DATABASE_CONNECTION_URI: postgresql://\${N8N_DB_USER}:\${N8N_DB_PASS}@postgres:5432/evolution?schema=public
      DATABASE_CONNECTION_CLIENT_NAME: evolution_v2

      # Cache (Redis)
      CACHE_REDIS_ENABLED: "true"
      CACHE_REDIS_URI: redis://redis:6379/6
      CACHE_REDIS_PREFIX_KEY: evolution
      CACHE_LOCAL_ENABLED: "false"

      # HTTP interno (TLS só no Traefik)
      SERVER_TYPE: "http"
      SERVER_SSL: "false"
      HTTPS: "false"

      # Externo (QR/links) + WS/CORS
      SERVER_URL: https://\${EVO_SUBDOMAIN}.\${DOMAIN_NAME}
      WEBSOCKET_ENABLED: "true"
      CORS_ORIGIN: "*"
      WHITELIST_ORIGINS: "https://\${EVO_SUBDOMAIN}.\${DOMAIN_NAME},https://\${SUBDOMAIN}.\${DOMAIN_NAME},https://chat.\${DOMAIN_NAME}"

      NODE_OPTIONS: "--dns-result-order=ipv4first"
    volumes:
      - evolution_store:/evolution/store
      - evolution_instances:/evolution/instances
    depends_on: [ postgres, redis ]
    labels:
      - traefik.enable=true
      - traefik.http.routers.evolution.rule=Host(`\${EVO_SUBDOMAIN}.\${DOMAIN_NAME}`)
      - traefik.http.routers.evolution.entrypoints=web,websecure
      - traefik.http.routers.evolution.tls=true
      - traefik.http.routers.evolution.tls.certresolver=mytlschallenge
      - traefik.http.services.evolution.loadbalancer.server.port=8080
    networks: [ web ]

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    command:
      - --admin-password-file=/run/secrets/portainer_admin_password
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
      - ./portainer/admin_password:/run/secrets/portainer_admin_password:ro
    labels:
      - traefik.enable=true
      - traefik.http.routers.portainer.rule=Host(`\${PORTAINER_HOST}`)
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

echo "✅ docker-compose.yml escrito (novo)."

# =================== sobe base (Traefik/DB) =============
echo "== Subindo Traefik =="
docker compose up -d traefik

echo "== Subindo Postgres + Redis =="
docker compose up -d postgres redis

# aguarda Postgres responder antes de criar DB evolution
echo "== Aguardando Postgres responder =="
export PGPASSWORD="${N8N_DB_PASS}"
for i in {1..30}; do
  if docker compose exec -T postgres psql -U "${N8N_DB_USER}" -d postgres -c "select 1" >/dev/null 2>&1; then break; fi
  sleep 2
done

echo "== Criando DB 'evolution' se não existir =="
docker compose exec -T postgres psql -U "${N8N_DB_USER}" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='evolution'" | grep -q 1 \
  || docker compose exec -T postgres psql -U "${N8N_DB_USER}" -d postgres -c "CREATE DATABASE evolution OWNER ${N8N_DB_USER};"

# ======= fix preventivo de permissões do volume n8n =====
# (Resolve "Permissions 0644 ... too wide" + "Command \"start\" not found")
VOLUME_N8N="$(docker volume ls --format '{{.Name}}' | grep '_n8n_data$' | head -n1 || true)"
if [[ -n "${VOLUME_N8N}" ]]; then
  docker run --rm -v "${VOLUME_N8N}":/data alpine:3 sh -lc '
    set -e
    mkdir -p /data
    chmod 700 /data || true
    if [ -f /data/config ]; then chmod 600 /data/config || true; fi
  ' || true
fi

# =================== sobe apps ==========================
echo "== Subindo n8n / worker / Portainer =="
docker compose up -d n8n n8n-worker portainer

echo "== Subindo Evolution =="
docker compose up -d evolution || true

# =================== Healthcheck ========================
HC=/usr/local/bin/stack-health
cat > "$HC" <<'BASH'
#!/usr/bin/env bash
set -o pipefail
ENV_FILE=""; for f in "./.env" "/root/.env"; do [[ -f "$f" ]] && ENV_FILE="$f" && break; done
[[ -n "$ENV_FILE" ]] && source "$ENV_FILE"
DOMAIN="${DOMAIN_NAME:-example.com}"
N8N_HOST="${SUBDOMAIN}.${DOMAIN}"
EVO_HOST="${EVO_SUBDOMAIN}.${DOMAIN}"
PORTAINER_FQDN="${PORTAINER_HOST:-portainer.${DOMAIN}}"
TRAEFIK_FQDN="${TRAEFIK_HOST:-traefik.${DOMAIN}}"
KEY="${EVOLUTION_API_KEY:-}"
ok(){ printf "✅ %s\n" "$*"; } ; fail(){ printf "❌ %s\n" "$*"; }
code(){ curl -skL -o /dev/null -w '%{http_code}' "$1"; }

echo "=== Healthcheck Stack ==="
docker ps --format ' - {{.Names}}: {{.Status}}' | egrep 'traefik|postgres|redis|n8n|evolution|portainer' || true
echo

c=$(code "https://${TRAEFIK_FQDN}") ; [[ "$c" =~ ^(200|301|302|401|403|404)$ ]] && ok "traefik (${c})" || fail "traefik (${c})"
c=$(code "https://${PORTAINER_FQDN}") ; [[ "$c" =~ ^(200|301|302|401|403)$ ]] && ok "portainer (${c})" || fail "portainer (${c})"

c=$(code "https://${N8N_HOST}/healthz"); [[ "$c" == "200" ]] || c=$(code "https://${N8N_HOST}/rest/healthz")
[[ "$c" == "200" ]] && ok "n8n (${c})" || fail "n8n (${c})"

c=$(code "https://${EVO_HOST}") ; [[ "$c" =~ ^(200|404)$ ]] && ok "evolution (${c})" || fail "eolution (${c})"
if [[ -n "$KEY" ]]; then
  c=$(curl -sk -H "apikey: $KEY" -o /dev/null -w '%{http_code}' "https://${EVO_HOST}/instance/fetchInstances")
  if [[ "$c" != "200" ]]; then
    c=$(curl -sk -H "apikey: $KEY" -o /dev/null -w '%{http_code}' "https://${EVO_HOST}/api/instance/fetchInstances")
  fi
  if [[ "$c" != "200" ]]; then
    c=$(curl -sk -H "apikey: $KEY" -o /dev/null -w '%{http_code}' "https://${EVO_HOST}/v2/instance/fetchInstances")
  fi
  [[ "$c" == "200" ]] && ok "fetchInstances (${c})" || fail "fetchInstances (${c})"
fi
echo "=== Done ==="
BASH
chmod +x "$HC"
cp "$HC" ./hostinger-healthcheck.sh 2>/dev/null || true
echo "✅ Healthcheck instalado: use 'stack-health' (ou ./hostinger-healthcheck.sh)"

# =================== prints finais ======================
echo
echo "🎉 Concluído!"
echo "Traefik:   https://${TRAEFIK_HOST}   (user: ${TRAEFIK_USER} / pass: ${TRAEFIK_PASS})"
echo "Portainer: https://${PORTAINER_HOST}   (user: admin / pass: ${PORTAINER_ADMIN_PASS})"
echo "n8n:       https://${SUBDOMAIN}.${DOMAIN_NAME}"
echo "Evolution: https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}  (manager em /manager)"
