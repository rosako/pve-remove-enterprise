#!/usr/bin/env bash
#
# Self-contained installer for the security-lab VPS (WireGuard hub + dashboard).
# Upload this ONE file to the VPS and run as root:
#
#   sudo DOMAIN=lab.example.ch CERTBOT_EMAIL=you@hepia.ch \
#        ADMIN_USER=admin ADMIN_PASSWORD='strong-pass' bash install-vps.sh
#
# Or just `sudo bash install-vps.sh` and it will prompt for the required values.
# Missing values are prompted only if a terminal is attached.
#
# Sub-command, run later once the Proxmox host reports its WireGuard pubkey:
#   sudo bash install-vps.sh add-proxmox <PROXMOX_PUBKEY>
#
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/lab-dashboard}"
ENV_DIR="${ENV_DIR:-/etc/lab-dashboard}"
DATA_DIR="${DATA_DIR:-/var/lib/lab-dashboard}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
ENV_FILE="$ENV_DIR/dashboard.env"

# Load dashboard.env WITHOUT shell expansion: the werkzeug password hash and
# other values legitimately contain '$', which `source` would try to expand.
load_env() {
  # Split on the FIRST '=' only and keep the rest verbatim. Using `IFS== read`
  # would strip the trailing '=' base64 padding off WireGuard keys / SECRET_KEY.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == [A-Z]*=* ]] || continue
    local k="${line%%=*}" v="${line#*=}"
    printf -v "$k" '%s' "$v"; export "$k"
  done < "$ENV_FILE"
}

# ---- sub-command: register the Proxmox site peer -------------------------- #
if [[ "${1:-}" == "add-proxmox" ]]; then
  PUBKEY="${2:?usage: install-vps.sh add-proxmox <PROXMOX_PUBKEY>}"
  sed -i "s|^WG_PROXMOX_PUBKEY=.*|WG_PROXMOX_PUBKEY=$PUBKEY|" "$ENV_FILE"
  load_env
  ( cd "$APP_DIR" && "$APP_DIR/venv/bin/python" -c \
    "import db, wg; wg.regenerate(db.all_students(), apply=False)" )
  # Restart (not just syncconf) so wg-quick re-reads the config and installs the
  # route to the lab subnet via wg0 — syncconf updates crypto only, not routes.
  systemctl restart wg-quick@wg0
  # Allow forwarding of tunnel traffic across the hub (student <-> Proxmox site).
  ufw route allow in on wg0 out on wg0 >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true
  systemctl restart lab-dashboard
  echo "Proxmox peer registered; wg0 restarted with lab route + forwarding."
  echo "--- routes via wg0 ---"; ip route | grep wg0 || echo "(none!)"
  echo "--- wg0 ---"; wg show wg0
  exit 0
fi

# ---- config (env-overridable, prompt if attached to a TTY) ---------------- #
prompt() {  # var, message, secret?
  local cur="${!1:-}"
  if [[ -z "$cur" ]]; then
    if [[ -t 0 ]]; then
      if [[ "${3:-}" == "secret" ]]; then read -rsp "$2: " cur; echo; else read -rp "$2: " cur; fi
    fi
  fi
  printf -v "$1" '%s' "$cur"
}
ADMIN_USER="${ADMIN_USER:-admin}"
prompt DOMAIN "Domain (A record must already point here, e.g. lab.example.ch)"
prompt CERTBOT_EMAIL "Email for Let's Encrypt"
prompt ADMIN_PASSWORD "Admin dashboard password" secret
: "${DOMAIN:?DOMAIN is required}"
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL is required}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"
PROXMOX_PUBKEY="${PROXMOX_PUBKEY:-}"
# Preserve an already-registered Proxmox peer across re-runs unless overridden.
if [[ -z "$PROXMOX_PUBKEY" && -f "$ENV_FILE" ]]; then
  PROXMOX_PUBKEY="$(sed -n 's/^WG_PROXMOX_PUBKEY=//p' "$ENV_FILE" | head -n1)"
fi

WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"
WG_TUNNEL_CIDR="${WG_TUNNEL_CIDR:-10.66.0.0/24}"
WG_SERVER_ADDR="${WG_SERVER_ADDR:-10.66.0.1}"
WG_LAB_CIDR="${WG_LAB_CIDR:-10.66.10.0/24}"
WG_PROXMOX_TUNNEL_IP="${WG_PROXMOX_TUNNEL_IP:-10.66.0.2}"

# ---- write the embedded dashboard application ----------------------------- #
echo "==> Writing dashboard application to $APP_DIR"
mkdir -p "$APP_DIR"
cat > "$APP_DIR/requirements.txt" <<'LAB_EMBED_EOF'
Flask==3.0.3
gunicorn==22.0.0
LAB_EMBED_EOF
cat > "$APP_DIR/app.py" <<'LAB_EMBED_EOF'
"""Lab dashboard: manage WireGuard students, hand out profiles + instructions.

Routes
------
  /                 admin: login-gated dashboard (create student, CSV import, list)
  /login /logout    admin auth
  /student/<id>/... admin actions (revoke / activate / delete)
  /s/<token>        public per-student page (secret URL): instructions + download
  /s/<token>/wg     public download of that student's .conf

The admin panel is behind a login. Per-student pages use an unguessable token so
students can fetch their profile *before* they are on the VPN, without the roster
being publicly listable.
"""
import csv
import io
import os
import re
import secrets
from functools import wraps

