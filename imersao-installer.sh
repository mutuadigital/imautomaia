#!/usr/bin/env bash
# Hostinger Quick Installer v3.2 — Evolution + Portainer + Traefik
# - Sempre pergunta se deseja atualizar variáveis do .env
# - Detecção da rede do Traefik e uso de traefik.docker.network
# - Healthcheck com fallback para n8n
set -euo pipefail

banner() {
  printf '%s\n' "============================================================"
  printf '%s\n' " Hostinger Quick Installer — Evolution + Portainer + Traefik"
  printf '%s\n\n' "============================================================"
}
err() { printf '❌ %s\n' "$*" >&2; }

ask() { # ask "Pergunta" "default"  (funciona mesmo via curl|bash)
  local prompt="$1"; local def="${2:-}"; local ans=""
  if [ -r /dev/tty ]; then
    if [ -n "$def" ]; then
      read -r -p "$prompt [$def]: " ans < /dev/tty || true
      ans="${ans:-$def}"
    else
      read -r -p "$prompt: " ans < /dev/tty || true
    fi
  else
    ans="$def"
  fi
  printf '%s\n' "$ans"
}
yesno() { # yesno "Pergunta" "y|n"
  local prompt="$1"; local def="${2:-y}"; local ans=""
  local defShow; defShow="$(printf '%s' "$def" | tr yYnN Yy)"
  if [ -r /dev/tty ]; then
    read -r -p "$prompt [$defShow]: " ans < /dev/tty || true
    ans="${ans:-$def}"
  else
    ans="$def"
  fi
  case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in y|yes) return 0;; *) return 1;; esac
}

find_compose_dir() {
  if [ -n "${BASE_DIR:-}" ] && [ -f "${BASE_DIR}/docker-compose.yml" ]; then printf '%s\n' "$BASE_DIR"; return 0; fi
  for d in "$PWD" "/root" "/home/$(whoami)" "/opt" "/srv"; do
    [ -f "$d/docker-compose.yml" ] && { printf '%s\n' "$d"; return 0; }
  done; return 1
}
ensure_env() { # ensure_env KEY VALUE FILE
  local key="$1"; local val="$2"; local file="$3"; touch "$file"
  if grep -qE "^${key}=" "$file"; then sed -i -E "s|^(${key}=).*|\1${val}|" "$file"; else printf '%s=%s\n' "$key" "$val" >> "$file"; fi
}

health_summary() {
  echo; echo "=== Endpoints esperados ==="
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
  echo; echo "Comandos úteis:"
  echo " - Logs Traefik:      docker logs traefik --tail=200"
  echo " - Logs n8n:          docker logs n8n --tail=200 || docker logs root-n8n-1 --tail=200"
  echo " - Logs Evolution:    docker logs evolution-api --tail=200"
  echo " - Logs Portainer:    docker logs portainer --tail=200"
  echo " - Recriar serviço:   docker compose up -d --no-deps --force-recreate <servico>"
  echo; echo "Healthcheck: ./hostinger-healthcheck.sh"
}

### INÍCIO
banner
command -v docker >/dev/null 2>&1 || { err "Docker não encontrado."; exit 1; }
docker compose version >/dev/null 2>&1 || { err "Docker Compose plugin não encontrado (docker compose)."; exit 1; }

COMPOSE_DIR="${BASE_DIR:-}"; [ -z "$COMPOSE_DIR" ] && COMPOSE_DIR="$(find_compose_dir)" || true
[ -n "$COMPOSE_DIR" ] || { err "Não encontrei docker-compose.yml. Defina BASE_DIR ou rode na pasta correta."; exit 1; }
cd "$COMPOSE_DIR"; echo "📁 Diretório do compose: $COMPOSE_DIR"; echo

