# Hostinger Stack: Traefik + n8n + Evolution API + Redis + Postgres + Portainer

Stack pronta para produção com **TLS automático (Let's Encrypt)** via **Traefik**, **n8n** com filas, **Evolution API** (WhatsApp) usando imagem estável `evoapicloud/evolution-api`, **Redis**, **Postgres** e **Portainer**.

## Pré-requisitos

- Ubuntu 22.04+ com Docker e Docker Compose plugin instalados
- DNS A dos hosts apontando para o IP do servidor:
  - `n8n.<domínio>`
  - `wa.<domínio>`
  - `portainer.<domínio>`
  - `traefik.<domínio>`
- **Cloudflare proxy desativado (modo “DNS only”)** nas 4 entradas

## Instalação

```bash
git clone <repo> && cd <repo>
chmod +x install.sh
./install.sh