from flask import (
    Flask, Response, abort, flash, redirect, render_template,
    request, session, url_for,
)
from werkzeug.security import check_password_hash, generate_password_hash

import db
import wg

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "dev-insecure-key")

ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_HASH = os.environ.get("ADMIN_PASSWORD_HASH", "")
BASE_URL = os.environ.get("BASE_URL", "").rstrip("/")

db.init_db()


# --------------------------------------------------------------------------- #
# auth
# --------------------------------------------------------------------------- #
def login_required(fn):
    @wraps(fn)
    def wrapper(*a, **kw):
        if not session.get("admin"):
            return redirect(url_for("login", next=request.path))
        return fn(*a, **kw)
    return wrapper


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        user = request.form.get("username", "")
        pw = request.form.get("password", "")
        if user == ADMIN_USER and ADMIN_HASH and check_password_hash(ADMIN_HASH, pw):
            session["admin"] = True
            return redirect(request.args.get("next") or url_for("index"))
        flash("Invalid credentials.", "error")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def _sync():
    """Regenerate + apply the WireGuard server config from current DB state."""
    wg.regenerate(db.all_students(), apply=True)


def _create_student(name, email):
    """Create one student: keypair, IP, DB row. Returns (row_or_None, error)."""
    name = (name or "").strip()
    email = (email or "").strip()
    if not name:
        return None, "empty name"
    ip = wg.allocate_ip(db.used_ips())
    if not ip:
        return None, "IP pool exhausted"
    priv, pub = wg.gen_keypair()
    token = secrets.token_urlsafe(24)
    sid = db.insert_student(name, email, token, ip, priv, pub)
    return db.student_by_id(sid), None


def _slug(name):
    return re.sub(r"[^a-zA-Z0-9._-]+", "_", name).strip("_") or "student"


# --------------------------------------------------------------------------- #
# admin
# --------------------------------------------------------------------------- #
ROSTER_PW_KEY = "roster_pw_hash"


@app.route("/")
@login_required
def index():
    students = db.all_students()
    return render_template("admin.html", students=students, base_url=BASE_URL,
                           lab_cidr=wg.LAB_CIDR,
                           roster_set=bool(db.get_setting(ROSTER_PW_KEY)))


@app.route("/roster-password", methods=["POST"])
@login_required
def roster_password():
    pw = request.form.get("roster_password", "")
    if not pw:
        flash("Le mot de passe ne peut pas être vide.", "error")
    else:
        db.set_setting(ROSTER_PW_KEY, generate_password_hash(pw))
        flash("Mot de passe de la liste partagée mis à jour.", "ok")
    return redirect(url_for("index"))


@app.route("/create", methods=["POST"])
@login_required
def create():
    row, err = _create_student(request.form.get("name"), request.form.get("email"))
    if err:
        flash(f"Could not create student: {err}", "error")
    else:
        _sync()
        flash(f"Created {row['name']} ({row['tunnel_ip']}).", "ok")
    return redirect(url_for("index"))


@app.route("/import", methods=["POST"])
@login_required
def import_csv():
    f = request.files.get("csv")
    if not f:
        flash("No file uploaded.", "error")
        return redirect(url_for("index"))
    text = f.read().decode("utf-8-sig", errors="replace")
    reader = csv.reader(io.StringIO(text))
    created, skipped = 0, 0
    for i, cols in enumerate(reader):
        if not cols or not cols[0].strip():
            continue
        first = cols[0].strip().lower()
        if i == 0 and first in ("name", "student", "nom"):  # header row
            continue
        name = cols[0].strip()
        email = cols[1].strip() if len(cols) > 1 else ""
        row, err = _create_student(name, email)
        if err:
            skipped += 1
        else:
            created += 1
    if created:
        _sync()
    flash(f"Imported {created} student(s), skipped {skipped}.", "ok" if created else "error")
    return redirect(url_for("index"))


@app.route("/student/<int:sid>/<action>", methods=["POST"])
@login_required
def student_action(sid, action):
    row = db.student_by_id(sid)
    if not row:
        abort(404)
    if action == "revoke":
        db.set_active(sid, False)
        _sync()
        flash(f"Revoked {row['name']}.", "ok")
    elif action == "activate":
        db.set_active(sid, True)
        _sync()
        flash(f"Reactivated {row['name']}.", "ok")
    elif action == "delete":
        db.delete_student(sid)
        _sync()
        flash(f"Deleted {row['name']}.", "ok")
    else:
        abort(400)
    return redirect(url_for("index"))


# --------------------------------------------------------------------------- #
# public per-student pages (secret token)
# --------------------------------------------------------------------------- #
@app.route("/s/<token>")
def student_page(token):
    row = db.student_by_token(token)
    if not row:
        abort(404)
    return render_template("student.html", s=row, active=bool(row["active"]),
                           endpoint=wg.ENDPOINT, lab_cidr=wg.LAB_CIDR)


