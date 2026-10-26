#!/usr/bin/env bash
#
# newservice.sh — enregistre ou retire un service du homelab
#
#   1. bloc reverse_proxy dans le Caddyfile + rechargement à chaud de wong
#   2. réécriture DNS dans AdGuard (sautée si un wildcard la couvre déjà)
#   3. entrée dans le services.yaml de Homepage (edith)
#
# La sonde Uptime Kuma reste manuelle (son API passe par Socket.io, pas REST).
#
# Usage :
#   ./newservice.sh add    <nom> <port> <groupe> "<description>"
#   ./newservice.sh remove <nom>
#   ./newservice.sh list
#   ajouter --dry-run en fin de ligne pour simuler
#
# Groupes Homepage : lus dynamiquement dans services.yaml

set -euo pipefail

# ─────────────── PARAMÈTRES ───────────────
CADDYFILE="${CADDYFILE:-/opt/stacks/wong/Caddyfile}"
CADDY_STACK="${CADDY_STACK:-/opt/stacks/wong}"
SERVICES_YAML="${SERVICES_YAML:-/opt/stacks/edith/config/services.yaml}"

DOMAIN="example.lan"
BACKEND_IP="${BACKEND_IP:-192.0.2.59}"     # hôte Docker (avengers)

ADGUARD_URL="${ADGUARD_URL:-http://192.0.2.57}"
ADGUARD_CREDS="${ADGUARD_CREDS:-$HOME/.adguard-creds}"   # une ligne : user:motdepasse
# ──────────────────────────────────────────

DRY_RUN=0
ARGS=()
for a in "$@"; do
    if [[ $a == "--dry-run" ]]; then
        DRY_RUN=1
    else
        ARGS+=("$a")
    fi
done
set -- "${ARGS[@]:-}"

die() { printf '\e[31mERREUR\e[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\e[32mOK\e[0m %s\n' "$*"; }
inf() { printf '   %s\n' "$*"; }
dry() { printf '\e[33m[dry-run]\e[0m %s\n' "$*"; }

command -v python3 >/dev/null || die "python3 requis"

ACTION="${1:-}"
[[ -n $ACTION ]] || die "usage : $0 add <nom> <port> <groupe> \"<desc>\" | $0 remove <nom> | $0 list"

[[ -f $CADDYFILE ]]     || die "Caddyfile introuvable : $CADDYFILE"
[[ -f $SERVICES_YAML ]] || die "services.yaml introuvable : $SERVICES_YAML"

# ═════════════ LIST ═════════════
if [[ $ACTION == list ]]; then
    python3 - "$CADDYFILE" "$SERVICES_YAML" "$DOMAIN" <<'PY'
import sys, re
caddyfile, yamlfile, domain = sys.argv[1:4]

# Services routés par Caddy : nom -> port
caddy = {}
lines = open(caddyfile).read().split('\n')
for i, l in enumerate(lines):
    m = re.match(r'^\s*@([a-z0-9-]+) host ', l)
    if not m:
        continue
    name = m.group(1)
    for j in range(i, min(i + 6, len(lines))):
        p = re.search(r'reverse_proxy \S*?:(\d+)', lines[j])
        if p:
            caddy[name] = p.group(1)
            break
    else:
        caddy[name] = '?'

# Entrées Homepage : hôte -> (libellé, groupe)
home, group, label = {}, None, None
for l in open(yamlfile).read().split('\n'):
    g = re.match(r'^- (.+):\s*$', l)
    if g:
        group = g.group(1)
        continue
    e = re.match(r'^\s+- (.+):\s*$', l)
    if e:
        label = e.group(1)
        continue
    h = re.search(r'href:\s*https?://([a-z0-9-]+)\.' + re.escape(domain), l)
    if h and group and label:
        home[h.group(1)] = (label, group)

groups = [g.group(1) for g in
          (re.match(r'^- (.+):\s*$', l) for l in open(yamlfile).read().split('\n'))
          if g]

def pad(txt, width, absent=False):
    s = '\033[33mabsent\033[0m' if absent else txt
    return s + ' ' * max(0, width - len(txt if not absent else 'absent'))

print("── Services ──")
print(f"  {'NOM':<14} {'PORT':<8} {'HOMEPAGE'}")
for name in sorted(set(caddy) | set(home)):
    port = pad(caddy.get(name, ''), 8, name not in caddy)
    if name in home:
        lbl, grp = home[name]
        entry = f"{lbl} ({grp})"
    else:
        entry = '\033[33mabsent\033[0m'
    print(f"  {name:<14} {port} {entry}")

orphans_caddy = sorted(set(caddy) - set(home))
orphans_home = sorted(set(home) - set(caddy))
if orphans_caddy or orphans_home:
    print("\n── Incohérences ──")
    for n in orphans_caddy:
        print(f"  {n} : routé par Caddy, absent de Homepage")
    for n in orphans_home:
        print(f"  {n} : dans Homepage, non routé par Caddy")