ENV_FILE="$COMPOSE_DIR/.env"; touch "$ENV_FILE"
# valores atuais
CUR_DOMAIN="$(grep -E '^DOMAIN_NAME=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_SUB="$(grep -E '^SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_TZ="$(grep -E '^GENERIC_TIMEZONE=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_SSL_EMAIL="$(grep -E '^SSL_EMAIL=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_EVO_SUB="$(grep -E '^EVO_SUBDOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_EVO_KEY="$(grep -E '^EVOLUTION_API_KEY=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_P_HOST="$(grep -E '^PORTAINER_HOST=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_T_HOST="$(grep -E '^TRAEFIK_HOST=' "$ENV_FILE" | cut -d= -f2- || true)"
CUR_TNET="$(grep -E '^TRAEFIK_NETWORK=' "$ENV_FILE" | cut -d= -f2- || true)"

# pergunta se quer atualizar
echo "== Configuração dos domínios e chaves =="
if yesno "Deseja revisar/atualizar as variáveis do .env?" "y"; then
  DOMAIN_NAME="$(ask 'Domínio raiz (ex.: imautomaia.com.br)' "${CUR_DOMAIN:-}")"
  SUBDOMAIN="$(ask 'Subdomínio do n8n (ex.: n8n)' "${CUR_SUB:-n8n}")"
  GENERIC_TIMEZONE="$(ask 'Timezone (ex.: America/Sao_Paulo)' "${CUR_TZ:-America/Sao_Paulo}")"
  SSL_EMAIL="$(ask 'Email para certificados (Let’s Encrypt)' "${CUR_SSL_EMAIL:-}")"
  EVO_SUBDOMAIN="$(ask 'Subdomínio da Evolution (ex.: wa)' "${CUR_EVO_SUB:-wa}")"

  if yesno "Expor Portainer por domínio? (portainer.${DOMAIN_NAME})" "$( [ -n "${CUR_P_HOST:-}" ] && echo y || echo n )"; then
    PORTAINER_HOST="$(ask 'Host do Portainer' "${CUR_P_HOST:-portainer.${DOMAIN_NAME}}")"
  else
    PORTAINER_HOST=""
  fi

  if yesno "Expor Traefik dashboard por domínio? (traefik.${DOMAIN_NAME})" "$( [ -n "${CUR_T_HOST:-}" ] && echo y || echo n )"; then
    TRAEFIK_HOST="$(ask 'Host do Traefik' "${CUR_T_HOST:-traefik.${DOMAIN_NAME}}")"
  else
    TRAEFIK_HOST=""
  fi
else
  # mantém os atuais
  DOMAIN_NAME="${CUR_DOMAIN:-}"; SUBDOMAIN="${CUR_SUB:-n8n}"
  GENERIC_TIMEZONE="${CUR_TZ:-America/Sao_Paulo}"; SSL_EMAIL="${CUR_SSL_EMAIL:-}"
  EVO_SUBDOMAIN="${CUR_EVO_SUB:-wa}"; PORTAINER_HOST="${CUR_P_HOST:-}"; TRAEFIK_HOST="${CUR_T_HOST:-}"
fi

# Evolution API key
if [ -z "${CUR_EVO_KEY:-}" ]; then
  if command -v openssl >/dev/null 2>&1; then EVOLUTION_API_KEY="$(openssl rand -hex 16)"; else EVOLUTION_API_KEY="change-me-$(date +%s)"; fi
else EVOLUTION_API_KEY="${CUR_EVO_KEY}"; fi

# detectar rede do traefik
if [ -z "${CUR_TNET:-}" ]; then
  TRAEFIK_NETWORK="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{printf "%s " $k}}{{end}}' root-traefik-1 2>/dev/null | awk '{print $1}')"
else
  TRAEFIK_NETWORK="$CUR_TNET"
fi

# persistir
ensure_env "DOMAIN_NAME" "$DOMAIN_NAME" "$ENV_FILE"
ensure_env "SUBDOMAIN" "$SUBDOMAIN" "$ENV_FILE"
ensure_env "GENERIC_TIMEZONE" "$GENERIC_TIMEZONE" "$ENV_FILE"
ensure_env "SSL_EMAIL" "$SSL_EMAIL" "$ENV_FILE"
ensure_env "EVO_SUBDOMAIN" "$EVO_SUBDOMAIN" "$ENV_FILE"
ensure_env "EVOLUTION_API_KEY" "$EVOLUTION_API_KEY" "$ENV_FILE"
[ -n "$PORTAINER_HOST" ] && ensure_env "PORTAINER_HOST" "$PORTAINER_HOST" "$ENV_FILE" || sed -i '/^PORTAINER_HOST=/d' "$ENV_FILE" || true
[ -n "$TRAEFIK_HOST" ]   && ensure_env "TRAEFIK_HOST" "$TRAEFIK_HOST" "$ENV_FILE"   || sed -i '/^TRAEFIK_HOST=/d' "$ENV_FILE" || true
[ -n "$TRAEFIK_NETWORK" ]&& ensure_env "TRAEFIK_NETWORK" "$TRAEFIK_NETWORK" "$ENV_FILE"

echo "✅ .env atualizado em: $ENV_FILE"
echo; echo "Resumo .env (chave oculta):"
grep -E '^(DOMAIN_NAME|SUBDOMAIN|GENERIC_TIMEZONE|SSL_EMAIL|EVO_SUBDOMAIN|PORTAINER_HOST|TRAEFIK_HOST|TRAEFIK_NETWORK)=' "$ENV_FILE" || true
grep -E '^(EVOLUTION_API_KEY)=' "$ENV_FILE" | sed -E 's/(EVOLUTION_API_KEY=).+/\1***oculto***/' || true
echo

# override
OVERRIDE_FILE="$COMPOSE_DIR/docker-compose.override.yml"
[ -f "$OVERRIDE_FILE" ] && cp -f "$OVERRIDE_FILE" "$OVERRIDE_FILE.bak.$(date +%s)" && echo "ℹ️  Backup: $OVERRIDE_FILE.bak.$(date +%s)"

cat > "$OVERRIDE_FILE" <<YAML
version: "3.7"

services:
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
      - traefik.docker.network=\${TRAEFIK_NETWORK}

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    labels:
YAML

# labels condicionais
if [ -n "${PORTAINER_HOST:-}" ]; then
  cat >> "$OVERRIDE_FILE" <<YAML
      - traefik.enable=true
      - traefik.http.routers.portainer.rule=Host(\`\${PORTAINER_HOST}\`)
      - traefik.http.routers.portainer.entrypoints=web,websecure
      - traefik.http.routers.portainer.tls=true
      - traefik.http.routers.portainer.tls.certresolver=mytlschallenge
      - traefik.http.services.portainer.loadbalancer.server.port=9000
      - traefik.docker.network=\${TRAEFIK_NETWORK}
YAML
else
  echo "      # Portainer não exposto por domínio" >> "$OVERRIDE_FILE"
fi

cat >> "$OVERRIDE_FILE" <<YAML

  traefik:
    labels:
YAML

if [ -n "${TRAEFIK_HOST:-}" ]; then
  cat >> "$OVERRIDE_FILE" <<YAML
      - traefik.enable=true
      - traefik.http.routers.traefik.rule=Host(\`\${TRAEFIK_HOST}\`)
      - traefik.http.routers.traefik.entrypoints=web,websecure
      - traefik.http.routers.traefik.tls=true
      - traefik.http.routers.traefik.tls.certresolver=mytlschallenge
      - traefik.http.routers.traefik.service=api@internal
      - traefik.docker.network=\${TRAEFIK_NETWORK}
YAML
else
  echo "      # Traefik dashboard não exposto por domínio" >> "$OVERRIDE_FILE"
fi

cat >> "$OVERRIDE_FILE" <<'YAML'

volumes:
  evolution_store:
  evolution_instances:
  portainer_data:
YAML

echo "✅ docker-compose.override.yml atualizado."
echo

echo "Baixando/atualizando imagens necessárias..."
docker compose pull evolution portainer || true

echo "Subindo/atualizando serviços..."
docker compose up -d evolution
[ -n "${PORTAINER_HOST:-}" ] && docker compose up -d portainer || true
docker compose up -d traefik || true

echo; echo "Gerando healthcheck..."
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

# n8n: tenta alguns caminhos
if ! check "n8n" "https://${SUBDOMAIN}.${DOMAIN_NAME}/rest/healthz"; then
  curl -sSf -m 8 "https://${SUBDOMAIN}.${DOMAIN_NAME}/healthz" >/dev/null 2>&1 && echo "✅ n8n OK em /healthz" || true
fi

[ -n "$EVO_SUBDOMAIN" ] && check "evolution-api" "https://${EVO_SUBDOMAIN}.${DOMAIN_NAME}/"
[ -n "$PORTAINER_HOST" ]&& check "portainer" "https://${PORTAINER_HOST}"
[ -n "$TRAEFIK_HOST" ]  && check "traefik" "https://${TRAEFIK_HOST}"
echo "=== Done ==="
EOS
chmod +x "$HEALTH_FILE"
echo "✅ Healthcheck criado: $HEALTH_FILE"

echo; echo "Aguardando emissão de certificados (1–2 min após a primeira visita aos hosts)..."
health_summary
echo "Concluído. 🚀"