@app.route("/s/<token>/wg")
def student_conf(token):
    row = db.student_by_token(token)
    if not row or not row["active"]:
        abort(404)
    conf = wg.client_config(row)
    fname = f"lab-{_slug(row['name'])}.conf"
    return Response(
        conf,
        mimetype="text/plain",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )


@app.route("/roster", methods=["GET", "POST"])
def roster():
    pw_hash = db.get_setting(ROSTER_PW_KEY)
    if not pw_hash:
        return render_template("roster.html", configured=False, unlocked=False)
    if request.method == "POST":
        if check_password_hash(pw_hash, request.form.get("password", "")):
            session["roster"] = True
        else:
            flash("Mot de passe incorrect.", "error")
    if not session.get("roster"):
        return render_template("roster.html", configured=True, unlocked=False)
    return render_template("roster.html", configured=True, unlocked=True,
                           students=db.active_students())


@app.route("/roster/logout")
def roster_logout():
    session.pop("roster", None)
    return redirect(url_for("roster"))


@app.route("/healthz")
def healthz():
    return "ok\n", 200


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000, debug=True)
LAB_EMBED_EOF
cat > "$APP_DIR/db.py" <<'LAB_EMBED_EOF'
"""SQLite persistence for the lab dashboard.

One table: students. The DB is the source of truth for WireGuard peers; the
server config file (wg0.conf) is regenerated from it (see wg.py).
"""
import os
import sqlite3
from contextlib import contextmanager

