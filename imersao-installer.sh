#!/usr/bin/env bash
# Imersão Automação & IA - Installer All-in-One
# Este script cria a stack: Traefik, Portainer, Postgres, Redis, n8n (queue mode), Evolution API
# Requisitos: Ubuntu 22.04/24.04, Docker + Docker Compose plugin
# Uso: bash imersao-installer.sh  (como root)
set -euo pipefail

BASE_DIR="/opt/imersao"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
ENV_FILE="${BASE_DIR}/.env"
TOOLS_DIR="${BASE_DIR}/tools"

echo "=== Imersão Automação & IA - Installer ==="
echo "Base: ${BASE_DIR}"
echo

# -------- util --------
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1 ; then
    echo "❌ Comando '$1' não encontrado."
    return 1
  fi
  return 0
}

pause() { read -r -p "Pressione ENTER para continuar..."; }

slugify() {
  # simples: minúsculas e remove espaços
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._@-]+/-/g'
}

# -------- checks --------
echo "[1/9] Verificando Docker e Compose..."
if ! require_cmd docker ; then
  cat <<'EOF'
Para instalar Docker (Ubuntu):
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
Saia e rode novamente este instalador.
EOF
  exit 1
fi

if ! docker compose version >/dev/null 2>&1 ; then
  echo "❌ Docker Compose plugin não encontrado (docker compose)."
  echo "Instale: sudo apt-get install -y docker-compose-plugin"
  exit 1
fi
echo "✅ Docker/Compose OK"
echo

echo "[2/9] Criando estrutura de pastas..."
mkdir -p "${BASE_DIR}/"{traefik,portainer,n8n,evolution,postgres,redis,tools}
echo "✅ Pastas criadas em ${BASE_DIR}"
echo

