#!/usr/bin/env bash
set -Eeuo pipefail

TITLE1="INSTALADOR MUTUA.DIGITAL IMERSÃO: AUTOMAÇÃO & IA NA PRÁTICA"
TITLE2="FERRAMENTAS: Evolution + Portainer + Traefik (v3.4)"
COMPOSE_DIR="/root"
BASE_COMPOSE="${COMPOSE_DIR}/docker-compose.yml"
OVERRIDE_COMPOSE="${COMPOSE_DIR}/docker-compose.override.yml"
ENV_FILE="${COMPOSE_DIR}/.env"
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

rand_hex() { openssl rand -hex 16; }

ensure_pkg() {
  if ! command -v "$1" >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y "$1"
  fi
}

parse_pg_env_from_compose() {
  # pega credenciais do serviço postgres do compose base da Hostinger
  # fallback para valores conhecidos caso parsing falhe
  local u p d
  u=$(awk '/postgres:/{flag=1} flag && /POSTGRES_USER:/{print $2; exit}' "${BASE_COMPOSE}" 2>/dev/null || true)
  p=$(awk '/postgres:/{flag=1} flag && /POSTGRES_PASSWORD:/{print $2; exit}' "${BASE_COMPOSE}" 2>/dev/null || true)
  d=$(awk '/postgres:/{flag=1} flag && /POSTGRES_DB:/{print $2; exit}' "${BASE_COMPOSE}" 2>/dev/null || true)
  [[ -z "${u:-}" ]] && u="n8n"
  [[ -z "${p:-}" ]] && p="n8n"
  [[ -z "${d:-}" ]] && d="n8ndb"
  echo "${u};${p};${d}"
}

# --------------- .env wizard ---------------
touch "${ENV_FILE}" 2>/dev/null || true

# carrega defaults existentes
source "${ENV_FILE}" 2>/dev/null || true
DOMAIN_NAME_DEFAULT="${DOMAIN_NAME:-imautomaia.com.br}"
SUBDOMAIN_DEFAULT="${SUBDOMAIN:-n8n}"
TZ_DEFAULT="${GENERIC_TIMEZONE:-America/Sao_Paulo}"
SSL_EMAIL_DEFAULT="${SSL_EMAIL:-you@example.com}"
EVO_SUB_DEFAULT="${EVO_SUBDOMAIN:-wa}"
PORTAINER_HOST_DEFAULT="${PORTAINER_HOST:-portainer.${DOMAIN_NAME_DEFAULT}}"
TRAEFIK_HOST_DEFAULT="${TRAEFIK_HOST:-traefik.${DOMAIN_NAME_DEFAULT}}"
ACME_CHALLENGE_DEFAULT="${ACME_CHALLENGE:-tls}" # tls|http
EVOKEY_DEFAULT="${EVOLUTION_API_KEY:-}"

echo "== Configuração dos domínios e chaves =="
if [[ "$(ask 'Deseja revisar/atualizar as variáveis do .env? (Y/n)' 'Y')" =~ ^(Y|y)$ ]]; then
  DOMAIN_NAME="$(ask 'Domínio raiz (ex.: imautomaia.com.br)' "${DOMAIN_NAME_DEFAULT}")"
  SUBDOMAIN="$(ask 'Subdomínio do n8n (ex.: n8n)' "${SUBDOMAIN_DEFAULT}")"
  GENERIC_TIMEZONE="$(ask 'Timezone (ex.: America/Sao_Paulo)' "${TZ_DEFAULT}")"
  SSL_EMAIL="$(ask 'Email para certificados (Let’s Encrypt)' "${SSL_EMAIL_DEFAULT}")"
  EVO_SUBDOMAIN="$(ask 'Subdomínio da Evolution (ex.: wa)' "${EVO_SUB_DEFAULT}")"

  if [[ "$(ask 'Expor Portainer por domínio? (portainer.DOM)' 'Y')" =~ ^(Y|y)$ ]]; then
    PORTAINER_HOST="$(ask 'Host do Portainer' "${PORTAINER_HOST_DEFAULT}")"
  else
    PORTAINER_HOST=""
  fi

  if [[ "$(ask 'Expor Traefik dashboard por domínio? (traefik.DOM)' 'Y')" =~ ^(Y|y)$ ]]; then
    TRAEFIK_HOST="$(ask 'Host do Traefik' "${TRAEFIK_HOST_DEFAULT}")"
  else
    TRAEFIK_HOST=""
  fi

  ACME_CHALLENGE="$(ask 'Tipo de desafio ACME (tls|http) — use http se Cloudflare Proxied' "${ACME_CHALLENGE_DEFAULT}")"

  if [[ -z "${EVOKEY_DEFAULT}" ]]; then
    EVOLUTION_API_KEY="$(rand_hex)"
    echo "Gerada EVOLUTION_API_KEY (oculta)."
  else
    EVOLUTION_API_KEY="${EVOKEY_DEFAULT}"
    if [[ "$(ask 'Deseja rotacionar a EVOLUTION_API_KEY?' 'n')" =~ ^(Y|y)$ ]]; then
      EVOLUTION_API_KEY="$(rand_hex)"
      echo "Rotacionada EVOLUTION_API_KEY (oculta)."
    fi
  fi

  cat > "${ENV_FILE}" <<EOF
