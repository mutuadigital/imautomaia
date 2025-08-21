#!/usr/bin/env bash
# Hostinger/Ubuntu Quick Installer — n8n + Evolution + Traefik + Portainer (v4.0)
# - Instala Docker/Compose (se faltar)
# - Gera .env interativo (com rotação de chaves)
# - Cria docker-compose.yml e override
# - Configura Traefik com HTTPS (ACME) e Basic Auth no dashboard
# - Sobe n8n (queue) + Redis + Postgres + Evolution + Portainer
# - Cria DB 'evolution' no Postgres
# - Gera script de healthcheck

set -Eeuo pipefail

TITLE1="INSTALADOR MUTUA.DIGITAL IMERSÃO: AUTOMAÇÃO & IA NA PRÁTICA"
TITLE2="FERRAMENTAS: Evolution + Portainer + Traefik (V4.0)"
COMPOSE_DIR="/root"
ENV_FILE="${COMPOSE_DIR}/.env"
BASE_COMPOSE="${COMPOSE_DIR}/docker-compose.yml"
OVERRIDE_COMPOSE="${COMPOSE_DIR}/docker-compose.override.yml"
TRAEFIK_DIR="${COMPOSE_DIR}/traefik"
TRAEFIK_HTPASSWD="${TRAEFIK_DIR}/htpasswd"
HEALTH="${COMPOSE_DIR}/hostinger-healthcheck.sh"

echo "============================================================"
echo " ${TITLE1}"
echo " ${TITLE2}"
echo "============================================================"
echo

cd "${COMPOSE_DIR}"

# ---------------- helpers ----------------
ask() {
  local prompt="$1"; local default="${2:-}"
  if [[ -n "${default}" ]]; then
    read -r -p "${prompt} [${default}]: " REPLY || true
    echo "${REPLY:-$default}"
  else
    read -r -p "${prompt}: " REPLY || true
    echo "${REPLY}"
  fi
}

confirm() { # yes by default
  local prompt="${1:-Confirma?}"; local def="${2:-Y}"
  local ans; ans="$(ask "${prompt}" "${def}")"
  [[ "${ans}" =~ ^(Y|y)$ ]]
}

rand_hex() { openssl rand -hex 16; }
rand_b32() { head -c 32 /dev/urandom | base64 | tr -d '=+/[:space:]' | cut -c1-32; }