# -------- detectar conflitos --------
echo "[3/9] Checando serviços existentes com nomes comuns (n8n, postgres, redis, traefik, portainer, evolution-api) ..."
EXISTING=$(docker ps -a --format '{{.Names}}' | grep -E '(^|-)n8n($|-)|(^|-)postgres($|-)|(^|-)redis($|-)|(^|-)traefik($|-)|(^|-)portainer($|-)|(^|-)evolution(-|$)' || true)
if [ -n "${EXISTING}" ]; then
  echo "⚠️  Foram encontrados contêineres potencialmente conflitantes:"
  echo "${EXISTING}" | sed 's/^/   - /g'
  echo
  read -r -p "Deseja PARAR e remover automaticamente esses contêineres? (y/N): " CONFIRM
  if [[ "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "Parando/removendo contêineres conflitantes..."
    for c in ${EXISTING}; do
      docker stop "$c" || true
      docker rm "$c" || true
    done
    echo "✅ Limpeza concluída."
  else
    echo "Prosseguindo sem remover. Certifique-se de que não há conflito de portas/domínios."
  fi
fi
echo

# -------- coletar inputs --------
echo "[4/9] Configuração interativa (.env)"
read -r -p "E-mail para certificados Let's Encrypt (ACME): " ACME_EMAIL
read -r -p "Domínio para Traefik dashboard (ex: traefik.seudominio.com): " TRAEFIK_HOST
read -r -p "Domínio para Portainer (ex: portainer.seudominio.com): " PORTAINER_HOST
read -r -p "Domínio para n8n (UI) (ex: n8n.seudominio.com): " N8N_HOST
read -r -p "Domínio para webhooks (ex: webhook.seudominio.com): " N8N_WEBHOOK_HOST
read -r -p "Domínio para Evolution API (ex: wa.seudominio.com): " EVO_HOST

read -r -p "Senha do Postgres (defina forte): " POSTGRES_PASSWORD

# n8n encryption key
if ! command -v openssl >/dev/null 2>&1 ; then
  echo "⚠️ openssl não encontrado. Informe manualmente a N8N_ENCRYPTION_KEY (base64 32 bytes)."
  read -r -p "N8N_ENCRYPTION_KEY: " N8N_ENCRYPTION_KEY
else
  read -r -p "Gerar N8N_ENCRYPTION_KEY automaticamente? (Y/n): " GENKEY
  if [[ ! "${GENKEY}" =~ ^[Nn]$ ]]; then
    N8N_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '\n')
    echo "→ Gerada N8N_ENCRYPTION_KEY."
  else
    read -r -p "Cole sua N8N_ENCRYPTION_KEY: " N8N_ENCRYPTION_KEY
  fi
fi

# evolution api key
if command -v openssl >/dev/null 2>&1 ; then
  EVOLUTION_API_KEY=$(openssl rand -hex 16)
else
  read -r -p "Chave da Evolution API (string aleatória): " EVOLUTION_API_KEY
fi

# Traefik basic auth
echo "Crie um usuário/senha para o dashboard do Traefik."
read -r -p "Usuário: " BASIC_USER
read -r -s -p "Senha: " BASIC_PASS; echo
if command -v htpasswd >/dev/null 2>&1 ; then
  BASIC_HASH=$(printf "%s:%s\n" "$BASIC_USER" "$(openssl passwd -apr1 "$BASIC_PASS")")
else
  # fallback simples (não-compatível total). Recomendado instalar apache2-utils/htpasswd.
  BASIC_HASH="${BASIC_USER}:$(openssl passwd -apr1 "$BASIC_PASS")"
fi
BASIC_HASH_ESCAPED=$(printf "%s" "$BASIC_HASH" | sed -e 's/\$/\$\$/g')

# -------- escrever .env --------
cat > "${ENV_FILE}" <<EOF
ACME_EMAIL=$(slugify "${ACME_EMAIL}")
TRAEFIK_HOST=$(slugify "${TRAEFIK_HOST}")
PORTAINER_HOST=$(slugify "${PORTAINER_HOST}")
N8N_HOST=$(slugify "${N8N_HOST}")
N8N_WEBHOOK_HOST=$(slugify "${N8N_WEBHOOK_HOST}")
EVO_HOST=$(slugify "${EVO_HOST}")

POSTGRES_DB=n8n
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_TIMEZONE=America/Sao_Paulo
N8N_WORKER_CONCURRENCY=5

EVOLUTION_API_KEY=${EVOLUTION_API_KEY}

TRAEFIK_BASIC_AUTH=${BASIC_HASH_ESCAPED}
EOF

echo "✅ .env criado em ${ENV_FILE}"
echo

# -------- docker-compose.yml --------
cat > "${COMPOSE_FILE}" <<"EOF"
version: "3.8"

networks:
  proxy:
    driver: bridge
  internal:
    driver: bridge

volumes:
  traefik_letsencrypt:
  portainer_data:
  postgres_data:
  n8n_data:
  evolution_store:
  evolution_instances:

services:
  traefik:
    image: traefik:v2.11
    container_name: traefik
    restart: unless-stopped
    command:
      - --api.dashboard=true
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --certificatesresolvers.le.acme.email=${ACME_EMAIL}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
    ports:
      - "80:80"
      - "443:443"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:80 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 10
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_letsencrypt:/letsencrypt
    networks: [proxy]
    labels:
      - traefik.enable=true
      - traefik.http.routers.traefik.rule=Host(`${TRAEFIK_HOST}`)
      - traefik.http.routers.traefik.entrypoints=websecure
      - traefik.http.routers.traefik.tls.certresolver=le
      - traefik.http.routers.traefik.service=api@internal
      - traefik.http.routers.traefik.middlewares=traefik-auth
      - traefik.http.middlewares.traefik-auth.basicauth.users=${TRAEFIK_BASIC_AUTH}

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    networks: [proxy]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:9000/api/status || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 20
    labels:
      - traefik.enable=true
      - traefik.http.routers.portainer.rule=Host(`${PORTAINER_HOST}`)
      - traefik.http.routers.portainer.entrypoints=websecure
      - traefik.http.routers.portainer.tls.certresolver=le
      - traefik.http.services.portainer.loadbalancer.server.port=9000

  postgres:
    image: postgres:16-alpine
    container_name: postgres
    restart: unless-stopped
    networks: [internal]
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 20
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    container_name: redis
    restart: unless-stopped
    networks: [internal]
    command: ["redis-server", "--appendonly", "yes"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 20

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks: [proxy, internal]
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_HOST: ${N8N_HOST}
      N8N_PROTOCOL: https
      N8N_EDITOR_BASE_URL: https://${N8N_HOST}/
      WEBHOOK_URL: https://${N8N_WEBHOOK_HOST}/
      TZ: ${N8N_TIMEZONE}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      N8N_SECURE_COOKIE: "true"
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PERSONALIZATION_ENABLED: "false"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:5678/rest/healthz || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 30
    volumes:
      - n8n_data:/home/node/.n8n
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls.certresolver=le
      - traefik.http.services.n8n.loadbalancer.server.port=5678

  n8n-webhook:
    image: docker.n8n.io/n8nio/n8n:latest
    container_name: n8n-webhook
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks: [proxy, internal]
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      WEBHOOK_URL: https://${N8N_WEBHOOK_HOST}/
      TZ: ${N8N_TIMEZONE}
    command: n8n webhook
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:5678/rest/healthz || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 30
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n-webhook.rule=Host(`${N8N_WEBHOOK_HOST}`)
      - traefik.http.routers.n8n-webhook.entrypoints=websecure
      - traefik.http.routers.n8n-webhook.tls.certresolver=le
      - traefik.http.services.n8n-webhook.loadbalancer.server.port=5678

  n8n-worker:
    image: docker.n8n.io/n8nio/n8n:latest
    container_name: n8n-worker
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks: [internal]
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      TZ: ${N8N_TIMEZONE}
    command: sh -c "n8n worker --concurrency=${N8N_WORKER_CONCURRENCY}"

  evolution:
    image: atendai/evolution-api:latest
    container_name: evolution-api
    restart: unless-stopped
    networks: [proxy]
    environment:
      AUTHENTICATION_API_KEY: ${EVOLUTION_API_KEY}
    volumes:
      - evolution_store:/evolution/store
      - evolution_instances:/evolution/instances
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8080/ || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 30
    labels:
      - traefik.enable=true
      - traefik.http.routers.evolution.rule=Host(`${EVO_HOST}`)
      - traefik.http.routers.evolution.entrypoints=websecure
      - traefik.http.routers.evolution.tls.certresolver=le
      - traefik.http.services.evolution.loadbalancer.server.port=8080
EOF

echo "✅ docker-compose.yml criado em ${COMPOSE_FILE}"
echo

# -------- healthcheck helper --------
cat > "${TOOLS_DIR}/healthcheck.sh" <<"EOF"
#!/usr/bin/env bash
set -e
echo "=== Verificação de Stack da Imersão ==="
echo "(use: bash /opt/imersao/tools/healthcheck.sh)"
echo

check() {
  local name="$1"
  local url="$2"
  if curl -sSf -m 5 "$url" >/dev/null ; then
    echo "✅ $name OK → $url"
  else
    echo "❌ $name FALHOU → $url"
    echo "   Dicas:"
    echo "   - Ver logs:        docker logs ${name} --tail=100"
    echo "   - Reiniciar:       docker restart ${name}"
    echo "   - Recriar serviço: cd /opt/imersao && docker compose up -d --no-deps --force-recreate ${name}"
    echo
  fi
}

echo "[Traefik]"
if curl -sSf -m 5 http://localhost:80 >/dev/null ; then
  echo "✅ Porta 80 local OK"
else
  echo "❌ Porta 80 local falhou."
  echo "   docker logs traefik --tail=200"
  echo "   docker restart traefik"
fi
echo

echo "[Portainer]"
if curl -sSf -m 5 http://localhost:9000/api/status >/dev/null ; then
  echo "✅ Porta 9000 local OK"
else
  echo "❌ Porta 9000 local falhou."
  echo "   docker logs portainer --tail=200"
  echo "   docker restart portainer"
fi
echo

source /opt/imersao/.env

[ -n "$TRAEFIK_HOST" ]      && check traefik       "https://${TRAEFIK_HOST}"
[ -n "$PORTAINER_HOST" ]    && check portainer     "https://${PORTAINER_HOST}/api/status"
[ -n "$N8N_HOST" ]          && check n8n           "https://${N8N_HOST}/rest/healthz"
[ -n "$N8N_WEBHOOK_HOST" ]  && check n8n-webhook   "https://${N8N_WEBHOOK_HOST}/rest/healthz"
[ -n "$EVO_HOST" ]          && check evolution-api "https://${EVO_HOST}/"
echo

echo "[Postgres]"
if docker exec -i postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1 ; then
  echo "✅ Postgres pronto (pg_isready)"
else
  echo "❌ Postgres indisponível."
  echo "   docker logs postgres --tail=200"
  echo "   docker restart postgres"
fi
echo

echo "[Redis]"
if docker exec -i redis redis-cli ping | grep -q PONG ; then
  echo "✅ Redis pronto (PONG)"
else
  echo "❌ Redis indisponível."
  echo "   docker logs redis --tail=200"
  echo "   docker restart redis"
fi
echo
echo "=== Fim da verificação ==="
EOF

chmod +x "${TOOLS_DIR}/healthcheck.sh"
echo "✅ healthcheck em ${TOOLS_DIR}/healthcheck.sh"
echo

# -------- subir stack --------
echo "[5/9] Puxando imagens..."
docker compose -f "${COMPOSE_FILE}" pull

echo "[6/9] Subindo serviços..."
docker compose -f "${COMPOSE_FILE}" up -d

echo "[7/9] Aguardando inicialização (pode levar ~1-3 min para TLS)..."
sleep 5

echo "[8/9] Status:"
docker compose -f "${COMPOSE_FILE}" ps

echo "[9/9] Rodando verificador:"
bash "${TOOLS_DIR}/healthcheck.sh" || true

cat <<'EOF'

=== Próximos passos ===
1) Acesse:
   - Traefik:   https://SEU_TRAEFIK_HOST
   - Portainer: https://SEU_PORTAINER_HOST
   - n8n UI:    https://SEU_N8N_HOST
   - Webhooks:  https://SEU_N8N_WEBHOOK_HOST
   - Evolution: https://SEU_EVO_HOST

2) Parear Evolution API:
   # criar instância
   curl -X POST "https://SEU_EVO_HOST/instance/create" \
     -H "Content-Type: application/json" \
     -H "apikey: SUA_CHAVE_API" \
     -d '{
       "instanceName": "imersao01",
       "token": "token-interno-qualquer",
       "qrcode": true,
       "number": "55SEUNUMERO",
       "integration": "WHATSAPP-BAILEYS",
       "alwaysOnline": true,
       "readMessages": true
     }'

   # conectar/obter QR
   curl -H "apikey: SUA_CHAVE_API" \
     "https://SEU_EVO_HOST/instance/connect/imersao01"

3) Dúvidas? Logs ajudam muito:
   docker logs traefik --tail=200
   docker logs portainer --tail=200
   docker logs n8n --tail=200
   docker logs evolution-api --tail=200

Bom proveito na imersão! 🚀
EOF