print("\n── Groupes disponibles ──")
for g in groups:
    print(f"  {g}")
PY
    exit 0
fi

NAME="${2:-}"
[[ -n $NAME ]] || die "nom manquant"
NAME=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
[[ -n $NAME ]] || die "nom invalide après nettoyage"
FQDN="${NAME}.${DOMAIN}"

backup() {
    local f="$1" b
    (( DRY_RUN )) && return
    b="${f}.$(date +%Y%m%d-%H%M%S).bak"
    cp -a "$f" "$b"
    inf "sauvegarde : $b"
    ls -t "${f}".*.bak 2>/dev/null | tail -n +6 | xargs -r rm --
}

# ═════════════ CADDY ═════════════
caddy_add() {
    if grep -q "^[[:space:]]*@${NAME} host " "$CADDYFILE"; then
        inf "Caddy : bloc @${NAME} déjà présent, rien à faire"
        return
    fi
    backup "$CADDYFILE"
    if (( DRY_RUN )); then
        dry "Caddy : insertion @${NAME} -> ${BACKEND_IP}:${PORT}"
        return
    fi
    python3 - "$CADDYFILE" "$NAME" "$FQDN" "$BACKEND_IP" "$PORT" <<'PY'
import sys, re
path, name, fqdn, ip, port = sys.argv[1:6]
lines = open(path).read().split('\n')
try:
    idx = next(i for i, l in enumerate(lines) if re.match(r'^\s*handle\s*\{\s*$', l))
except StopIteration:
    sys.exit("bloc 'handle {' final introuvable dans le Caddyfile")
lines[idx:idx] = [f"    @{name} host {fqdn}",
                  f"    handle @{name} {{",
                  f"        reverse_proxy {ip}:{port}",
                  "    }",
                  ""]
open(path, 'w').write('\n'.join(lines))
PY
    ok "Caddy : bloc @${NAME} -> ${BACKEND_IP}:${PORT}"
}

caddy_remove() {
    if ! grep -q "^[[:space:]]*@${NAME} host " "$CADDYFILE"; then
        inf "Caddy : aucun bloc @${NAME}"
        return
    fi
    backup "$CADDYFILE"
    if (( DRY_RUN )); then
        dry "Caddy : suppression du bloc @${NAME}"
        return
    fi
    python3 - "$CADDYFILE" "$NAME" <<'PY'
import sys, re
path, name = sys.argv[1:3]
lines = open(path).read().split('\n')
start = next(i for i, l in enumerate(lines) if re.match(rf'^\s*@{re.escape(name)} host ', l))
depth, seen, end = 0, False, start
for i in range(start, len(lines)):
    depth += lines[i].count('{') - lines[i].count('}')
    if '{' in lines[i]:
        seen = True
    if seen and depth == 0:
        end = i
        break
if end + 1 < len(lines) and lines[end + 1].strip() == '':
    end += 1
del lines[start:end + 1]
open(path, 'w').write('\n'.join(lines))
PY
    ok "Caddy : bloc @${NAME} retiré"
}

caddy_reload() {
    command -v docker >/dev/null || { inf "docker absent, redémarre Caddy à la main"; return; }
    [[ -d $CADDY_STACK ]] || { inf "stack $CADDY_STACK introuvable"; return; }
    local svc
    svc=$( (cd "$CADDY_STACK" && docker compose config --services 2>/dev/null | head -1) || true )
    [[ -n $svc ]] || { inf "service compose introuvable, redémarre à la main"; return; }
    if (( DRY_RUN )); then
        dry "Caddy : validate + restart (service ${svc})"
        return
    fi
    # On valide avant de redémarrer : un Caddyfile cassé empêcherait Caddy de repartir
    if (cd "$CADDY_STACK" && docker compose exec -T "$svc" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1); then
        (cd "$CADDY_STACK" && docker compose restart >/dev/null 2>&1)
        sleep 2
        ok "Caddy redémarré"
    else
        die "Caddyfile invalide — restaure la sauvegarde ci-dessus, rien n'a été redémarré"
    fi
}