DOMAIN_NAME=${DOMAIN_NAME}
SUBDOMAIN=${SUBDOMAIN}
GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
SSL_EMAIL=${SSL_EMAIL}
EVO_SUBDOMAIN=${EVO_SUBDOMAIN}
PORTAINER_HOST=${PORTAINER_HOST}
TRAEFIK_HOST=${TRAEFIK_HOST}
ACME_CHALLENGE=${ACME_CHALLENGE}
EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
EOF
  echo "✅ .env atualizado em: ${ENV_FILE}"
else
  echo "Usando valores existentes em ${ENV_FILE}"
fi
source "${ENV_FILE}"

echo
echo "Resumo .env (chave oculta):"
echo "DOMAIN_NAME=${DOMAIN_NAME}"
echo "SUBDOMAIN=${SUBDOMAIN}"
echo "GENERIC_TIMEZONE=${GENERIC_TIMEZONE}"
echo "SSL_EMAIL=${SSL_EMAIL}"
echo "EVO_SUBDOMAIN=${EVO_SUBDOMAIN}"
echo "PORTAINER_HOST=${PORTAINER_HOST:-<não exposto>}"
echo "TRAEFIK_HOST=${TRAEFIK_HOST:-<não exposto>}"
echo "ACME_CHALLENGE=${ACME_CHALLENGE}"
echo "EVOLUTION_API_KEY=***oculto***"
echo

# --------------- compose override ---------------
# Seleciona flags do Traefik para ACME
ACME_FLAGS=""
if [[ "${ACME_CHALLENGE}" == "http" ]]; then
  ACME_FLAGS=$(cat <<ACME
      - "--certificatesresolvers.mytlschallenge.acme.httpchallenge=true"
      - "--certificatesresolvers.mytlschallenge.acme.httpchallenge.entrypoint=web"
ACME
)
else
  ACME_FLAGS='      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"'
fi

# Monta CONNECTION_URI do Postgres a partir do compose base
IFS=';' read -r PGUSER PGPASS PGDB <<<"$(parse_pg_env_from_compose)"
PG_URI="postgresql://${PGUSER}:${PGPASS}@postgres:5432/evolution?schema=public"

backup="${OVERRIDE_COMPOSE}.bak.$(date +%s)"
cp -f "${OVERRIDE_COMPOSE}" "${backup}" 2>/dev/null || true
echo "ℹ️  Backup: ${backup}"

