# postfix-m365-oauth2-relay

Postfix SMTP relay for Microsoft 365 with app-only OAuth2.

Allows internal applications and devices to send mail through Exchange Online without requiring OAuth2 support on the client side. Postfix accepts connections with SASL Basic Auth (PLAIN/LOGIN) and authenticates to M365 using the `client_credentials` flow.

## Architecture

```
Internal application / device
        │
        │  SMTP + STARTTLS
        │  port 587: SASL username/password
        │  port 25:  permitted IP addresses only
        ▼
Internal Postfix relay (Ubuntu 24.04)
        │
        │  SMTP submission + STARTTLS
        │  XOAUTH2, app-only access token
        ▼
smtp.office365.com:587
        │
        ▼
Exchange Online (App RBAC)
```

## Key features

- App-only OAuth2 (`client_credentials`) — no interactive login, no refresh token
- Exchange Online [App RBAC](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac) — permission scoped to specific mailboxes only
- Python token daemon — automatic access token renewal before expiry
- Atomic token file writes — Postfix never reads a partial token
- SASL Basic Auth for clients — supports legacy applications and devices without OAuth
- Optional anonymous relay by IP address — for devices that cannot perform SASL

## Components

| Path | Description |
|---|---|
| `opt/postfix-oauth2/token_daemon.py` | Main daemon — obtains and distributes access tokens |
| `opt/postfix-oauth2/token_store.py` | Atomic token file writes |
| `opt/postfix-oauth2/config.py` | Configuration loading and validation |
| `etc/postfix-oauth2/config.yaml.example` | Example daemon configuration |
| `etc/systemd/system/postfix-oauth2.service` | systemd service unit |
| `install.sh` | Installation script |
| `INSTALLATION.md` | Complete step-by-step installation guide |

## Prerequisites

- Ubuntu Server 24.04 LTS
- Postfix installed and basic configuration in place
- [`sasl-xoauth2`](https://github.com/tarickb/sasl-xoauth2) plugin
- Python 3.12+
- App Registration in Microsoft Entra ID
- Exchange Online with App RBAC configured

## Installation

```bash
git clone https://github.com/<user>/postfix-m365-oauth2-relay.git
cd postfix-m365-oauth2-relay
sudo bash install.sh
```

The script:

- checks prerequisites (Postfix, Python, sasl-xoauth2, smtp/unix chroot setting)
- creates the `postfix-oauth2` system user
- creates the directory structure with correct ownership and permissions
- installs a Python virtual environment with dependencies
- copies daemon source files
- installs the systemd service unit
- prints the next steps

## Configuration

See [CONFIGURATION.md](CONFIGURATION.md) for setup notes.

## Directory structure after installation

```
/opt/postfix-oauth2/
├── venv/
├── config.py
├── token_store.py
└── token_daemon.py

/etc/postfix-oauth2/
├── config.yaml
└── secrets/
    └── m365-primary.secret

/etc/postfix/oauth2/
├── smtp@example.com
└── scanner@example.com
```

## License

MIT
