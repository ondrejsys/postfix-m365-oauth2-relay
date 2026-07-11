#!/usr/bin/env bash
# install.sh — Postfix OAuth2 token daemon installer
#
# Installs the token daemon for a Postfix relay to Microsoft 365
# using app-only OAuth2 (client_credentials).
#
# Prerequisites:
#   - Ubuntu Server 24.04 LTS
#   - Postfix installed and basic configuration in place
#   - sasl-xoauth2 plugin installed (/usr/lib/sasl2/libsasl-xoauth2.so)
#   - Python 3.12+
#
# Usage:
#   sudo bash install.sh
#
# For the full installation walkthrough including Entra ID and Exchange Online
# configuration, see: INSTALLATION.md

set -euo pipefail

# ── Output helpers ───────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
section() { echo -e "\n${BOLD}──── $* ────${RESET}"; }
die()     { error "$*"; exit 1; }

# ── Root check ───────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root: sudo bash install.sh"
fi

# ── Constants ────────────────────────────────────────────────────────────────

DAEMON_USER="postfix-oauth2"
APP_DIR="/opt/postfix-oauth2"
CONFIG_DIR="/etc/postfix-oauth2"
SECRET_DIR="/etc/postfix-oauth2/secrets"
TOKEN_DIR="/etc/postfix/oauth2"
VENV_DIR="${APP_DIR}/venv"
SERVICE_NAME="postfix-oauth2"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Prerequisites ────────────────────────────────────────────────────────────

section "Checking prerequisites"

check_command() {
    if ! command -v "$1" &>/dev/null; then
        die "Missing command: $1. Install it and re-run the script."
    fi
    info "OK: $1"
}

check_command postfix
check_command python3

if ! python3 -c "import sys; assert sys.version_info >= (3, 12)" 2>/dev/null; then
    die "Python 3.12 or later is required. Found: $(python3 --version)"
fi
info "OK: Python $(python3 --version)"

# Search for the sasl-xoauth2 plugin in common locations
XOAUTH2_SO=""
for candidate in \
    /usr/lib/sasl2/libsasl-xoauth2.so \
    /usr/local/lib/sasl2/libsasl-xoauth2.so \
    /usr/lib/x86_64-linux-gnu/sasl2/libsasl-xoauth2.so; do
    if [[ -f "$candidate" ]]; then
        XOAUTH2_SO="$candidate"
        break
    fi
done

if [[ -z "$XOAUTH2_SO" ]]; then
    die "sasl-xoauth2 plugin not found. Install it according to INSTALLATION.md (section 25) and re-run."
fi
info "OK: sasl-xoauth2 → ${XOAUTH2_SO}"

if ! systemctl is-active --quiet postfix; then
    warn "Postfix is not active. The script will continue, but the daemon will not function until Postfix is running."
fi

# ── Source files ─────────────────────────────────────────────────────────────

section "Checking source files"

REQUIRED_FILES=(
    "opt/postfix-oauth2/config.py"
    "opt/postfix-oauth2/token_store.py"
    "opt/postfix-oauth2/token_daemon.py"
    "etc/systemd/system/postfix-oauth2.service"
    "etc/postfix-oauth2/config.yaml.example"
)

for f in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
        die "Missing file: ${SCRIPT_DIR}/${f}"
    fi
    info "OK: ${f}"
done

# ── System user ──────────────────────────────────────────────────────────────

section "System user"

if id "${DAEMON_USER}" &>/dev/null; then
    info "User ${DAEMON_USER} already exists."
else
    useradd \
        --system \
        --user-group \
        --home-dir /nonexistent \
        --shell /usr/sbin/nologin \
        "${DAEMON_USER}"
    info "Created user: ${DAEMON_USER}"
fi

if ! id "${DAEMON_USER}" | grep -q "postfix"; then
    usermod -aG postfix "${DAEMON_USER}"
    info "Added to group: postfix"
else
    info "Already a member of group: postfix"
fi

# ── Directory structure ──────────────────────────────────────────────────────

section "Directory structure"

install -d -o root -g "${DAEMON_USER}" -m 0750 "${APP_DIR}"
install -d -o root -g "${DAEMON_USER}" -m 0750 "${CONFIG_DIR}"
install -d -o root -g "${DAEMON_USER}" -m 0750 "${SECRET_DIR}"
install -d -o "${DAEMON_USER}" -g postfix -m 2770 "${TOKEN_DIR}"

info "Directories created:"
info "  ${APP_DIR}       (root:${DAEMON_USER} 0750)"
info "  ${CONFIG_DIR}    (root:${DAEMON_USER} 0750)"
info "  ${SECRET_DIR}    (root:${DAEMON_USER} 0750)"
info "  ${TOKEN_DIR}     (${DAEMON_USER}:postfix 2770 setgid)"

# ── Python virtual environment ───────────────────────────────────────────────

section "Python virtual environment"

if [[ ! -d "${VENV_DIR}" ]]; then
    # Ensure the venv module is available
    if ! python3 -m venv --help &>/dev/null 2>&1; then
        info "Installing python3-venv..."
        apt-get install -y python3-venv python3.12-venv 2>/dev/null || \
            apt-get install -y python3-venv
    fi

    python3 -m venv "${VENV_DIR}"
    info "Virtual environment created: ${VENV_DIR}"
else
    info "Virtual environment already exists: ${VENV_DIR}"
fi