# IMPORTANTE: remover 'version:' pra evitar warning do compose v2
cat > "${OVERRIDE_COMPOSE}" <<YAML
services:
  # ----- Evolution API -----
  evolution:
    image: atendai/evolution-api:latest
    container_name: evolution-api
    restart: always
    environment:
      AUTHENTICATION_API_KEY: \${EVOLUTION_API_KEY}
      # Persistência e cache (v2)
      DATABASE_ENABLED: "true"
      DATABASE_PROVIDER: "postgresql"
      DATABASE_CONNECTION_URI: "${PG_URI}"
      CACHE_REDIS_ENABLED: "true"
      CACHE_REDIS_URI: "redis://redis:6379/6"
      CACHE_REDIS_PREFIX_KEY: "evolution"
      CACHE_LOCAL_ENABLED: "false"
    volumes:
      - evolution_store:/evolution/store
      - evolution_instances:/evolution/instances
    networks: [ web ]
    labels:
      - traefik.enable=true
      - traefik.http.routers.evolution.rule=Host(\`\${EVO_SUBDOMAIN}.\${DOMAIN_NAME}\`)
      - traefik.http.routers.evolution.entrypoints=web,websecure
      - traefik.http.routers.evolution.tls=true
      - traefik.http.routers.evolution.tls.certresolver=mytlschallenge
      - traefik.http.services.evolution.loadbalancer.server.port=8080
      - traefik.docker.network=web

  # ----- Portainer -----
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    networks: [ web ]
    labels:
$( [[ -n "${PORTAINER_HOST}" ]] && cat <<'LBL'
      - traefik.enable=true
      - traefik.http.routers.portainer.rule=Host(`${PORTAINER_HOST}`)
      - traefik.http.routers.portainer.entrypoints=web,websecure
      - traefik.http.routers.portainer.tls=true
      - traefik.http.routers.portainer.tls.certresolver=mytlschallenge
      - traefik.http.services.portainer.loadbalancer.server.port=9000
      - traefik.docker.network=web
LBL
)

  # ----- Traefik: complementa serviço existente -----
  traefik:
    networks: [ web ]
    labels:
$( [[ -n "${TRAEFIK_HOST}" ]] && cat <<'LBL'
      - traefik.enable=true
      - traefik.http.routers.traefik.rule=Host(`${TRAEFIK_HOST}`)
LBL
)
    command:
      - "--api=true"
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.mytlschallenge.acme.email=\${SSL_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
${ACME_FLAGS}

volumes:
  evolution_store:
  evolution_instances:
  portainer_data:
  # traefik_data/n8n_data já são externos no compose base da Hostinger

networks:
  web:
    driver: bridge
YAML

echo "✅ docker-compose.override.yml atualizado."
echo

# --------------- redes & serviços ---------------
# cria rede web caso não exista
docker network inspect web >/dev/null 2>&1 || docker network create web

echo "Baixando/atualizando imagens necessárias..."
docker compose pull --ignore-buildable

echo "Subindo serviços na ordem (traefik → portainer → postgres → redis → evolution)..."
docker compose up -d traefik portainer
docker compose up -d postgres redis
docker compose up -d evolution

# garante DB 'evolution'
echo "Garantindo base 'evolution' no Postgres..."
ensure_pkg jq >/dev/null
PGP=$(docker compose exec -T postgres env | grep -E '^POSTGRES_PASSWORD=' | cut -d= -f2 || true)
[[ -z "${PGP}" ]] && PGP="${PGPASS}"
PGU=$(docker compose exec -T postgres env | grep -E '^POSTGRES_USER=' | cut -d= -f2 || true)
[[ -z "${PGU}" ]] && PGU="${PGUSER}"
docker compose exec -T -e PGPASSWORD="${PGP}" postgres \
  psql -U "${PGU}" -d postgres -c "CREATE DATABASE evolution;" 2>/dev/null || true

# --------------- healthcheck script ---------------
cat > "${HEALTH}" <<'HSH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /root/.env 2>/dev/null || true
N8N="https://${SUBDOMAIN}.${DOMAIN_NAME}/rest/healthz"
EVO="https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/instance/fetchInstances"
PRT="https://${PORTAINER_HOST}"
TRF="https://${TRAEFIK_HOST}"

echo "=== Healthcheck Hostinger Stack ==="
echo "n8n:       ${N8N}"
echo "evolution: ${EVO}"
echo "portainer: ${PRT}"
echo "traefik:   ${TRF}"
echo

# porta 80 (traefik)
if curl -fsS "http://${DOMAIN_NAME}" >/dev/null 2>&1; then
  echo "✅ Traefik (porta 80) OK"
else
  echo "❌ Traefik porta 80 FAIL"
  docker logs traefik --tail=200 || docker logs root-traefik-1 --tail=200 || true
fi

# n8n
if curl -fsS "${N8N}" >/dev/null 2>&1; then
  echo "✅ n8n OK → ${N8N}"
else
  echo "❌ n8n FAIL → ${N8N}"
  echo "   Logs: docker logs n8n --tail=200 || docker logs root-n8n-1 --tail=200"
  echo "   Restart: docker restart n8n"
  echo "   Recreate: docker compose up -d --no-deps --force-recreate n8n"
fi

# evolution (usa apikey)
if curl -fsS "${EVO}" -H "apikey: ${EVOLUTION_API_KEY}" >/dev/null 2>&1; then
  echo "✅ evolution-api OK → ${EVO}"
else
  echo "❌ evolution-api FAIL → ${EVO}"
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
  echo "   Logs: docker logs traefik --tail=200 || docker logs root-traefik-1 --tail=200"
fi

echo "=== Done ==="
HSH
chmod +x "${HEALTH}"
echo "✅ Healthcheck criado: ${HEALTH}"
echo
echo "Aguardando emissão de certificados (visite cada domínio em HTTPS para disparar o ACME)…"
echo
echo "=== Endpoints esperados ==="
echo " - n8n:       https://${SUBDOMAIN}.${DOMAIN_NAME}"
echo " - Evolution: https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}"
[[ -n "${PORTAINER_HOST}" ]] && echo " - Portainer: https://${PORTAINER_HOST}"
[[ -n "${TRAEFIK_HOST}"  ]] && echo " - Traefik:   https://${TRAEFIK_HOST}"
echo
echo "Comandos úteis:"
echo " - Logs Traefik:      docker logs traefik --tail=200 || docker logs root-traefik-1 --tail=200"
echo " - Logs n8n:          docker logs n8n --tail=200 || docker logs root-n8n-1 --tail=200"
echo " - Logs Evolution:    docker logs evolution-api --tail=200"
echo " - Logs Portainer:    docker logs portainer --tail=200"
echo " - Recriar serviço:   docker compose up -d --no-deps --force-recreate <servico>"
echo
echo "Healthcheck: ${HEALTH}"
echo "Concluído. 🚀"