ensure_pkg() {
  if ! command -v "$1" >/dev/null 2>&1; then
    apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y "$1"
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Instalando Docker..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
      $(. /etc/os-release; echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  fi
  if ! docker compose version >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y docker-compose-plugin
  fi
}

public_ip() {
  curl -fsS https://api.ipify.org || curl -fsS ifconfig.me || dig +short myip.opendns.com @resolver1.opendns.com || echo "desconhecido"
}

# --------------- pré-requisitos ---------------
ensure_pkg curl
ensure_pkg jq
ensure_pkg openssl
ensure_pkg apache2-utils   # htpasswd
ensure_docker

# --------------- .env wizard ---------------
touch "${ENV_FILE}" 2>/dev/null || true
source "${ENV_FILE}" 2>/dev/null || true

# defaults
DOMAIN_NAME_DEFAULT="${DOMAIN_NAME:-imautomaia.com.br}"
SUBDOMAIN_DEFAULT="${SUBDOMAIN:-n8n}"
EVO_SUB_DEFAULT="${EVO_SUBDOMAIN:-wa}"
TZ_DEFAULT="${GENERIC_TIMEZONE:-America/Sao_Paulo}"
SSL_EMAIL_DEFAULT="${SSL_EMAIL:-you@example.com}"
PORTAINER_HOST_DEFAULT="${PORTAINER_HOST:-portainer.${DOMAIN_NAME_DEFAULT}}"
TRAEFIK_HOST_DEFAULT="${TRAEFIK_HOST:-traefik.${DOMAIN_NAME_DEFAULT}}"
ACME_CHALLENGE_DEFAULT="${ACME_CHALLENGE:-http}"  # http|tls|dns
CF_DNS_API_TOKEN_DEFAULT="${CF_DNS_API_TOKEN:-}"
EVOKEY_DEFAULT="${EVOLUTION_API_KEY:-}"
N8N_ENC_DEFAULT="${N8N_ENCRYPTION_KEY:-}"
N8N_DB_USER_DEFAULT="${N8N_DB_USER:-n8n}"
N8N_DB_PASS_DEFAULT="${N8N_DB_PASS:-$(rand_hex)}"
N8N_DB_NAME_DEFAULT="${N8N_DB_NAME:-n8ndb}"
TRAEFIK_USER_DEFAULT="${TRAEFIK_USER:-admin}"
TRAEFIK_PASS_DEFAULT="${TRAEFIK_PASS:-$(rand_hex)}"

echo "== Configuração dos domínios, chaves e credenciais =="
if confirm "Deseja revisar/atualizar as variáveis do .env? (Y/n)" "Y"; then
  DOMAIN_NAME="$(ask 'Domínio raiz (ex.: imautomaia.com.br)' "${DOMAIN_NAME_DEFAULT}")"
  SUBDOMAIN="$(ask 'Subdomínio do n8n (ex.: n8n)' "${SUBDOMAIN_DEFAULT}")"
  EVO_SUBDOMAIN="$(ask 'Subdomínio da Evolution (ex.: wa)' "${EVO_SUB_DEFAULT}")"
  GENERIC_TIMEZONE="$(ask 'Timezone (ex.: America/Sao_Paulo)' "${TZ_DEFAULT}")"
  SSL_EMAIL="$(ask 'Email para certificados (Let’s Encrypt)' "${SSL_EMAIL_DEFAULT}")"

  # Portainer e Traefik expostos?
  if confirm "Expor Portainer por domínio? (${PORTAINER_HOST_DEFAULT}) (Y/n)" "Y"; then
    PORTAINER_HOST="$(ask 'Host do Portainer' "${PORTAINER_HOST_DEFAULT}")"
  else
    PORTAINER_HOST=""
  fi
  if confirm "Expor Traefik dashboard por domínio? (${TRAEFIK_HOST_DEFAULT}) (Y/n)" "Y"; then
    TRAEFIK_HOST="$(ask 'Host do Traefik' "${TRAEFIK_HOST_DEFAULT}")"
  else
    TRAEFIK_HOST=""
  fi

  # Método ACME
  ACME_CHALLENGE="$(ask 'Método ACME (http|tls|dns[cloudflare])' "${ACME_CHALLENGE_DEFAULT}")"
  CF_DNS_API_TOKEN="${CF_DNS_API_TOKEN_DEFAULT}"
  if [[ "${ACME_CHALLENGE}" == "dns" ]]; then
    CF_DNS_API_TOKEN="$(ask 'Cloudflare CF_DNS_API_TOKEN (DNS Edit+Read)' "${CF_DNS_API_TOKEN_DEFAULT}")"
  fi

  # n8n DB e encryption key
  N8N_DB_USER="$(ask 'Postgres USER (n8n)' "${N8N_DB_USER_DEFAULT}")"
  N8N_DB_PASS="$(ask 'Postgres PASS (auto se vazio)' "${N8N_DB_PASS_DEFAULT}")"
  N8N_DB_NAME="$(ask 'Postgres DB (n8ndb)' "${N8N_DB_NAME_DEFAULT}")"
  if [[ -z "${N8N_ENC_DEFAULT}" ]] || confirm "Rotacionar N8N_ENCRYPTION_KEY? (n/N)" "n"; then
    N8N_ENCRYPTION_KEY="$(rand_b32)"
  else
    N8N_ENCRYPTION_KEY="${N8N_ENC_DEFAULT}"
  fi

  # Evolution API Key (global)
  if [[ -z "${EVOKEY_DEFAULT}" ]] || confirm "Rotacionar EVOLUTION_API_KEY? (n/N)" "n"; then
    EVOLUTION_API_KEY="$(rand_hex)"
  else
    EVOLUTION_API_KEY="${EVOKEY_DEFAULT}"
  fi

  # Traefik Basic Auth
  TRAEFIK_USER="$(ask 'Usuário do painel Traefik' "${TRAEFIK_USER_DEFAULT}")"
  TRAEFIK_PASS="$(ask 'Senha do painel Traefik (auto se vazio)' "${TRAEFIK_PASS_DEFAULT}")"
  [[ -z "${TRAEFIK_PASS}" ]] && TRAEFIK_PASS="$(rand_hex)"

  cat > "${ENV_FILE}" <<EOF
DOMAIN_NAME=${DOMAIN_NAME}
SUBDOMAIN=${SUBDOMAIN}
EVO_SUBDOMAIN=${EVO_SUBDOMAIN}
GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
SSL_EMAIL=${SSL_EMAIL}
PORTAINER_HOST=${PORTAINER_HOST}
TRAEFIK_HOST=${TRAEFIK_HOST}
ACME_CHALLENGE=${ACME_CHALLENGE}
CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}
EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
N8N_DB_USER=${N8N_DB_USER}
N8N_DB_PASS=${N8N_DB_PASS}
N8N_DB_NAME=${N8N_DB_NAME}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
TRAEFIK_USER=${TRAEFIK_USER}
TRAEFIK_PASS=${TRAEFIK_PASS}
EOF
  echo "✅ .env atualizado em: ${ENV_FILE}"