_DB_PATH = os.environ.get("DB_PATH", "/var/lib/lab-dashboard/lab.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS students (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT    NOT NULL,
    email        TEXT    NOT NULL DEFAULT '',
    token        TEXT    NOT NULL UNIQUE,      -- secret URL slug for the student page
    tunnel_ip    TEXT    NOT NULL UNIQUE,      -- e.g. 10.66.0.11
    privkey      TEXT    NOT NULL,             -- client WG private key
    pubkey       TEXT    NOT NULL,             -- client WG public key
    active       INTEGER NOT NULL DEFAULT 1,   -- 0 = revoked (peer removed)
    created_at   TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


@contextmanager
def get_db():
    os.makedirs(os.path.dirname(_DB_PATH), exist_ok=True)
    conn = sqlite3.connect(_DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db():
    with get_db() as conn:
        conn.executescript(SCHEMA)


def all_students(include_inactive=True):
    q = "SELECT * FROM students"
    if not include_inactive:
        q += " WHERE active = 1"
    q += " ORDER BY tunnel_ip"
    with get_db() as conn:
        # numeric-ish sort on last octet
        rows = list(conn.execute(q))
    rows.sort(key=lambda r: int(r["tunnel_ip"].split(".")[-1]))
    return rows


def active_students():
    return [r for r in all_students() if r["active"]]


def student_by_token(token):
    with get_db() as conn:
        return conn.execute(
            "SELECT * FROM students WHERE token = ?", (token,)
        ).fetchone()


def student_by_id(sid):
    with get_db() as conn:
        return conn.execute("SELECT * FROM students WHERE id = ?", (sid,)).fetchone()


def used_ips():
    with get_db() as conn:
        return {r["tunnel_ip"] for r in conn.execute("SELECT tunnel_ip FROM students")}


def insert_student(name, email, token, tunnel_ip, privkey, pubkey):
    with get_db() as conn:
        cur = conn.execute(
            "INSERT INTO students (name, email, token, tunnel_ip, privkey, pubkey) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (name, email, token, tunnel_ip, privkey, pubkey),
        )
        return cur.lastrowid


def set_active(sid, active):
    with get_db() as conn:
        conn.execute("UPDATE students SET active = ? WHERE id = ?", (1 if active else 0, sid))


def delete_student(sid):
    with get_db() as conn:
        conn.execute("DELETE FROM students WHERE id = ?", (sid,))


# ---- key/value settings (e.g. the shared roster password hash) ---- #
def get_setting(key, default=None):
    with get_db() as conn:
        row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else default


def set_setting(key, value):
    with get_db() as conn:
        conn.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )
LAB_EMBED_EOF
cat > "$APP_DIR/wg.py" <<'LAB_EMBED_EOF'
"""WireGuard peer management for the lab dashboard.

Design: the SQLite DB is the source of truth. On every change we regenerate the
whole server config (wg0.conf) from a template + the active students, write it
atomically, then apply it live with `wg syncconf` so existing tunnels are not
torn down. The Proxmox site peer is injected from config (it advertises the lab
subnet); student peers are pinned to a single /32 each.
"""
import ipaddress
import os
import subprocess
import tempfile

# ---- config pulled from environment (see config.example.env) ----
IFACE = os.environ.get("WG_INTERFACE", "wg0")
CONF_PATH = os.environ.get("WG_CONF_PATH", "/etc/wireguard/wg0.conf")
LISTEN_PORT = os.environ.get("WG_LISTEN_PORT", "51820")
ENDPOINT = os.environ.get("WG_ENDPOINT", "lab.example.ch:51820")
SERVER_PRIVKEY = os.environ.get("WG_SERVER_PRIVKEY", "")
SERVER_PUBKEY = os.environ.get("WG_SERVER_PUBKEY", "")
TUNNEL_CIDR = os.environ.get("WG_TUNNEL_CIDR", "10.66.0.0/24")
SERVER_ADDR = os.environ.get("WG_SERVER_ADDR", "10.66.0.1")
STUDENT_START = int(os.environ.get("WG_STUDENT_START", "11"))
STUDENT_END = int(os.environ.get("WG_STUDENT_END", "250"))
LAB_CIDR = os.environ.get("WG_LAB_CIDR", "10.66.10.0/24")
PROXMOX_PUBKEY = os.environ.get("WG_PROXMOX_PUBKEY", "")
PROXMOX_TUNNEL_IP = os.environ.get("WG_PROXMOX_TUNNEL_IP", "10.66.0.2")
CLIENT_DNS = os.environ.get("WG_CLIENT_DNS", "").strip()


def gen_keypair():
    """Return (private_key, public_key) using the wg binary."""
    priv = subprocess.run(["wg", "genkey"], capture_output=True, text=True, check=True).stdout.strip()
    pub = subprocess.run(
        ["wg", "pubkey"], input=priv, capture_output=True, text=True, check=True
    ).stdout.strip()
    return priv, pub


def allocate_ip(used):
    """Lowest free student IP in the tunnel network, or None if exhausted."""
    net = ipaddress.ip_network(TUNNEL_CIDR)
    base = str(net.network_address).rsplit(".", 1)[0]  # e.g. "10.66.0"
    for octet in range(STUDENT_START, STUDENT_END + 1):
        ip = f"{base}.{octet}"
        if ip not in used:
            return ip
    return None


def client_config(student):
    """Render a ready-to-import wg-quick client config for one student."""
    prefix = ipaddress.ip_network(TUNNEL_CIDR).prefixlen
    dns_line = f"DNS = {CLIENT_DNS}\n" if CLIENT_DNS else ""
    return (
        "[Interface]\n"
        f"PrivateKey = {student['privkey']}\n"
        f"Address = {student['tunnel_ip']}/{prefix}\n"
        f"{dns_line}"
        "\n"
        "[Peer]\n"
        f"PublicKey = {SERVER_PUBKEY}\n"
        f"Endpoint = {ENDPOINT}\n"
        f"AllowedIPs = {TUNNEL_CIDR}, {LAB_CIDR}\n"
        "PersistentKeepalive = 25\n"
    )


def _render_server_conf(students):
    prefix = ipaddress.ip_network(TUNNEL_CIDR).prefixlen
    parts = [
        "# Managed by lab-dashboard. Manual edits below the marker are overwritten.\n"
        "[Interface]\n"
        f"Address = {SERVER_ADDR}/{prefix}\n"
        f"ListenPort = {LISTEN_PORT}\n"
        f"PrivateKey = {SERVER_PRIVKEY}\n"
    ]
    if PROXMOX_PUBKEY:
        parts.append(
            "\n# --- Proxmox site peer (routes the lab subnet) ---\n"
            "[Peer]\n"
            f"PublicKey = {PROXMOX_PUBKEY}\n"
            f"AllowedIPs = {PROXMOX_TUNNEL_IP}/32, {LAB_CIDR}\n"
        )
    parts.append("\n# --- student peers (managed) ---\n")
    for s in students:
        parts.append(
            "[Peer]\n"
            f"# {s['name']} <{s['email']}>\n"
            f"PublicKey = {s['pubkey']}\n"
            f"AllowedIPs = {s['tunnel_ip']}/32\n\n"
        )
    return "".join(parts)


def regenerate(students, apply=True):
    """Write wg0.conf from active students and (optionally) apply it live."""
    conf = _render_server_conf([s for s in students if s["active"]])
    d = os.path.dirname(CONF_PATH)
    fd, tmp = tempfile.mkstemp(dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(conf)
        os.chmod(tmp, 0o600)
        os.replace(tmp, CONF_PATH)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    if apply:
        apply_live()


def apply_live():
    """Apply CONF_PATH to the running interface without dropping tunnels.

    `wg syncconf` needs the stripped form (no Address/DNS/PostUp lines).
    """
    try:
        up = subprocess.run(["ip", "link", "show", IFACE], capture_output=True).returncode == 0
    except FileNotFoundError:
        return  # no `ip` (e.g. non-Linux dev box) — nothing to apply
    if not up:
        # interface not up yet (e.g. first run before wg-quick up) — skip.
        return
    stripped = subprocess.run(
        ["wg-quick", "strip", IFACE], capture_output=True, text=True, check=True
    ).stdout
    with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
        f.write(stripped)
        tmp = f.name
    try:
        subprocess.run(["wg", "syncconf", IFACE, tmp], check=True)
    finally:
        os.unlink(tmp)
LAB_EMBED_EOF
mkdir -p "$APP_DIR/templates"
cat > "$APP_DIR/templates/base.html" <<'LAB_EMBED_EOF'
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{% block title %}Laboratoire de sécurité{% endblock %}</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='style.css') }}">
</head>
<body>
  <header class="topbar">
    <span class="brand">Laboratoire de sécurité</span>
    {% if session.admin %}<a class="right" href="{{ url_for('logout') }}">Déconnexion</a>{% endif %}
  </header>
  <main>
    {% with msgs = get_flashed_messages(with_categories=true) %}
      {% for cat, m in msgs %}<div class="flash {{ cat }}">{{ m }}</div>{% endfor %}
    {% endwith %}
    {% block content %}{% endblock %}
  </main>
