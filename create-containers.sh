#!/usr/bin/env bash
#
# Create the LXC "mock machines" students will scan. Run as root on Proxmox
# AFTER proxmox-setup.sh (the lab bridge + NAT must exist).
#
#   bash create-containers.sh
#
# Idempotent: containers that already exist are skipped, so you can re-run this
# after adding entries to MOCKS below. Tune STORAGE/TEMPLATE to your host.
set -euo pipefail

LAB_BRIDGE="${LAB_BRIDGE:-vmbr1}"
LAB_GW="${LAB_GW:-10.66.10.1}"
LAB_PREFIX="${LAB_PREFIX:-24}"
STORAGE="${STORAGE:-local-lvm}"           # where container rootfs lives
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE_NAME="${TEMPLATE_NAME:-debian-12-standard}"
NAMESERVER="${NAMESERVER:-1.1.1.1}"

# vmid  ip_octet  hostname  profile
#   scan-target profiles : web | web-ssh | web-ftp | web-alt | web-ssh-alt
#   realistic web sites  : site-shop | site-corp | site-media
MOCKS=(
  "9011 11 web01   web"
  "9012 12 web02   web-ssh"
  "9013 13 files01 web-ftp"
  "9014 14 app01   web-alt"
  "9015 15 dev01   web-ssh-alt"
  "9016 16 shop01  site-shop"
  "9017 17 corp01  site-corp"
  "9018 18 media01 site-media"
)

# --------------------------------------------------------------------------- #
# Page rendering. Each site is self-contained (inline CSS, no external assets)
# so it renders fully over the VPN with no internet access. Brands are
# fictional on purpose.
# --------------------------------------------------------------------------- #
render_page() {  # $1=profile  $2=hostname
  local profile="$1" host="$2"
  case "$profile" in

  site-shop)