else
  echo "Usando valores existentes de ${ENV_FILE}"
fi

source "${ENV_FILE}"

echo
echo "Resumo .env (chaves ocultas):"
echo "DOMAIN_NAME=${DOMAIN_NAME}"
echo "SUBDOMAIN=${SUBDOMAIN}"
echo "EVO_SUBDOMAIN=${EVO_SUBDOMAIN}"
echo "GENERIC_TIMEZONE=${GENERIC_TIMEZONE}"
echo "SSL_EMAIL=${SSL_EMAIL}"
echo "PORTAINER_HOST=${PORTAINER_HOST:-<não exposto>}"
echo "TRAEFIK_HOST=${TRAEFIK_HOST:-<não exposto>}"
echo "ACME_CHALLENGE=${ACME_CHALLENGE}"
echo "N8N_DB_USER=${N8N_DB_USER}  N8N_DB_NAME=${N8N_DB_NAME}"
echo "EVOLUTION_API_KEY=***  N8N_ENCRYPTION_KEY=***  TRAEFIK_PASS=***"
echo

# --------------- Traefik dir & htpasswd ---------------
mkdir -p "${TRAEFIK_DIR}"
# arquivo de usuários para Basic Auth (bcrypt)
HTLINE="$(htpasswd -nbB "${TRAEFIK_USER}" "${TRAEFIK_PASS}")"
echo "${HTLINE}" > "${TRAEFIK_HTPASSWD}"
chmod 600 "${TRAEFIK_HTPASSWD}"