</body>
</html>
LAB_EMBED_EOF
mkdir -p "$APP_DIR/templates"
cat > "$APP_DIR/templates/login.html" <<'LAB_EMBED_EOF'
{% extends "base.html" %}
{% block title %}Connexion administrateur — Laboratoire de sécurité{% endblock %}
{% block content %}
<div class="card narrow">
  <h1>Connexion administrateur</h1>
  <form method="post" autocomplete="off">
    <label>Nom d'utilisateur <input name="username" required autofocus></label>
    <label>Mot de passe <input name="password" type="password" required></label>
    <button type="submit">Se connecter</button>
  </form>
</div>
{% endblock %}
LAB_EMBED_EOF
mkdir -p "$APP_DIR/templates"
cat > "$APP_DIR/templates/admin.html" <<'LAB_EMBED_EOF'
{% extends "base.html" %}
{% block title %}Tableau de bord — Laboratoire de sécurité{% endblock %}
{% block content %}
<div class="grid">
  <div class="card">
    <h2>Ajouter un étudiant</h2>
    <form method="post" action="{{ url_for('create') }}">
      <label>Nom <input name="name" required placeholder="Ada Lovelace"></label>
      <label>Courriel <input name="email" type="email" placeholder="ada@hepia.ch"></label>
      <button type="submit">Créer</button>
    </form>
  </div>
  <div class="card">
    <h2>Importer un CSV</h2>
    <p class="muted">Colonnes : <code>nom,courriel</code> (en-tête facultatif). Un étudiant par ligne.</p>
    <form method="post" action="{{ url_for('import_csv') }}" enctype="multipart/form-data">
      <input type="file" name="csv" accept=".csv,text/csv" required>
      <button type="submit">Importer</button>
    </form>
  </div>
</div>

<div class="card">
  <h2>Liste partagée des étudiants</h2>
  <p class="muted">Page unique à distribuer à toute la classe : chaque étudiant y retrouve
    son lien personnel. Elle est protégée par le mot de passe ci-dessous.</p>
  <div class="row-between wrap">
    <span>Lien : <a href="{{ base_url }}/roster" target="_blank">{{ base_url }}/roster</a>
      <button class="link copy" data-link="{{ base_url }}/roster">copier le lien</button></span>
    <span class="muted">{% if roster_set %}Mot de passe défini{% else %}Mot de passe non défini{% endif %}</span>
  </div>
  <form method="post" action="{{ url_for('roster_password') }}" class="inline-form">
    <label>{% if roster_set %}Modifier le{% else %}Définir le{% endif %} mot de passe de la liste
      <input name="roster_password" type="text" required placeholder="mot de passe à partager"></label>
    <button type="submit">Enregistrer</button>
  </form>
</div>

<div class="card">
  <div class="row-between">
    <h2>Étudiants <span class="muted">({{ students|length }})</span></h2>
    <span class="muted">Sous-réseau à scanner : <code>{{ lab_cidr }}</code></span>
  </div>
  {% if not students %}
    <p class="muted">Aucun étudiant pour l'instant. Ajoutez-en un ci-dessus ou importez un CSV.</p>
  {% else %}
  <table>
    <thead>
      <tr><th>Nom</th><th>IP du tunnel</th><th>Statut</th><th>Page étudiant</th><th></th></tr>
    </thead>
    <tbody>
      {% for s in students %}
      <tr class="{{ '' if s['active'] else 'revoked' }}">
        <td>{{ s['name'] }}<br><span class="muted small">{{ s['email'] }}</span></td>
        <td><code>{{ s['tunnel_ip'] }}</code></td>
        <td>{% if s['active'] %}<span class="badge ok">actif</span>{% else %}<span class="badge off">révoqué</span>{% endif %}</td>
        <td>
          <a href="{{ base_url }}/s/{{ s['token'] }}" target="_blank">ouvrir</a>
          <button class="link copy" data-link="{{ base_url }}/s/{{ s['token'] }}">copier le lien</button>
        </td>
        <td class="actions">
          {% if s['active'] %}
          <form method="post" action="{{ url_for('student_action', sid=s['id'], action='revoke') }}"><button class="warn">révoquer</button></form>
          {% else %}
          <form method="post" action="{{ url_for('student_action', sid=s['id'], action='activate') }}"><button>réactiver</button></form>
          {% endif %}
          <form method="post" action="{{ url_for('student_action', sid=s['id'], action='delete') }}" onsubmit="return confirm('Supprimer {{ s['name'] }} ? Cela retire son accès VPN.');"><button class="danger">supprimer</button></form>
        </td>
      </tr>
      {% endfor %}
    </tbody>
  </table>
  {% endif %}
</div>

