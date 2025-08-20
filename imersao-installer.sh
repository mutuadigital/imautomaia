#!/usr/bin/env bash
# Hostinger Quick Installer v3 — Evolution API + Portainer + Traefik dashboard
# Uso: bash imersao-installer-v3.sh
# Requisitos: VPS Hostinger com docker-compose.yml padrão (Traefik + n8n/Redis/Postgres)

set -euo pipefail

banner() {
  printf '%s\n' "============================================================"
  printf '%s\n' " Hostinger Quick Installer — Evolution + Portainer + Traefik"
  printf '%s\n\n' "============================================================"
}

err() { printf '❌ %s\n' "$*" >&2; }

ask() {
  # ask "Pergunta" "default"
  local prompt="$1"; local def="${2:-}"; local ans=""
  if [ -t 0 ]; then
    if [ -n "$def" ]; then
      read -r -p "$prompt [$def]: " ans || true
      ans="${ans:-$def}"
    else
      read -r -p "$prompt: " ans || true
    fi
  else
    ans="$def"
  fi
  printf '%s\n' "$ans"
}

yesno() {
  # yesno "Pergunta" "y|n"
  local prompt="$1"; local def="${2:-y}"; local ans=""
  local defShow; defShow="$(printf '%s' "$def" | tr yYnN Yy)"
  if [ -t 0 ]; then
    read -r -p "$prompt [$defShow]: " ans || true
    ans="${ans:-$def}"
  else
    ans="$def"
  fi
  case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

find_compose_dir() {
  if [ -n "${BASE_DIR:-}" ] && [ -f "${BASE_DIR}/docker-compose.yml" ]; then
    printf '%s\n' "$BASE_DIR"; return 0
  fi
  for d in "$PWD" "/root" "/home/$(whoami)" "/opt" "/srv"; do
    if [ -f "$d/docker-compose.yml" ]; then
      printf '%s\n' "$d"; return 0
    fi
  done
  return 1
}

ensure_env() {
  # ensure_env KEY VALUE FILE
  local key="$1"; local val="$2"; local file="$3"
  touch "$file"
  if grep -qE "^${key}=" "$file"; then
    sed -i -E "s|^(${key}=).*|\1${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

health_summary() {
  echo
  echo "=== Endpoints esperados ==="
  local DOMAIN_NAME SUBDOMAIN EVO_SUBDOMAIN P_HOST T_HOST
  DOMAIN_NAME="$(grep -E '^DOMAIN_NAME=' "$ENV_FILE" | cut -d= -f2- || true)"
  SUBDOMAIN="$(grep -E '^SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)"
  EVO_SUBDOMAIN="$(grep -E '^EVO_SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)"
  P_HOST="$(grep -E '^PORTAINER_HOST=' "$ENV_FILE" | cut -d= -f2- || true)"
  T_HOST="$(grep -E '^TRAEFIK_HOST=' "$ENV_FILE" | cut -d= -f2- || true)"

  [ -n "$SUBDOMAIN" ]     && echo " - n8n:       https://${SUBDOMAIN}.${DOMAIN_NAME}"
  [ -n "$EVO_SUBDOMAIN" ] && echo " - Evolution: https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}"
  [ -n "$P_HOST" ]        && echo " - Portainer: https://${P_HOST}"
  [ -n "$T_HOST" ]        && echo " - Traefik:   https://${T_HOST}"
  echo
  echo "Comandos úteis:"
  echo " - Logs Traefik:      docker logs traefik --tail=200"
  echo " - Logs n8n:          docker logs n8n --tail=200 || docker logs root-n8n-1 --tail=200"
  echo " - Logs Evolution:    docker logs evolution-api --tail=200"
  echo " - Logs Portainer:    docker logs portainer --tail=200"
  echo " - Recriar serviço:   docker compose up -d --no-deps --force-recreate <servico>"
  echo
  echo "Healthcheck: ./hostinger-healthcheck.sh"
}

### INÍCIO
banner

# 0) Pré-checagens
command -v docker >/dev/null 2>&1 || { err "Docker não encontrado."; exit 1; }
docker compose version >/dev/null 2>&1 || { err "Docker Compose plugin não encontrado (docker compose)."; exit 1; }

# 1) Encontrar diretório do compose
COMPOSE_DIR="${BASE_DIR:-}"
if [ -z "$COMPOSE_DIR" ]; then
  if ! COMPOSE_DIR="$(find_compose_dir)"; then
    err "Não encontrei docker-compose.yml. Coloque este script na mesma pasta do compose ou exporte BASE_DIR=/caminho e rode novamente."
    exit 1
  fi
fi
cd "$COMPOSE_DIR"
echo "📁 Diretório do compose: $COMPOSE_DIR"
echo

# 2) Wizard de variáveis (.env)
ENV_FILE="$COMPOSE_DIR/.env"
touch "$ENV_FILE"

CUR_DOMAIN="$(grep -E '^DOMAIN_NAME=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_SUB="$(grep -E '^SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_TZ="$(grep -E '^GENERIC_TIMEZONE=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_SSL_EMAIL="$(grep -E '^SSL_EMAIL=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_EVO_SUB="$(grep -E '^EVO_SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_EVO_KEY="$(grep -E '^EVOLUTION_API_KEY=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_P_HOST="$(grep -E '^PORTAINER_HOST=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_T_HOST="$(grep -E '^TRAEFIK_HOST=' "$ENV_FILE" | cut -d= -f2- || true)"

DEFAULT_TZ="${CUR_TZ:-America/Sao_Paulo}"
DEFAULT_SUB="${CUR_SUB:-n8n}"
DEFAULT_EVO_SUB="${CUR_EVO_SUB:-wa}"
DEFAULT_P_HOST="${CUR_P_HOST:-portainer.${CUR_DOMAIN:-SEU_DOMINIO}}"
DEFAULT_T_HOST="${CUR_T_HOST:-traefik.${CUR_DOMAIN:-SEU_DOMINIO}}"

echo "== Configuração dos domínios e chaves =="
DOMAIN_NAME="$(ask 'Domínio raiz (ex.: imautomaia.com.br)' "${CUR_DOMAIN:-}")"
SUBDOMAIN="$(ask 'Subdomínio do n8n (ex.: n8n)' "${DEFAULT_SUB}")"
GENERIC_TIMEZONE="$(ask 'Timezone (ex.: America/Sao_Paulo)' "${DEFAULT_TZ}")"
SSL_EMAIL="$(ask 'Email para certificados (Let’s Encrypt)' "${CUR_SSL_EMAIL:-}")"
EVO_SUBDOMAIN="$(ask 'Subdomínio da Evolution (ex.: wa)' "${DEFAULT_EVO_SUB}")"

EXPOSE_PORTAINER="n"
if yesno "Expor Portainer por domínio? (cria portainer.${DOMAIN_NAME})" "y"; then
  EXPOSE_PORTAINER="y"
  PORTAINER_HOST="$(ask 'Host do Portainer' "portainer.${DOMAIN_NAME}")"
else
  PORTAINER_HOST=""
fi

EXPOSE_TRAEFIK="n"
if yesno "Expor Traefik dashboard por domínio? (cria traefik.${DOMAIN_NAME})" "y"; then
  EXPOSE_TRAEFIK="y"
  TRAEFIK_HOST="$(ask 'Host do Traefik' "traefik.${DOMAIN_NAME}")"
else
  TRAEFIK_HOST=""
fi

# Evolution API key
if [ -z "${CUR_EVO_KEY}" ]; then
  if command -v openssl >/dev/null 2>&1; then
    EVOLUTION_API_KEY="$(openssl rand -hex 16)"
  else
    EVOLUTION_API_KEY="change-me-$(date +%s)"
  fi
else
  EVOLUTION_API_KEY="${CUR_EVO_KEY}"
fi

# 3) Persistir no .env
ensure_env "DOMAIN_NAME" "$DOMAIN_NAME" "$ENV_FILE"
ensure_env "SUBDOMAIN" "$SUBDOMAIN" "$ENV_FILE"
ensure_env "GENERIC_TIMEZONE" "$GENERIC_TIMEZONE" "$ENV_FILE"
ensure_env "SSL_EMAIL" "$SSL_EMAIL" "$ENV_FILE"
ensure_env "EVO_SUBDOMAIN" "$EVO_SUBDOMAIN" "$ENV_FILE"
ensure_env "EVOLUTION_API_KEY" "$EVOLUTION_API_KEY" "$ENV_FILE"

if [ "$EXPOSE_PORTAINER" = "y" ]; then
  ensure_env "PORTAINER_HOST" "$PORTAINER_HOST" "$ENV_FILE"
fi
if [ "$EXPOSE_TRAEFIK" = "y" ]; then
  ensure_env "TRAEFIK_HOST" "$TRAEFIK_HOST" "$ENV_FILE"
fi

echo "✅ .env atualizado em: $ENV_FILE"
echo
echo "Resumo .env (chave oculta):"
grep -E '^(DOMAIN_NAME|SUBDOMAIN|GENERIC_TIMEZONE|SSL_EMAIL|EVO_SUBDOMAIN|PORTAINER_HOST|TRAEFIK_HOST)=' "$ENV_FILE" || true
grep -E '^(EVOLUTION_API_KEY)=' "$ENV_FILE" | sed -E 's/(EVOLUTION_API_KEY=).+/\1***oculto***/' || true
echo

# 4) docker-compose.override.yml
OVERRIDE_FILE="$COMPOSE_DIR/docker-compose.override.yml"
[ -f "$OVERRIDE_FILE" ] && cp -f "$OVERRIDE_FILE" "$OVERRIDE_FILE.bak.$(date +%s)" && echo "ℹ️  Backup: $OVERRIDE_FILE.bak.$(date +%s)"

# Monta labels opcionais
PORTAINER_LABELS=""
if [ -n "${PORTAINER_HOST:-}" ]; then
  PORTAINER_LABELS="$(cat <<EOF
      - traefik.enable=true
      - traefik.http.routers.portainer.rule=Host(\`$PORTAINER_HOST\`)
      - traefik.http.routers.portainer.entrypoints=web,websecure
      - traefik.http.routers.portainer.tls=true
      - traefik.http.routers.portainer.tls.certresolver=mytlschallenge
      - traefik.http.services.portainer.loadbalancer.server.port=9000
EOF
)"
fi

TRAEFIK_LABELS=""
if [ -n "${TRAEFIK_HOST:-}" ]; then
  TRAEFIK_LABELS="$(cat <<EOF
      - traefik.enable=true
      - traefik.http.routers.traefik.rule=Host(\`$TRAEFIK_HOST\`)
      - traefik.http.routers.traefik.entrypoints=web,websecure
      - traefik.http.routers.traefik.tls=true
      - traefik.http.routers.traefik.tls.certresolver=mytlschallenge
      - traefik.http.routers.traefik.service=api@internal
EOF
)"
fi

cat > "$OVERRIDE_FILE" <<YAML
version: "3.7"

services:
  # Evolution API
  evolution:
    image: atendai/evolution-api:latest
    container_name: evolution-api
    restart: always
    environment:
      AUTHENTICATION_API_KEY: \${EVOLUTION_API_KEY}
    volumes:
      - evolution_store:/evolution/store
      - evolution_instances:/evolution/instances
    labels:
      - traefik.enable=true
      - traefik.http.routers.evolution.rule=Host(\`\${EVO_SUBDOMAIN}.\${DOMAIN_NAME}\`)
      - traefik.http.routers.evolution.entrypoints=web,websecure
      - traefik.http.routers.evolution.tls=true
      - traefik.http.routers.evolution.tls.certresolver=mytlschallenge
      - traefik.http.services.evolution.loadbalancer.server.port=8080

  # Portainer (opcional)
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    labels:
$(printf '%s\n' "${PORTAINER_LABELS:-      # desabilitado}") 

  # Traefik (apenas labels extras, serviço já existe no compose base)
  traefik:
    labels:
$(printf '%s\n' "${TRAEFIK_LABELS:-      # desabilitado}") 

volumes:
  evolution_store:
  evolution_instances:
  portainer_data:
YAML

echo "✅ docker-compose.override.yml atualizado."
echo

# 5) Subir/atualizar serviços
echo "Baixando/atualizando imagens necessárias..."
docker compose pull evolution portainer || true

echo "Subindo Evolution/Portainer e atualizando Traefik..."
docker compose up -d evolution
if [ -n "${PORTAINER_HOST:-}" ]; then docker compose up -d portainer; fi
docker compose up -d traefik || true   # só para pegar labels novas

echo
echo "Aguardando emissão de certificados (1–2 min após primeira visita aos hosts)..."
sleep 5

# 6) Gera healthcheck
HEALTH_FILE="$COMPOSE_DIR/hostinger-healthcheck.sh"
cat > "$HEALTH_FILE" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="${BASE_DIR:-$PWD}"
ENV_FILE="$BASE_DIR/.env"
[ -f "$ENV_FILE" ] || { echo "❌ .env não encontrado em $BASE_DIR"; exit 1; }

DOMAIN_NAME="$(grep -E '^DOMAIN_NAME=' "$ENV_FILE" | cut -d= -f2-)"
SUBDOMAIN="$(grep -E '^SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2-)"
EVO_SUBDOMAIN="$(grep -E '^EVO_SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- )"
PORTAINER_HOST="$(grep -E '^PORTAINER_HOST=' "$ENV_FILE" | cut -d= -f2- | tr -d '\n' || true)"
TRAEFIK_HOST="$(grep -E '^TRAEFIK_HOST=' "$ENV_FILE" | cut -d= -f2- | tr -d '\n' || true)"

echo "=== Healthcheck Hostinger Stack ==="
[ -n "$SUBDOMAIN" ]     && echo "n8n:       https://${SUBDOMAIN}.${DOMAIN_NAME}/rest/healthz"
[ -n "$EVO_SUBDOMAIN" ] && echo "evolution: https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/"
[ -n "$PORTAINER_HOST" ]&& echo "portainer: https://${PORTAINER_HOST}"
[ -n "$TRAEFIK_HOST" ]  && echo "traefik:   https://${TRAEFIK_HOST}"
echo

check() {
  local name="$1"; local url="$2"
  if curl -sSf -m 8 "$url" >/dev/null; then
    echo "✅ $name OK → $url"
  else
    echo "❌ $name FAIL → $url"
    echo "   Logs: docker logs $name --tail=200 || true"
    echo "   Restart: docker restart $name || true"
    echo "   Recreate: docker compose up -d --no-deps --force-recreate $name || true"
    echo
  fi
}

if curl -sSf -m 5 http://localhost:80 >/dev/null ; then
  echo "✅ Traefik (porta 80) OK"
else
  echo "❌ Traefik (porta 80) FAIL"
  echo "   docker logs traefik --tail=200"
fi

[ -n "$SUBDOMAIN" ]     && check "n8n" "https://${SUBDOMAIN}.${DOMAIN_NAME}/rest/healthz"
[ -n "$EVO_SUBDOMAIN" ] && check "evolution-api" "https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/"
[ -n "$PORTAINER_HOST" ]&& check "portainer" "https://${PORTAINER_HOST}"
[ -n "$TRAEFIK_HOST" ]  && check "traefik" "https://${TRAEFIK_HOST}"
echo "=== Done ==="
EOS
chmod +x "$HEALTH_FILE"
echo "✅ Healthcheck criado: $HEALTH_FILE"

# 7) Checagem rápida
echo
echo "=== Checagen rápida (pode falhar até LE emitir) ==="
if curl -sSf -m 5 "https://${SUBDOMAIN}.${DOMAIN_NAME}/rest/healthz" >/dev/null 2>&1; then
  echo "✅ n8n OK"
else
  echo "ℹ️  n8n ainda sem HTTPS válido (aguarde emissão) ou endpoint não disponível."
fi

if curl -sSf -m 5 "https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/" >/dev/null 2>&1; then
  echo "✅ Evolution OK"
else
  echo "ℹ️  Evolution ainda sem HTTPS válido (aguarde emissão) ou rota indisponível."
fi

if [ -n "${PORTAINER_HOST:-}" ]; then
  if curl -sSf -m 5 "https://${PORTAINER_HOST}" >/dev/null 2>&1; then
    echo "✅ Portainer OK"
  else
    echo "ℹ️  Portainer ainda sem HTTPS válido (aguarde emissão)."
  fi
fi

if [ -n "${TRAEFIK_HOST:-}" ]; then
  if curl -sSf -m 5 "https://${TRAEFIK_HOST}" >/devnull 2>&1; then
    echo "✅ Traefik OK"
  else
    echo "ℹ️  Traefik dashboard ainda sem HTTPS válido (aguarde emissão)."
  fi
fi

health_summary
echo "Concluído. 🚀"