# ═════════════ ADGUARD ═════════════
adguard() {
    local op="$1" list creds http
    [[ -f $ADGUARD_CREDS ]] || { inf "AdGuard : $ADGUARD_CREDS absent, étape sautée"; return; }
    creds=$(head -1 "$ADGUARD_CREDS")
    list=$(curl -s --max-time 5 -u "$creds" "${ADGUARD_URL}/control/rewrite/list" 2>/dev/null || true)
    [[ -n $list ]] || { inf "AdGuard : injoignable ou identifiants refusés, étape sautée"; return; }

    if [[ $op == add ]] && grep -q "\*\.${DOMAIN}" <<<"$list"; then
        ok "AdGuard : wildcard *.${DOMAIN} en place, réécriture inutile"
        return
    fi
    if [[ $op == add ]] && grep -q "\"${FQDN}\"" <<<"$list"; then
        inf "AdGuard : réécriture ${FQDN} déjà présente"
        return
    fi
    if (( DRY_RUN )); then
        dry "AdGuard : ${op} ${FQDN} -> ${BACKEND_IP}"
        return
    fi
    http=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "$creds" \
             -X POST "${ADGUARD_URL}/control/rewrite/${op}" \
             -H 'Content-Type: application/json' \
             -d "{\"domain\":\"${FQDN}\",\"answer\":\"${BACKEND_IP}\"}" || echo 000)
    if [[ $http == 2* ]]; then
        ok "AdGuard : réécriture ${op} pour ${FQDN}"
    else
        inf "AdGuard : appel API en échec (HTTP ${http})"
    fi
}

# ═════════════ HOMEPAGE ═════════════
homepage_add() {
    if grep -qiP "^\s*- ${NAME}:\s*$" "$SERVICES_YAML"; then
        inf "Homepage : entrée ${NAME} déjà présente"
        return
    fi
    backup "$SERVICES_YAML"
    if (( DRY_RUN )); then
        dry "Homepage : ajout de ${NAME} dans ${GROUP}"
        return
    fi
    python3 - "$SERVICES_YAML" "$NAME" "$FQDN" "$GROUP" "$DESC" <<'PY'
import sys, re
path, name, fqdn, group, desc = sys.argv[1:6]
lines = open(path).read().split('\n')
label = name.capitalize()
try:
    start = next(i for i, l in enumerate(lines) if l.strip() == f'- {group}:')
except StopIteration:
    sys.exit(f"groupe '{group}' absent du services.yaml")
end = len(lines)
for i in range(start + 1, len(lines)):
    if re.match(r'^- \S', lines[i]):
        end = i
        break
while end > start and lines[end - 1].strip() == '':
    end -= 1
lines[end:end] = [f'    - {label}:',
                  f'        href: https://{fqdn}',
                  f'        description: {desc}']
open(path, 'w').write('\n'.join(lines))
PY
    ok "Homepage : ${NAME} ajouté au groupe ${GROUP}"
}

homepage_remove() {
    if ! grep -qiP "^\s*- ${NAME}:\s*$" "$SERVICES_YAML"; then
        inf "Homepage : aucune entrée ${NAME}"
        return
    fi
    backup "$SERVICES_YAML"
    if (( DRY_RUN )); then
        dry "Homepage : suppression de ${NAME}"
        return
    fi
    python3 - "$SERVICES_YAML" "$NAME" <<'PY'
import sys, re
path, name = sys.argv[1:3]
lines = open(path).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if re.match(rf'^\s*- {re.escape(name)}:\s*$', l, re.I))
end = len(lines)
for i in range(start + 1, len(lines)):
    s = lines[i]
    if s.strip() == '':
        continue
    if re.match(r'^\s*- \S', s):
        end = i
        break
while end > start and lines[end - 1].strip() == '':
    end -= 1
del lines[start:end]
open(path, 'w').write('\n'.join(lines))
PY
    ok "Homepage : entrée ${NAME} retirée"
}

# ═════════════ ORCHESTRATION ═════════════
case "$ACTION" in
  add)
    PORT="${3:-}"; GROUP="${4:-}"; DESC="${5:-$NAME}"
    [[ $PORT =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )) || die "port manquant ou invalide"
    [[ -n $GROUP ]] || die "groupe manquant — lance '$0 list' pour voir les groupes"
    grep -q "^- ${GROUP}:" "$SERVICES_YAML" || die "groupe '${GROUP}' absent — lance '$0 list'"
    if grep -q "^[[:space:]]*@${NAME} host " "$CADDYFILE"; then
        inf "le service ${NAME} est déjà enregistré dans le Caddyfile"
    elif grep -qP "reverse_proxy \S*:${PORT}\s*$" "$CADDYFILE"; then
        die "le port ${PORT} est déjà routé dans le Caddyfile — lance '$0 list'"
    fi
    echo "── ajout de ${FQDN} -> ${BACKEND_IP}:${PORT} ──"
    caddy_add
    caddy_reload
    adguard add
    homepage_add
    echo
    ok "terminé"
    inf "reste à faire : sonde Uptime Kuma sur https://${FQDN}"
    inf "                sonde Conteneur Docker sur ${NAME}"
    ;;
  remove)
    echo "── retrait de ${FQDN} ──"
    caddy_remove
    caddy_reload
    adguard delete
    homepage_remove
    echo
    ok "terminé"
    inf "reste à faire : supprimer les sondes Uptime Kuma"
    ;;
  *)
    die "action inconnue : $ACTION (add | remove | list)"
    ;;
esac