cat <<HTML
<!doctype html><html lang=fr><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Neovia - Boutique en ligne</title><style>
*{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:#1b1f2a;background:#fff}
header{background:#0f2c4d;color:#fff;padding:.9rem 1.5rem;display:flex;align-items:center;gap:2rem;flex-wrap:wrap}
.logo{font-weight:800;font-size:1.3rem;letter-spacing:-.5px}
nav a{color:#cfe0f5;text-decoration:none;margin-right:1.2rem;font-size:.92rem}
nav a:hover{color:#fff}
.search{margin-left:auto;display:flex}
.search input{border:0;border-radius:6px 0 0 6px;padding:.5rem .8rem;width:220px}
.search button{border:0;background:#f5a623;color:#3a2600;font-weight:700;padding:.5rem 1rem;border-radius:0 6px 6px 0;cursor:pointer}
.hero{background:linear-gradient(120deg,#123a63,#2f6ea8);color:#fff;padding:3rem 1.5rem;text-align:center}
.hero h1{margin:0 0 .5rem;font-size:2.1rem}.hero p{margin:0;opacity:.9}
.wrap{max-width:1040px;margin:2rem auto;padding:0 1.5rem}
h2{font-size:1.25rem;margin:0 0 1rem}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:1.2rem}
.card{border:1px solid #e3e7ee;border-radius:10px;overflow:hidden;transition:.15s}
.card:hover{box-shadow:0 6px 18px rgba(16,32,60,.12)}
.ph{height:140px}
.p1{background:linear-gradient(135deg,#7bb0e8,#3f7fc4)}.p2{background:linear-gradient(135deg,#f6c28b,#e08b3c)}
.p3{background:linear-gradient(135deg,#9fd8c0,#46a583)}.p4{background:linear-gradient(135deg,#c3b2e8,#7e63c4)}
.info{padding:.8rem}.info h3{margin:0 0 .3rem;font-size:.97rem;font-weight:600}
.price{color:#0f2c4d;font-weight:800}.old{color:#96a0b0;text-decoration:line-through;font-weight:400;font-size:.85rem;margin-left:.4rem}
.stars{color:#f5a623;font-size:.82rem}
footer{background:#0b1f36;color:#8fa6c0;margin-top:2.5rem;padding:2rem 1.5rem;font-size:.87rem;text-align:center}
.badge{display:inline-block;background:#e8f4ea;color:#1f7a45;border-radius:4px;padding:.1rem .45rem;font-size:.73rem;font-weight:700;margin-left:.3rem}
</style></head><body>
<header><span class=logo>NEOVIA</span>
<nav><a href=#>Informatique</a><a href=#>Maison</a><a href=#>Sport</a><a href=#>Promotions</a><a href=#>Service client</a></nav>
<form class=search onsubmit="return false"><input placeholder="Rechercher un produit"><button>Rechercher</button></form>
</header>
<div class=hero><h1>Soldes d'automne : jusqu'a -40%</h1><p>Livraison offerte des 49 CHF - Retours gratuits sous 30 jours</p></div>
<div class=wrap>
<h2>Produits les plus vendus</h2>
<div class=grid>
  <div class=card><div class="ph p1"></div><div class=info><h3>Casque audio sans fil ARC-700</h3>
    <div class=stars>* * * * *</div><div><span class=price>129.90 CHF</span><span class=old>189.00</span><span class=badge>En stock</span></div></div></div>
  <div class=card><div class="ph p2"></div><div class=info><h3>Sac a dos urbain 28L</h3>
    <div class=stars>* * * *</div><div><span class=price>64.50 CHF</span><span class=old>89.00</span><span class=badge>En stock</span></div></div></div>
  <div class=card><div class="ph p3"></div><div class=info><h3>Bouilloire inox 1.7L</h3>
    <div class=stars>* * * *</div><div><span class=price>39.90 CHF</span><span class=badge>En stock</span></div></div></div>
  <div class=card><div class="ph p4"></div><div class=info><h3>Clavier mecanique compact</h3>
    <div class=stars>* * * * *</div><div><span class=price>99.00 CHF</span><span class=old>119.00</span><span class=badge>En stock</span></div></div></div>
</div>
</div>
<footer>Neovia SA - Rue du Commerce 14, Geneve - Societe fictive utilisee pour un laboratoire pedagogique.<br>Hote : $host</footer>
</body></html>
HTML
    ;;

  site-corp)
cat <<HTML
<!doctype html><html lang=fr><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Altura Systemes - Solutions infonuagiques</title><style>
*{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:#141c27;background:#fff}
header{padding:1rem 2rem;display:flex;align-items:center;gap:2rem;border-bottom:1px solid #e8ecf1;flex-wrap:wrap}
.logo{font-weight:800;font-size:1.2rem;color:#0d5c63;letter-spacing:-.3px}
nav{margin-left:auto}nav a{color:#4a5a6e;text-decoration:none;margin-left:1.4rem;font-size:.92rem}
nav a:hover{color:#0d5c63}
.cta{background:#0d5c63;color:#fff!important;padding:.5rem .95rem;border-radius:6px;font-weight:600}
.hero{padding:4rem 2rem;text-align:center;background:linear-gradient(160deg,#f4fbfb,#e6f2f4)}
.hero h1{margin:0 0 .8rem;font-size:2.4rem;letter-spacing:-.8px;max-width:760px;margin-inline:auto}
.hero p{margin:0 auto 1.6rem;max-width:620px;color:#48606f;font-size:1.05rem}
.btn{display:inline-block;background:#0d5c63;color:#fff;text-decoration:none;padding:.75rem 1.5rem;border-radius:7px;font-weight:600}
.btn.alt{background:#fff;color:#0d5c63;border:1px solid #bcd9dc;margin-left:.6rem}
.wrap{max-width:1000px;margin:3rem auto;padding:0 2rem}
h2{font-size:1.5rem;text-align:center;margin:0 0 .5rem}
.sub{text-align:center;color:#6b7c8d;margin:0 0 2rem}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:1.4rem}
.card{border:1px solid #e8ecf1;border-radius:10px;padding:1.4rem}
.card h3{margin:.2rem 0 .5rem;font-size:1.05rem}
.card p{margin:0;color:#5c6b7a;font-size:.92rem}
.ic{width:38px;height:38px;border-radius:9px;background:linear-gradient(135deg,#19a5ad,#0d5c63)}
.stats{display:flex;justify-content:center;gap:3.5rem;flex-wrap:wrap;background:#0d2f33;color:#fff;padding:2.5rem 2rem;margin-top:3rem}
.stat b{display:block;font-size:1.9rem}.stat span{color:#9ec6c9;font-size:.87rem}
footer{background:#08181a;color:#7f9ea1;padding:2rem;text-align:center;font-size:.86rem}
</style></head><body>
<header><span class=logo>ALTURA SYSTEMES</span>
<nav><a href=#>Produits</a><a href=#>Solutions</a><a href=#>Tarifs</a><a href=#>Documentation</a><a class=cta href=#>Demander une demo</a></nav>
</header>
<div class=hero><h1>L'infrastructure infonuagique pensee pour les PME suisses</h1>
<p>Hebergement, sauvegarde et supervision dans des centres de donnees certifies. Mise en service en moins de 24 heures.</p>
<a class=btn href=#>Commencer</a><a class="btn alt" href=#>Nous contacter</a></div>
<div class=wrap><h2>Nos services</h2><p class=sub>Une plateforme unique pour vos environnements critiques</p>
<div class=grid>
  <div class=card><div class=ic></div><h3>Serveurs manages</h3><p>Instances dediees supervisees 24/7 avec engagement de disponibilite de 99.95%.</p></div>
  <div class=card><div class=ic></div><h3>Sauvegarde continue</h3><p>Replication hors site chiffree, restauration granulaire jusqu'a 90 jours.</p></div>
  <div class=card><div class=ic></div><h3>Securite reseau</h3><p>Pare-feu applicatif, segmentation et detection d'intrusion integres.</p></div>
</div></div>
<div class=stats><div class=stat><b>1 240</b><span>clients actifs</span></div>
<div class=stat><b>99.95%</b><span>disponibilite</span></div>
<div class=stat><b>3</b><span>centres de donnees</span></div></div>
<footer>Altura Systemes SA - Societe fictive utilisee pour un laboratoire pedagogique.<br>Hote : $host</footer>
</body></html>
HTML
    ;;

  site-media)
cat <<HTML
<!doctype html><html lang=fr><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Le Quotidien Numerique</title><style>
*{box-sizing:border-box}body{margin:0;font-family:Georgia,'Times New Roman',serif;color:#1a1a1a;background:#fbfbf9}
.top{background:#8b1a1a;color:#fff;font-size:.78rem;padding:.35rem 1.5rem;font-family:system-ui,sans-serif;letter-spacing:.5px}
header{text-align:center;padding:1.4rem 1.5rem .9rem;border-bottom:3px double #1a1a1a}
header h1{margin:0;font-size:2.6rem;letter-spacing:-1px}
header .date{font-family:system-ui,sans-serif;font-size:.78rem;color:#6b6b6b;margin-top:.4rem;text-transform:uppercase;letter-spacing:1.5px}
nav{border-bottom:1px solid #d8d6d0;text-align:center;padding:.6rem;font-family:system-ui,sans-serif;font-size:.85rem}
nav a{color:#333;text-decoration:none;margin:0 .85rem}nav a:hover{color:#8b1a1a}
.wrap{max-width:1000px;margin:1.6rem auto;padding:0 1.5rem;display:grid;grid-template-columns:2fr 1fr;gap:2.2rem}
@media(max-width:720px){.wrap{grid-template-columns:1fr}}
.lead h2{font-size:1.9rem;margin:.2rem 0 .6rem;line-height:1.2}
.lead .img{height:230px;background:linear-gradient(135deg,#b8c4d0,#6f8296);margin-bottom:.9rem}
.kicker{font-family:system-ui,sans-serif;font-size:.72rem;color:#8b1a1a;font-weight:700;text-transform:uppercase;letter-spacing:1.2px}
p{line-height:1.65;color:#2b2b2b}
.byline{font-family:system-ui,sans-serif;font-size:.78rem;color:#777;margin-bottom:.7rem}
article{border-top:1px solid #ddd9d2;padding:1rem 0}
article h3{margin:.25rem 0 .35rem;font-size:1.1rem}
aside h4{font-family:system-ui,sans-serif;font-size:.8rem;text-transform:uppercase;letter-spacing:1px;border-bottom:2px solid #1a1a1a;padding-bottom:.4rem;margin:0 0 .8rem}
aside ol{padding-left:1.1rem;margin:0}aside li{margin-bottom:.7rem;font-size:.93rem;line-height:1.4}
footer{border-top:3px double #1a1a1a;margin-top:2rem;padding:1.5rem;text-align:center;font-family:system-ui,sans-serif;font-size:.8rem;color:#666}
</style></head><body>
<div class=top>EDITION DU JOUR - MISE A JOUR EN CONTINU</div>
<header><h1>Le Quotidien Numerique</h1><div class=date>Geneve - Economie, technologie et societe</div></header>
<nav><a href=#>Accueil</a><a href=#>Economie</a><a href=#>Technologie</a><a href=#>Suisse</a><a href=#>International</a><a href=#>Culture</a><a href=#>Opinions</a></nav>
<div class=wrap>
<main>
  <div class=lead><span class=kicker>Technologie</span>
    <h2>Les PME romandes acceleretent leur migration vers l'infonuagique</h2>
    <div class=byline>Par la redaction economique</div>
    <div class=img></div>
    <p>Pres de six entreprises sur dix de Suisse romande declarent avoir transfere une partie de leurs
    services vers des plateformes hebergees au cours des douze derniers mois. Une evolution portee par
    la recherche de flexibilite, mais qui soulevent de nouvelles questions en matiere de securite.</p>
    <p>Les specialistes interroges insistent sur la necessite de former les equipes internes, la majorite
    des incidents recenses restant lies a des erreurs de configuration plutot qu'a des attaques ciblees.</p>
  </div>
  <article><span class=kicker>Economie</span><h3>Le marche de l'emploi reste tendu dans les metiers techniques</h3>
    <p>Les postes d'ingenieurs reseau et de specialistes en cybersecurite figurent parmi les plus difficiles a pourvoir.</p></article>
  <article><span class=kicker>Suisse</span><h3>Nouvelle ligne ferroviaire : le chantier avance plus vite que prevu</h3>
    <p>Les travaux devraient s'achever avec six mois d'avance sur le calendrier initial.</p></article>
</main>
<aside><h4>Les plus lus</h4><ol>
  <li>Ce que change la nouvelle loi sur la protection des donnees</li>
  <li>Teletravail : les entreprises revoient leurs accords</li>
  <li>Cinq outils pour securiser un reseau domestique</li>
  <li>Energie : une facture en baisse pour l'hiver prochain</li>
</ol></aside>
</div>
<footer>Le Quotidien Numerique - Publication fictive utilisee pour un laboratoire pedagogique.<br>Hote : $host</footer>
</body></html>
HTML
    ;;

  *)  # generic scan target
cat <<HTML
<!doctype html><html lang=fr><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>$host</title><style>
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#fff;color:#1a1d24;
display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
.b{border:1px solid #e3e6ea;border-radius:12px;padding:2rem 2.5rem;box-shadow:0 1px 3px rgba(16,24,40,.06)}
h1{margin:0 0 .3rem}code{color:#2563eb}p{color:#6b7280}
</style></head><body><div class=b><h1>$host</h1>
<p>Machine cible du laboratoire de securite.</p>
<p>Hote : <code>$host</code> - Profil : <code>$profile</code></p></div></body></html>
HTML
    ;;
  esac
}

echo "==> Ensuring $TEMPLATE_NAME template is available"
pveam update >/dev/null 2>&1 || true
TEMPLATE_FILE="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '/'"$TEMPLATE_NAME"'/{print $1; exit}')"
if [[ -z "$TEMPLATE_FILE" ]]; then
  AVAIL="$(pveam available | awk '/'"$TEMPLATE_NAME"'/{print $2; exit}')"
  [[ -n "$AVAIL" ]] || { echo "template $TEMPLATE_NAME not found in pveam"; exit 1; }
  echo "    downloading $AVAIL"
  pveam download "$TEMPLATE_STORAGE" "$AVAIL"
  TEMPLATE_FILE="$TEMPLATE_STORAGE:vztmpl/$AVAIL"
fi
echo "    template: $TEMPLATE_FILE"

provision() {  # $1=vmid $2=hostname $3=profile
  local vmid="$1" host="$2" profile="$3" tmp
  # wait for network, then install the web server
  pct exec "$vmid" -- bash -c 'set -e
    export DEBIAN_FRONTEND=noninteractive
    for i in $(seq 1 30); do ping -c1 -W1 '"$NAMESERVER"' >/dev/null 2>&1 && break; sleep 1; done
    apt-get update -qq
    apt-get install -y -qq nginx >/dev/null
    systemctl enable --now nginx >/dev/null 2>&1'
  # push the rendered page (avoids nested-heredoc quoting problems)
  tmp="$(mktemp)"
  render_page "$profile" "$host" >"$tmp"
  pct push "$vmid" "$tmp" /var/www/html/index.html
  rm -f "$tmp"
  # extra services so scans differ per host
  case "$profile" in
    *ssh*) pct exec "$vmid" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null && systemctl enable --now ssh >/dev/null 2>&1" ;;
  esac
  case "$profile" in
    *ftp*) pct exec "$vmid" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq vsftpd >/dev/null && systemctl enable --now vsftpd >/dev/null 2>&1" ;;
  esac
  case "$profile" in
    *alt*) pct exec "$vmid" -- bash -c '
      mkdir -p /opt/altsrv && echo "<h1>service alternatif sur le port 8080</h1>" > /opt/altsrv/index.html
      cat >/etc/systemd/system/altweb.service <<UNIT
[Unit]
Description=alt web on 8080
After=network.target
[Service]
ExecStart=/usr/bin/python3 -m http.server 8080 --directory /opt/altsrv
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload && systemctl enable --now altweb >/dev/null 2>&1' ;;
  esac
}

for row in "${MOCKS[@]}"; do
  read -r vmid octet host profile <<<"$row"
  ip="${LAB_GW%.*}.$octet"
  if pct status "$vmid" >/dev/null 2>&1; then
    echo "==> $vmid ($host) already exists, skipping"
    continue
  fi
  echo "==> Creating $vmid $host $ip [$profile]"
  pct create "$vmid" "$TEMPLATE_FILE" \
    --hostname "$host" \
    --unprivileged 1 \
    --cores 1 --memory 256 --swap 128 \
    --rootfs "$STORAGE:2" \
    --net0 "name=eth0,bridge=$LAB_BRIDGE,ip=$ip/$LAB_PREFIX,gw=$LAB_GW" \
    --nameserver "$NAMESERVER" \
    --onboot 1 \
    --features nesting=0 >/dev/null
  pct start "$vmid"
  provision "$vmid" "$host" "$profile"
  echo "    $host ready at http://$ip/"
done

echo
echo "=========================================================="
echo " Mock machines up. From a connected student:"
echo "   nmap -sn ${LAB_GW%.*}.0/$LAB_PREFIX      # discover"
echo "   nmap -sV ${LAB_GW%.*}.11                 # scan one"
echo
echo " Web sites to visit in a browser:"
echo "   http://${LAB_GW%.*}.16/   Neovia (e-commerce)"
echo "   http://${LAB_GW%.*}.17/   Altura Systemes (entreprise)"
echo "   http://${LAB_GW%.*}.18/   Le Quotidien Numerique (presse)"
echo "=========================================================="
