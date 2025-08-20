# Guia Rápido — Imersão Automação & IA

**Data de geração:** 2025-08-20

Este kit sobe **Traefik, Portainer, Postgres, Redis, n8n (queue mode) e Evolution API** com um único script.

## Uso (como root)
```bash
# copie o arquivo e execute
bash imersao-installer.sh
```
Siga as perguntas interativas para preencher domínios e segredos. O script gera `/.env`, `docker-compose.yml`, e um verificador em `/opt/imersao/tools/healthcheck.sh`.

## Verificação
```bash
bash /opt/imersao/tools/healthcheck.sh
```

## Endpoints esperados
- Traefik:   `https://traefik.SEUDOMINIO`
- Portainer: `https://portainer.SEUDOMINIO`
- n8n:       `https://n8n.SEUDOMINIO`
- Webhooks:  `https://webhook.SEUDOMINIO`
- Evolution: `https://wa.SEUDOMINIO`

## Dicas
- Atualizar imagens: `cd /opt/imersao && docker compose pull && docker compose up -d`
- Logs: `docker logs NOME --tail=200`
- Backup Postgres: `docker exec -t postgres pg_dump -U ${POSTGRES_USER} ${POSTGRES_DB} > /opt/imersao/backup_n8n_$(date +%F).sql`