<script>
document.querySelectorAll('.copy').forEach(b => b.addEventListener('click', () => {
  navigator.clipboard.writeText(b.dataset.link).then(() => { const t = b.textContent; b.textContent = 'copié !'; setTimeout(() => b.textContent = t, 1200); });
}));
</script>
{% endblock %}
LAB_EMBED_EOF
mkdir -p "$APP_DIR/templates"
cat > "$APP_DIR/templates/student.html" <<'LAB_EMBED_EOF'
{% extends "base.html" %}
{% block title %}{{ s['name'] }} — Accès au laboratoire{% endblock %}
{% block content %}
<div class="card">
  <h1>Bienvenue, {{ s['name'] }}</h1>
  {% if not active %}
    <div class="flash error">Votre accès a été révoqué. Contactez votre enseignant.</div>
  {% else %}
  <p>Cette page vous fournit votre profil VPN personnel pour le laboratoire de sécurité
     et explique comment vous connecter. Votre accès est lié à ce lien : gardez-le privé.</p>

  <div class="downloadbox">
    <a class="bigbtn" href="{{ url_for('student_conf', token=s['token']) }}">Télécharger votre profil WireGuard</a>
    <p class="muted small">Votre adresse IP : <code>{{ s['tunnel_ip'] }}</code></p>
  </div>

  <h2>1. Installer WireGuard</h2>
  <ul class="platforms">
    <li><b>Windows / macOS</b> : téléchargez l'application depuis
      <a href="https://www.wireguard.com/install/" target="_blank" rel="noopener">wireguard.com/install</a>.</li>
    <li><b>iOS / Android</b> : installez <em>WireGuard</em> depuis l'App Store / le Play Store.</li>
    <li><b>Linux</b> : <code>sudo apt install wireguard</code> (Debian/Ubuntu) ou le paquet de votre distribution.</li>
  </ul>

  <h2>2. Importer votre profil</h2>
  <ul class="platforms">
    <li><b>Application de bureau</b> : <em>Importer un ou des tunnels depuis un fichier</em>,
      puis choisissez le fichier <code>.conf</code> téléchargé, puis <em>Activer</em>.</li>
    <li><b>Téléphone</b> : appuyez sur le bouton d'ajout, puis <em>Importer depuis un fichier</em>, puis activez le tunnel.</li>
    <li><b>Linux (ligne de commande)</b> : placez le fichier dans <code>/etc/wireguard/lab.conf</code>,
      puis <code>sudo wg-quick up lab</code> (arrêt : <code>sudo wg-quick down lab</code>).</li>
  </ul>

  <h2>3. Vérifier la connexion</h2>
  <p>Une fois le tunnel actif, vérifiez que vous atteignez la passerelle du laboratoire :</p>
  <pre>ping 10.66.0.1</pre>

  <h2>4. Scanner le laboratoire</h2>
  <p>Les machines cibles se trouvent dans <code>{{ lab_cidr }}</code>. Découvrez les hôtes actifs,
     puis scannez-en un :</p>
  <pre># découvrir les hôtes actifs
nmap -sn {{ lab_cidr }}

# scanner les services d'un hôte découvert
nmap -sV -sC 10.66.10.11</pre>
  <p class="muted small">Ne scannez que les hôtes situés dans <code>{{ lab_cidr }}</code>. Scanner
     quoi que ce soit d'autre via ce VPN est hors périmètre.</p>
  {% endif %}
