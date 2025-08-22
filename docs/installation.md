# Installation

## Prerequisites
- Linux VM (Ubuntu/Oracle Linux OK)
- Docker CE
- Git

### Install Docker (Oracle Linux 9, idempotent)
```bash
sudo ./scripts/install_docker_ol9.sh
```

### (Optional) Open Postgres port on the host firewall

```bash
sudo ./scripts/open_firewall_ol9.sh 5432
```

## Clone & Build

From the project root:

```bash
# Build the Hub+Gateway image
./scripts/build_container.sh
```

## First Run (Hub + Gateway)

TLS is supported directly by Gunicorn (no nginx). If you’re fronting with Cloudflare:

1. Create a **Cloudflare Origin Certificate** for your domain
   In Cloudflare → SSL/TLS → Origin Server → Create certificate.
   You’ll download:

   * `cf-origin.pem`
   * `cf-origin.key`

2. Put certs on the host where Docker runs:

```bash
sudo mkdir -p /etc/ssl/matrixhub
sudo cp cf-origin.pem cf-origin.key /etc/ssl/matrixhub/
sudo chmod 644 /etc/ssl/matrixhub/cf-origin.pem /etc/ssl/matrixhub/cf-origin.key
```

3. Start the container:

```bash
./scripts/run_container.sh
```

**Ports**

* Hub API (TLS): `https://localhost:443/`
* MCP Gateway Admin: `http://localhost:4444/admin/`

