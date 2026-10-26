# Feuille de route

Ce que cette installation n'a pas encore, et pourquoi. Les noms suivent la même
convention que les services existants : lieux et organisations pour
l'infrastructure, personnages pour les services applicatifs.

## Services prévus

| Nom | Service | Priorité | Raison |
|---|---|---|---|
| `stark` | Forgejo | Haute | Versionner les configurations sur une forge auto-hébergée plutôt que sur un dépôt distant |
| — | Beszel | Moyenne | Métriques système et alertes de seuil, complément d'Uptime Kuma qui ne teste que la disponibilité |
| — | LoggiFly | Moyenne | Alertes sur motifs dans les logs. À déployer une fois les logs normaux connus, sinon tout ressemble à une anomalie |
| `tivan` | Wallabag | Basse | Lecture différée. À décider après usage réel de FreshRSS |
| — | Semaphore | Basse | Interface Ansible. Après avoir appris Ansible en ligne de commande, pas avant |
| `cerebro` | SearXNG | Basse | Métamoteur de recherche. Risque d'abandon assumé |
| — | Immich | À voir | Photothèque. Dépend du volume réel à héberger |

## Chantiers d'infrastructure

**Proxmox Backup Server.** Remplacerait les vzdump complets par de la
déduplication : environ 13 Go quotidiens aujourd'hui, quelques centaines de
mégaoctets après la première passe. Doit tourner sur une machine et un disque
distincts de l'hyperviseur, sinon la sauvegarde partage le sort de ce qu'elle
sauvegarde. Bloqué par l'absence d'un second hôte x86 : les paquets officiels
sont amd64 uniquement.

**Chiffrement des sauvegardes.** Viendra avec PBS. Piège à éviter : la clé de
chiffrement ne doit pas vivre dans le coffre de mots de passe lui-même
sauvegardé, sous peine de dépendance circulaire.

**Copie hors site.** C'est le manque principal, détaillé dans le README. Un NAS est
prévu pour la porter.

**Segmentation réseau.** Placer les objets connectés dans un VLAN ou un réseau
invité : ils ignorent souvent le DNS annoncé en DHCP et utilisent des résolveurs codés en
dur. C'est le seul cas où un filtrage DNS ne suffit plus.

**DMZ pour l'hôte WireGuard.** Aujourd'hui le LXC exposé est sur le même
segment que le reste du LAN.

**Pare-feu Proxmox.** Protège du trafic interne au LAN, là où le NAT ne couvre
que l'extérieur. Risque de verrouillage : les règles d'accès doivent exister
avant l'activation.

**DHCP.** Distribuer le résolveur local à tout le réseau, pour ne plus
configurer le DNS appareil par appareil.

## Laboratoire d'attaque

Monter un réseau isolé pour rejouer des scénarios offensifs : machine Kali, contrôleur
de domaine Windows, poste client instrumenté, sonde réseau et SIEM.

Contrainte non négociable : bridge dédié, aucune route vers le LAN, aucune
passerelle. Le but est d'observer des attaques réelles sans qu'elles puissent
atteindre une machine de production.

## Écarté

| Option | Raison |
|---|---|
| Tailscale, Headscale | Dépendance à un plan de contrôle tiers (détaillé dans le README) |
| Portainer | Dockge suffit et reste lisible en texte |
| Watchtower | Met à jour automatiquement, donc peut casser un service la nuit. Diun notifie sans agir |
| Mise à jour automatique des conteneurs | Même raison |
| Export automatisé du coffre de mots de passe | Imposerait de stocker le mot de passe maître sur l'hôte, exactement le problème qu'on cherche à éviter. Export manuel chiffré trimestriel à la place |
| Panneau d'administration de Vaultwarden | Surface d'attaque supplémentaire sur le service le plus sensible, pour afficher un compteur |
