#!/usr/bin/env bash
set -euo pipefail

# Chatwoot Healthcheck (standalone)
# - Não altera nada no servidor
# - Lê variáveis do .env.chatwoot (se existir)
# - Tenta deduzir o host via FRONTEND_URL ou labels do Traefik
# - Verifica containers, HTTPS, DB/Redis, Sidekiq e logs recentes

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

ENV_CW="${ENV_CW:-.env.chatwoot}"
if [[ -f "$ENV_CW" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_CW"
fi

# Deduz HOST
extract_host() {
  local url="$1"
  [[ -z "${url:-}" ]] && return 1
  echo "$url" | sed -E 's#https?://([^/]+)/?.*#\1#'
}

CHATWOOT_HOST=""
if [[ -n "${FRONTEND_URL:-}" ]]; then
  CHATWOOT_HOST="$(extract_host "$FRONTEND_URL" || true)"
fi

if [[ -z "$CHATWOOT_HOST" ]]; then
  # Tenta pelas labels do Traefik
  rule="$(docker inspect chatwoot --format '{{index .Config.Labels "traefik.http.routers.chatwoot.rule"}}' 2>/dev/null || true)"
  # Ex.: Host(`chat.seu-dominio.com`)
  CHATWOOT_HOST="$(echo "$rule" | sed -n "s/.*Host(\`\\([^\\\`]*\\)\`).*/\\1/p")"
fi

[[ -z "$CHATWOOT_HOST" ]] && {
  echo "❌ Não consegui deduzir o host do Chatwoot."
  echo "   Defina FRONTEND_URL no .env.chatwoot (ex.: https://chat.seu-dominio.com)"
  exit 2
}

echo "=== Chatwoot Healthcheck ==="
echo "Host: $CHATWOOT_HOST"
echo

# 1) Containers
echo "1) Containers:"
for name in chatwoot chatwoot-worker; do
  if docker ps --format '{{.Names}}|{{.Status}}' | grep -q "^${name}|"; then
    docker ps --format '{{.Names}}|{{.Status}}' | grep "^${name}|" | sed 's/|/  →  /'
  else
    echo "❌ ${name} não está em execução"
  fi
done
echo

# 2) HTTPS (Traefik / resposta pública)
echo "2) HTTPS público:"
status="$(curl -sSk -o /dev/null -w '%{http_code}' "https://${CHATWOOT_HOST}/")"
echo "GET https://${CHATWOOT_HOST}/  →  HTTP $status"
if [[ "$status" != "200" && "$status" != "302" && "$status" != "301" ]]; then
  echo "⚠️  Esperado 200/301/302 (login/redirect)."
fi
echo

# 3) DB e Redis (de dentro do container web)
echo "3) Verificando DB/Redis via Rails runner (dentro do container):"
if docker ps --format '{{.Names}}' | grep -qx chatwoot; then
  docker exec -i chatwoot bash -lc '
    set -e
    ruby -v >/dev/null 2>&1 || { echo "Ruby indisponível"; exit 1; }
    bundle exec rails runner "
      begin
        db_ok = ActiveRecord::Base.connection.active? rescue false
        puts \"db=#{db_ok}\"
      rescue => e
        puts \"db=false #{e.class}: #{e.message}\"
      end
      begin
        require \"redis\"
        r = Redis.new(url: ENV[\"REDIS_URL\"])
        pong = (r.ping == \"PONG\")
        puts \"redis=#{pong}\"
      rescue => e
        puts \"redis=false #{e.class}: #{e.message}\"
      end
    " 2>/dev/null
  '
else
  echo "❌ Container 'chatwoot' não encontrado"
fi
echo

# 4) Sidekiq fila
echo "4) Sidekiq (fila):"
if docker ps --format '{{.Names}}' | grep -qx chatwoot-worker; then
  docker exec -i chatwoot bash -lc '
    bundle exec rails runner "
      begin
        require \"sidekiq\"
        sizes = {
          default: Sidekiq::Queue.new.size,
          mailers: Sidekiq::Queue.new(\"mailers\").size
        }
        puts \"queues=#{sizes}\"
      rescue => e
        puts \"queues=unknown #{e.class}: #{e.message}\"
      end
    " 2>/dev/null
  '
else
  echo "❌ chatwoot-worker não está rodando"
fi
echo

# 5) Logs recentes (resumo)
echo "5) Logs recentes (últimas ~30 linhas):"
for name in chatwoot chatwoot-worker; do
  if docker ps --format '{{.Names}}' | grep -qx "$name"; then
    echo "--- $name ---"
    docker logs --tail=30 "$name" 2>&1 | sed 's/^/  /'
  fi
done
echo

echo "=== Fim ==="
