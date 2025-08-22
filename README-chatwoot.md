# Chatwoot Add-on (Traefik + Docker)

Instalador opcional do **Chatwoot** que reutiliza **Postgres** e **Redis** já existentes no seu servidor e publica via **Traefik** no subdomínio que você escolher.

## Requisitos

- Traefik do stack principal já rodando (com entrypoints `web` e `websecure`).
- Containers `postgres` e `redis` do stack principal na rede `web`.
- DNS do subdomínio do Chatwoot apontado para o servidor (sem proxy/laranja).

## Instalação

```bash
bash install-chatwoot.sh