</div>
{% endblock %}
LAB_EMBED_EOF
mkdir -p "$APP_DIR/templates"
cat > "$APP_DIR/templates/roster.html" <<'LAB_EMBED_EOF'
{% extends "base.html" %}
{% block title %}Liste des étudiants — Laboratoire de sécurité{% endblock %}
{% block content %}
{% if not configured %}
  <div class="card narrow">
    <h1>Liste non disponible</h1>
    <p class="muted">Cette page n'a pas encore été activée par l'enseignant.</p>
  </div>
{% elif not unlocked %}
  <div class="card narrow">
    <h1>Accès à la liste</h1>
    <p class="muted">Saisissez le mot de passe fourni par votre enseignant.</p>
    <form method="post" autocomplete="off">
      <label>Mot de passe <input name="password" type="password" required autofocus></label>
      <button type="submit">Accéder</button>
    </form>
  </div>
{% else %}
  <div class="card">
    <div class="row-between">
      <h1>Étudiants</h1>
      <a class="muted" href="{{ url_for('roster_logout') }}">Verrouiller</a>
    </div>
    <p class="muted">Trouvez votre nom, puis ouvrez votre page personnelle pour télécharger
      votre profil WireGuard et suivre les instructions.</p>
    {% if not students %}
      <p class="muted">Aucun étudiant pour l'instant.</p>
    {% else %}
    <table>
      <thead><tr><th>Nom</th><th>Courriel</th><th>Configuration</th></tr></thead>
      <tbody>
        {% for s in students %}
        <tr>
          <td>{{ s['name'] }}</td>
          <td class="muted">{{ s['email'] }}</td>
          <td><a href="{{ url_for('student_page', token=s['token']) }}">Ouvrir ma page</a></td>
        </tr>
        {% endfor %}
      </tbody>
    </table>
    {% endif %}
  </div>
{% endif %}
{% endblock %}
LAB_EMBED_EOF
mkdir -p "$APP_DIR/static"
cat > "$APP_DIR/static/style.css" <<'LAB_EMBED_EOF'
:root {
  --bg: #ffffff; --panel: #ffffff; --panel2: #f6f7f9; --ink: #1a1d24;
  --muted: #6b7280; --line: #e3e6ea; --accent: #2563eb; --accent-ink: #1d4ed8;
  --ok: #15803d; --ok-bg: #ecfdf3; --danger: #b91c1c; --danger-bg: #fef2f2;
  --warn: #b45309; --radius: 10px;
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--ink);
  font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Ubuntu, sans-serif;
}
.topbar {
  display: flex; align-items: center; gap: 1rem; padding: .8rem 1.2rem;
  background: #fff; border-bottom: 1px solid var(--line);
}
.brand { font-weight: 700; letter-spacing: .2px; }
.topbar .right { margin-left: auto; color: var(--muted); text-decoration: none; }
.topbar .right:hover { color: var(--ink); }
main { max-width: 940px; margin: 1.4rem auto; padding: 0 1rem; }
h1 { font-size: 1.5rem; margin: .2rem 0 1rem; }
h2 { font-size: 1.1rem; margin: 1.3rem 0 .6rem; }
a { color: var(--accent); }
a:hover { color: var(--accent-ink); }
code {
  background: var(--panel2); padding: .1rem .35rem; border-radius: 6px;
  font-size: .9em; border: 1px solid var(--line);
}
pre {
  background: var(--panel2); border: 1px solid var(--line); border-radius: 10px;
  padding: .9rem 1rem; overflow-x: auto; color: #111827;
}
.card {
  background: var(--panel); border: 1px solid var(--line); border-radius: var(--radius);
  padding: 1.1rem 1.2rem; margin-bottom: 1.1rem; box-shadow: 0 1px 2px rgba(16,24,40,.04);
}
.card.narrow { max-width: 380px; margin: 3rem auto; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1.1rem; }
@media (max-width: 640px) { .grid { grid-template-columns: 1fr; } }
label { display: block; margin: .6rem 0; color: var(--muted); font-size: .85rem; }
input {
  display: block; width: 100%; margin-top: .25rem; padding: .55rem .7rem;
  background: #fff; border: 1px solid var(--line); border-radius: 8px;
  color: var(--ink); font-size: .95rem;
}
input:focus { outline: 2px solid rgba(37,99,235,.35); border-color: var(--accent); }
input[type=file] { padding: .4rem; }
button, .bigbtn {
  cursor: pointer; border: 1px solid transparent; border-radius: 8px; padding: .55rem .9rem;
  background: var(--accent); color: #fff; font-weight: 600; font-size: .9rem;
}
button:hover { filter: brightness(.96); }
button.warn { background: var(--warn); } button.danger { background: var(--danger); }
button.link { background: none; color: var(--accent); border: 0; padding: .2rem .3rem; font-weight: 500; }
button.link:hover { text-decoration: underline; }
.inline-form { display: flex; align-items: flex-end; gap: .6rem; flex-wrap: wrap; margin-top: .6rem; }
.inline-form label { flex: 1 1 260px; margin: 0; }
table { width: 100%; border-collapse: collapse; margin-top: .6rem; }
th, td { text-align: left; padding: .55rem .5rem; border-bottom: 1px solid var(--line); vertical-align: top; }
th { color: var(--muted); font-size: .78rem; text-transform: uppercase; letter-spacing: .4px; }
tr.revoked { opacity: .55; }
.actions { display: flex; gap: .4rem; flex-wrap: wrap; }
.actions form { margin: 0; }
.badge { padding: .1rem .5rem; border-radius: 999px; font-size: .75rem; font-weight: 700; }
.badge.ok { background: var(--ok-bg); color: var(--ok); }
.badge.off { background: var(--danger-bg); color: var(--danger); }
.muted { color: var(--muted); } .small { font-size: .82rem; }
.row-between { display: flex; align-items: baseline; justify-content: space-between; gap: 1rem; }
.row-between.wrap { flex-wrap: wrap; }
.flash { padding: .6rem .9rem; border-radius: 8px; margin-bottom: 1rem; border: 1px solid transparent; }
.flash.ok { background: var(--ok-bg); border-color: #bbf7d0; color: var(--ok); }
.flash.error { background: var(--danger-bg); border-color: #fecaca; color: var(--danger); }
.downloadbox { text-align: center; margin: 1.4rem 0; }
.bigbtn { display: inline-block; text-decoration: none; font-size: 1.05rem; padding: .85rem 1.4rem; }
.platforms { padding-left: 1.1rem; } .platforms li { margin: .35rem 0; }
LAB_EMBED_EOF

# Files-only mode: used to verify the installer without touching the system.
if [[ -n "${LAB_FILES_ONLY:-}" ]]; then echo "(files-only mode: stopping)"; exit 0; fi

echo "==> [1/8] Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard-tools nginx certbot python3-certbot-nginx \
                      python3-venv python3-pip sqlite3 ufw curl >/dev/null
# Kernel WireGuard is in-tree on Ubuntu's kernel; wireguard-tools is enough.
# Remove any stale userspace override left by an earlier run so we use the module.
rm -f /etc/systemd/system/wg-quick@wg0.service.d/override.conf
rmdir /etc/systemd/system/wg-quick@wg0.service.d 2>/dev/null || true
systemctl daemon-reload

echo "==> [2/8] Enabling IP forwarding"
echo 'net.ipv4.ip_forward = 1' >/etc/sysctl.d/99-lab-forward.conf
sysctl -q --system

echo "==> [3/8] WireGuard server keys"
umask 077
mkdir -p "$WG_DIR"
if [[ ! -f "$WG_DIR/server.key" ]]; then
  wg genkey | tee "$WG_DIR/server.key" | wg pubkey >"$WG_DIR/server.pub"
  echo "    generated new server keypair"
else
  echo "    reusing existing server keypair"
fi
SERVER_PRIVKEY="$(cat "$WG_DIR/server.key")"
SERVER_PUBKEY="$(cat "$WG_DIR/server.pub")"

echo "==> [4/8] Python venv + dependencies"
mkdir -p "$DATA_DIR" "$ENV_DIR"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q --upgrade pip
"$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"

export ADMIN_PASSWORD   # prompted value is not exported otherwise; the hasher reads it from the env
ADMIN_PASSWORD_HASH="$("$APP_DIR/venv/bin/python" -c \
  "from werkzeug.security import generate_password_hash as g; import os; print(g(os.environ['ADMIN_PASSWORD']))")"
SECRET_KEY="$(head -c 32 /dev/urandom | base64)"

echo "==> [5/8] Writing $ENV_FILE"
cat >"$ENV_FILE" <<EOF
SECRET_KEY=$SECRET_KEY
ADMIN_USER=$ADMIN_USER
ADMIN_PASSWORD_HASH=$ADMIN_PASSWORD_HASH
DB_PATH=$DATA_DIR/lab.db
BASE_URL=https://$DOMAIN
WG_INTERFACE=wg0
WG_CONF_PATH=$WG_DIR/wg0.conf
WG_LISTEN_PORT=$WG_LISTEN_PORT
WG_ENDPOINT=$DOMAIN:$WG_LISTEN_PORT
WG_SERVER_PRIVKEY=$SERVER_PRIVKEY
WG_SERVER_PUBKEY=$SERVER_PUBKEY
WG_TUNNEL_CIDR=$WG_TUNNEL_CIDR
WG_SERVER_ADDR=$WG_SERVER_ADDR
WG_STUDENT_START=11
WG_STUDENT_END=250
WG_LAB_CIDR=$WG_LAB_CIDR
WG_PROXMOX_PUBKEY=$PROXMOX_PUBKEY
WG_PROXMOX_TUNNEL_IP=$WG_PROXMOX_TUNNEL_IP
WG_CLIENT_DNS=
EOF
chmod 600 "$ENV_FILE"

echo "==> [6/8] Generating wg0.conf and bringing up the tunnel"
load_env
( cd "$APP_DIR" && "$APP_DIR/venv/bin/python" -c \
  "import db, wg; db.init_db(); wg.regenerate(db.all_students(), apply=False)" )
systemctl enable -q wg-quick@wg0
if wg show wg0 >/dev/null 2>&1; then
  wg syncconf wg0 <(wg-quick strip wg0)          # already up & healthy: hot-reload
else
  systemctl stop wg-quick@wg0 2>/dev/null || true
  ip link del wg0 2>/dev/null || true            # clear any stale/broken leftover
  systemctl restart wg-quick@wg0
fi
sleep 1
wg show wg0 >/dev/null 2>&1 || { echo "ERROR: wg0 did not come up"; systemctl --no-pager status wg-quick@wg0; exit 1; }

echo "==> [7/8] systemd service + nginx"
cat >/etc/systemd/system/lab-dashboard.service <<EOF
[Unit]
Description=Lab dashboard (WireGuard student portal)
After=network-online.target wg-quick@wg0.service
Wants=network-online.target

[Service]
User=root
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$APP_DIR/venv/bin/gunicorn -w 2 -b 127.0.0.1:8000 app:app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q lab-dashboard
systemctl restart lab-dashboard

cat >/etc/nginx/sites-available/lab <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 2m;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
ln -sf /etc/nginx/sites-available/lab /etc/nginx/sites-enabled/lab
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "==> [8/8] Firewall + TLS certificate"
ufw allow 22/tcp   >/dev/null
ufw allow 80/tcp   >/dev/null
ufw allow 443/tcp  >/dev/null
ufw allow "${WG_LISTEN_PORT}/udp" >/dev/null
ufw --force enable  >/dev/null
# Allow forwarding tunnel traffic across the hub (student <-> Proxmox site peer).
ufw route allow in on wg0 out on wg0 >/dev/null 2>&1 || true
ufw reload >/dev/null 2>&1 || true
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" --redirect

echo
echo "=========================================================="
echo " VPS ready."
echo "   Dashboard : https://$DOMAIN   (admin: $ADMIN_USER)"
echo "   WG server public key : $SERVER_PUBKEY"
echo "   WG endpoint          : $DOMAIN:$WG_LISTEN_PORT"
echo
echo " Next: run the Proxmox installer with"
echo "   SERVER_PUBKEY='$SERVER_PUBKEY' ENDPOINT='$DOMAIN:$WG_LISTEN_PORT'"
echo " then, back here:  sudo bash install-vps.sh add-proxmox <PROXMOX_PUBKEY>"
echo "=========================================================="
