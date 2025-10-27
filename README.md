# GeoDock — Proxy de l’API Adresse

[![proxy-ci](https://github.com/jbjardine/GeoDock/actions/workflows/proxy-ci.yml/badge.svg?branch=main)](https://github.com/jbjardine/GeoDock/actions/workflows/proxy-ci.yml)

Objectif: exposer en local les mêmes endpoints et schémas que `https://api-adresse.data.gouv.fr` en mode proxy (conformité fonctionnelle), prêt à déployer chez des clients.

## Prérequis
- Docker + Docker Compose
- Plateforme: Linux x86_64 pour la production (recommandé). Windows possible pour dev/tests via Docker Desktop, à éviter en production; préférer un serveur Linux ou une VM/WSL2.
- DNS/hosts: faire résoudre `GeoDock.intra` (ou un FQDN interne) vers l’hôte Docker (ou utiliser l’IP pour tester).

## Démarrage rapide (mode proxy)
- Diagnostic: `bash scripts/doctor.sh`
- Démarrer le proxy: `bash scripts/proxy_up.sh`
- Vérifier: `bash scripts/proxy_verify.sh`
  - Mode par défaut: TLS bridge (HTTP accepté, proxy → amont en HTTPS).
  - Redirection HTTP→HTTPS désactivée par défaut (`REDIRECT_HTTP_TO_HTTPS=false`).
  - Option: exposer/masquer `/_health` en HTTP via `EXPOSE_HEALTH_ON_HTTP=true|false` (false = 100 % HTTPS).
  - Parité rapide vs officiel: `BASE=http://localhost REMOTE_BASE=https://api-adresse.data.gouv.fr python3 scripts/parity_check.py`

Guide détaillé: voir `docs/install/proxy.md`.

## Fonctionnement
- Le serveur relaie 100 % des requêtes vers l’API officielle (mode proxy).

## TLS et ports
- Le proxy expose HTTP:80 et HTTPS:443 en parallèle (mappage configurable via `.env`).
- `SERVER_NAME` pilote le nom du certificat. Sans certificat monté, un certificat auto‑signé est généré (tests). En production, monter un certificat interne.
- Protocoles: `TLSv1.2 TLSv1.3` (modifiable via `SSL_PROTOCOLS`).

### Monter un certificat
- Placer `proxy/certs/tls.crt` et `proxy/certs/tls.key` (montés en lecture seule dans le conteneur).
- Redémarrer le proxy: `docker compose restart proxy`.
- Le certificat doit couvrir `SERVER_NAME` (ex: GeoDock.intra).

## Release
- Générer un tarball: `bash scripts/release_proxy.sh`
- Sortie: `dist/GeoDock-proxy-<timestamp>.tar.gz`.
- Dernière release: https://github.com/jbjardine/GeoDock/releases/latest

## Installation (tarball)
- Copier l’archive sur le serveur Linux x86_64.
- Extraire: `tar -xzf GeoDock-proxy-*.tar.gz`
- Démarrer: `docker compose -f docker-compose.proxy.yml up -d --build proxy`
- Vérifier: `curl -sS http://localhost/_health`

## Qualité
- Lint shell en CI (shellcheck). Les hooks pre-commit et Dependabot sont fournis à titre optionnel; aucune action n’est requise pour déployer.

## Feuille de route (à venir)
- Mode “réplique locale” avec bascule/fail‑back vers l’API officielle.
- Outillage d’observabilité (journaux et métriques) optionnel.

## Licence
- MIT — voir le fichier `LICENSE`.

## Attributions
- Ce projet agit comme un proxy de l’API Adresse officielle: `https://api-adresse.data.gouv.fr`.
- Les dénominations et marques citées appartiennent à leurs propriétaires.
- Non‑affiliation: GeoDock est un projet tiers, non affilié, validé ou sponsorisé par Etalab, La Poste, l’IGN ou tout autre organisme. Il consomme uniquement l’API publique et ne modifie pas les données.