# --------------- Compose base (SEM 'version:' para evitar warning) ---------------
cat > "${BASE_COMPOSE}" <<'YAML'
services:

  traefik:
    image: traefik:latest
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
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_data:/letsencrypt
      - ./traefik/htpasswd:/etc/traefik/htpasswd:ro
    labels:
      - traefik.enable=true
      # Dashboard protegido por Basic Auth
      - traefik.http.routers.traefik.rule=Host(`${TRAEFIK_HOST}`)
      - traefik.http.routers.traefik.entrypoints=web,websecure
      - traefik.http.routers.traefik.tls=true
      - traefik.http.routers.traefik.tls.certresolver=mytlschallenge
      - traefik.http.routers.traefik.service=api@internal
      - traefik.http.middlewares.traefik-auth.basicauth.usersfile=/etc/traefik/htpasswd
      - traefik.http.routers.traefik.middlewares=traefik-auth@docker
    networks: [ web ]

  # Redis para n8n queue e Evolution cache
  redis:
    image: redis:6
    container_name: redis
    restart: always
    volumes:
      - redis_data:/data
    networks: [ web ]

  # Postgres compartilhado (n8n + evolution)
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

  # n8n (principal)
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

  # n8n worker (queue)
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

  # Evolution API v2
  evolution:
    image: atendai/evolution-api:latest
    container_name: evolution-api
    restart: always
    environment:
      AUTHENTICATION_API_KEY: ${EVOLUTION_API_KEY}
      # Banco (persistência)
      DATABASE_ENABLED: "true"
      DATABASE_PROVIDER: "postgresql"
      DATABASE_CONNECTION_URI: postgresql://${N8N_DB_USER}:${N8N_DB_PASS}@postgres:5432/evolution?schema=public
      DATABASE_CONNECTION_CLIENT_NAME: evolution_v2
      # Cache (Redis)
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

  # Portainer (opcional, exposto se HOST definido)
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

# --------------- Compose override para ACME variants ---------------
# Monta flags ACME específicas
ACME_FLAGS=""
EXTRA_ENV=""
if [[ "${ACME_CHALLENGE}" == "tls" ]]; then
  ACME_FLAGS=$'      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"\n      - "--log.level=DEBUG"'
elif [[ "${ACME_CHALLENGE}" == "dns" ]]; then
  ACME_FLAGS=$'      - "--certificatesresolvers.mytlschallenge.acme.dnschallenge=true"\n      - "--certificatesresolvers.mytlschallenge.acme.dnschallenge.provider=cloudflare"\n      - "--certificatesresolvers.mytlschallenge.acme.dnschallenge.delaybeforecheck=10"\n      - "--log.level=DEBUG"'
  EXTRA_ENV=$'    environment:\n      - CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}\n'
else
  # http-01
  ACME_FLAGS=$'      - "--certificatesresolvers.mytlschallenge.acme.httpchallenge=true"\n      - "--certificatesresolvers.mytlschallenge.acme.httpchallenge.entrypoint=web"\n      - "--log.level=DEBUG"'
fi

cat > "${OVERRIDE_COMPOSE}" <<YAML
services:
  traefik:
    command:
${ACME_FLAGS}
${EXTRA_ENV}
YAML

echo "✅ docker-compose.yml e docker-compose.override.yml prontos."
echo

# --------------- Rede e permissões ---------------
docker network inspect web >/dev/null 2>&1 || docker network create web
# acme.json dentro do volume nomeado será criado por Traefik; só garantimos perms na primeira execução via container.

# --------------- Subida dos serviços (ordem) ---------------
echo "Baixando/atualizando imagens..."
docker compose pull --ignore-buildable

echo "Subindo Traefik + Portainer..."
docker compose up -d traefik portainer

echo "Subindo Postgres + Redis..."
docker compose up -d postgres redis

echo "Criando base 'evolution' no Postgres (se ainda não existir)..."
docker compose exec -T -e PGPASSWORD="${N8N_DB_PASS}" postgres \
  psql -U "${N8N_DB_USER}" -d postgres -c "CREATE DATABASE evolution;" 2>/dev/null || true

echo "Subindo n8n + n8n-worker + Evolution..."
docker compose up -d n8n n8n-worker evolution

# --------------- Healthcheck script ---------------
cat > "${HEALTH}" <<'HSH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /root/.env 2>/dev/null || true

N8N="https://${SUBDOMAIN}.${DOMAIN_NAME}/rest/healthz"
EVO="https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/"
EVO_INST="https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/instance/fetchInstances"
PRT="https://${PORTAINER_HOST}"
TRF="https://${TRAEFIK_HOST}"