"${VENV_DIR}/bin/pip" install --quiet --upgrade pip
"${VENV_DIR}/bin/pip" install --quiet requests PyYAML
info "Dependencies installed: requests, PyYAML"

# ── Daemon source files ──────────────────────────────────────────────────────

section "Daemon files"

install -o root -g "${DAEMON_USER}" -m 0640 \
    "${SCRIPT_DIR}/opt/postfix-oauth2/config.py" \
    "${APP_DIR}/config.py"

install -o root -g "${DAEMON_USER}" -m 0640 \
    "${SCRIPT_DIR}/opt/postfix-oauth2/token_store.py" \
    "${APP_DIR}/token_store.py"

install -o root -g "${DAEMON_USER}" -m 0640 \
    "${SCRIPT_DIR}/opt/postfix-oauth2/token_daemon.py" \
    "${APP_DIR}/token_daemon.py"

# Fix ownership on the venv after file installation
chown -R root:"${DAEMON_USER}" "${VENV_DIR}"
find "${VENV_DIR}" -type d -exec chmod 0750 {} \;

info "Files installed to: ${APP_DIR}"

# ── Python syntax check ──────────────────────────────────────────────────────

section "Syntax check"

sudo -u "${DAEMON_USER}" \
    "${VENV_DIR}/bin/python" - <<'PY'
import ast
from pathlib import Path
import sys

files = ["config.py", "token_store.py", "token_daemon.py"]
ok = True
for filename in files:
    try:
        source = Path(filename).read_text(encoding="utf-8")
        ast.parse(source, filename=filename)
        print(f"  OK: {filename}")
    except SyntaxError as exc:
        print(f"  ERROR: {filename}: {exc}", file=sys.stderr)
        ok = False

sys.exit(0 if ok else 1)
PY

sudo -u "${DAEMON_USER}" \
    "${VENV_DIR}/bin/python" \
    -c "import requests, yaml; print('  OK: requests, PyYAML importable')"

# ── Configuration file ───────────────────────────────────────────────────────

section "Configuration"

CONFIG_TARGET="${CONFIG_DIR}/config.yaml"
CONFIG_EXAMPLE="${SCRIPT_DIR}/etc/postfix-oauth2/config.yaml.example"

if [[ -f "${CONFIG_TARGET}" ]]; then
    warn "Configuration already exists: ${CONFIG_TARGET}"
    warn "Leaving existing configuration untouched."
else
    install -o root -g "${DAEMON_USER}" -m 0640 \
        "${CONFIG_EXAMPLE}" \
        "${CONFIG_TARGET}"
    info "Configuration copied to: ${CONFIG_TARGET}"
    warn "Edit the configuration before starting the daemon:"
    warn "  sudo nano ${CONFIG_TARGET}"
fi

# ── Systemd service unit ─────────────────────────────────────────────────────

section "systemd service unit"

install -o root -g root -m 0644 \
    "${SCRIPT_DIR}/etc/systemd/system/postfix-oauth2.service" \
    "${SERVICE_FILE}"

systemctl daemon-reload
info "Service unit installed: ${SERVICE_FILE}"

VERIFY_OUT=$(systemd-analyze verify "${SERVICE_FILE}" 2>&1 || true)
if [[ -n "$VERIFY_OUT" ]]; then
    warn "systemd-analyze verify reported:"
    warn "${VERIFY_OUT}"
else
    info "OK: systemd-analyze verify — no warnings"
fi

# ── Postfix smtp chroot check ────────────────────────────────────────────────

section "Postfix chroot check"

SMTP_CHROOT=$(postconf -M smtp/unix 2>/dev/null | awk '{print $5}' || echo "?")

if [[ "$SMTP_CHROOT" == "y" ]]; then
    warn "The outbound smtp/unix transport is running in a chroot (chroot=y)."
    warn "Token files will not be accessible. Fix in /etc/postfix/master.cf:"
    warn "  smtp      unix  -       -       n       -       -       smtp"
    warn "Then run: sudo systemctl restart postfix"
elif [[ "$SMTP_CHROOT" == "n" ]]; then
    info "OK: smtp/unix chroot=n"
else
    warn "Could not verify chroot setting for smtp/unix transport."
fi

# ── Next steps ───────────────────────────────────────────────────────────────

section "Installation complete"

echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo ""
echo "  1. Create the client secret file:"
echo "       sudo nano ${SECRET_DIR}/m365-primary.secret"
echo "       (content: the raw client secret value, no quotes)"
echo "       sudo chown root:${DAEMON_USER} ${SECRET_DIR}/m365-primary.secret"
echo "       sudo chmod 0640 ${SECRET_DIR}/m365-primary.secret"
echo ""
echo "  2. Edit the configuration (tenant_id, client_id, mailboxes):"
echo "       sudo nano ${CONFIG_TARGET}"
echo ""
echo "  3. Test the configuration:"
echo "       cd ${APP_DIR} && sudo -u ${DAEMON_USER} \\"
echo "         ${VENV_DIR}/bin/python -c \\"
echo "         \"from config import load_config; print(load_config('${CONFIG_TARGET}'))\""
echo ""
echo "  4. Start the daemon:"
echo "       sudo systemctl start ${SERVICE_NAME}"
echo "       sudo journalctl -u ${SERVICE_NAME} -n 20 --no-pager"
echo ""
echo "  5. Enable autostart after a successful test:"
echo "       sudo systemctl enable ${SERVICE_NAME}"
echo ""
echo -e "${BOLD}Documentation:${RESET} INSTALLATION.md"
echo ""
