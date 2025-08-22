# Run the Hub with TLS (no nginx)

MatrixHub terminates TLS directly in **Gunicorn** using a **Cloudflare Origin Certificate**.

## 1) Prepare certs on the host
Create/Download a Cloudflare **Origin Certificate** for your domain (Full/Strict). Then:

```bash
sudo mkdir -p /etc/ssl/matrixhub
sudo cp cf-origin.pem cf-origin.key /etc/ssl/matrixhub/
sudo chmod 644 /etc/ssl/matrixhub/cf-origin.pem /etc/ssl/matrixhub/cf-origin.key
```

> These are trusted by Cloudflare, not browsers—perfect for Full (strict).

## 2) Start Hub + Gateway

From the project root:

```bash
./scripts/run_container.sh
```

This mounts:

* Hub env: `.env` (or `.env.example`) → `/app/.env`
* Gateway env: `.env.gateway.local` (or `.env.gateway.example`) → `/app/.env.gateway.*`
* TLS certs: `/etc/ssl/matrixhub` (read-only)

Gunicorn starts on `:443` with:

```
--certfile /etc/ssl/matrixhub/cf-origin.pem
--keyfile  /etc/ssl/matrixhub/cf-origin.key
```

## 3) Ports & URLs

* **Hub (TLS):** `https://localhost:443/`
* **Gateway Admin:** `http://localhost:4444/admin/`

## 4) Cloudflare sanity

* DNS A/AAAA → your server → **Proxied (orange)**
* SSL/TLS → **Full (strict)**
* Edge Certificates → (optional) “Always Use HTTPS”: **On**
* Network → HTTP/2 + HTTP/3: **On**