echo "=== Healthcheck Stack ==="
echo "n8n:       ${N8N}"
echo "evolution: ${EVO_INST}"
echo "portainer: ${PRT}"
echo "traefik:   ${TRF}"
echo

# Porta 80 (traefik)
if curl -fsS "http://${DOMAIN_NAME}" >/dev/null 2>&1; then
  echo "✅ Traefik (porta 80) OK"
else
  echo "❌ Traefik porta 80 FAIL"
  docker logs traefik --tail=200 || true
fi

# n8n
if curl -fsS "${N8N}" >/dev/null 2>&1; then
  echo "✅ n8n OK → ${N8N}"
else
  echo "❌ n8n FAIL → ${N8N}"
  echo "   Logs: docker logs n8n --tail=200 || true"
  echo "   Restart: docker restart n8n"
  echo "   Recreate: docker compose up -d --no-deps --force-recreate n8n"
fi

# evolution (usa apikey)
if curl -fsS "${EVO_INST}" -H "apikey: ${EVOLUTION_API_KEY}" >/dev/null 2>&1; then
  echo "✅ evolution-api OK → ${EVO_INST}"
else
  echo "❌ evolution-api FAIL → ${EVO_INST}"
  echo "   Root: curl -sk ${EVO} | head -n1"
  echo "   Logs: docker logs evolution-api --tail=200"
  echo "   Restart: docker restart evolution-api"
  echo "   Recreate: docker compose up -d --no-deps --force-recreate evolution"
fi

# portainer
if [[ -n "${PORTAINER_HOST}" ]] && curl -fsS "${PRT}" >/dev/null 2>&1; then
  echo "✅ portainer OK → ${PRT}"
elif [[ -n "${PORTAINER_HOST}" ]]; then
  echo "❌ portainer FAIL → ${PRT}"
  echo "   Logs: docker logs portainer --tail=200"
fi

# traefik dash
if [[ -n "${TRAEFIK_HOST}" ]] && curl -fsS "${TRF}" >/dev/null 2>&1; then
  echo "✅ traefik OK → ${TRF}"
elif [[ -n "${TRAEFIK_HOST}" ]]; then
  echo "❌ traefik FAIL → ${TRF}"
  echo "   Logs: docker logs traefik --tail=200"
fi

echo "=== Done ==="
HSH
chmod +x "${HEALTH}"
echo "✅ Healthcheck criado: ${HEALTH}"
echo

# --------------- Dicas finais ---------------
IP="$(public_ip)"
echo "DNS → aponte estes registros A para ${IP}:"
echo " - ${SUBDOMAIN}.${DOMAIN_NAME}"
echo " - ${EVO_SUBDOMAIN}.${DOMAIN_NAME}"
[[ -n "${PORTAINER_HOST}" ]] && echo " - ${PORTAINER_HOST}"
[[ -n "${TRAEFIK_HOST}"  ]] && echo " - ${TRAEFIK_HOST}"
echo
echo "Após apontar DNS, visite em HTTPS para disparar o ACME:"
echo " - n8n:       https://${SUBDOMAIN}.${DOMAIN_NAME}"
echo " - Evolution: https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}"
[[ -n "${PORTAINER_HOST}" ]] && echo " - Portainer: https://${PORTAINER_HOST}"
[[ -n "${TRAEFIK_HOST}"  ]] && echo " - Traefik:   https://${TRAEFIK_HOST} (login: ${TRAEFIK_USER})"
echo
echo "Ver ACME/certificados (debug):"
echo " docker logs -f traefik | grep -i -E 'acme|certificate|challenge|lego'"
echo
echo "Testes Evolution (instâncias):"
echo " curl -s https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/instance/fetchInstances -H \"apikey: \$(. ${ENV_FILE}; echo \\\"\$EVOLUTION_API_KEY\\\")\" | jq ."
echo
echo "Healthcheck rápido:"
echo " ${HEALTH}"
echo
echo "Concluído. 🚀"
