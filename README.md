# GeoDock — Proxy + Runtime local de l’API Adresse

[![proxy-ci](https://github.com/jbjardine/GeoDock/actions/workflows/proxy-ci.yml/badge.svg?branch=main)](https://github.com/jbjardine/GeoDock/actions/workflows/proxy-ci.yml)

Objectif: exposer en local les mêmes endpoints et schémas que `https://api-adresse.data.gouv.fr`, soit en mode proxy pur, soit avec un runtime local `gpf-geocodeur` alimenté par des archives d’index HTTP.

## Prérequis
- Docker + Docker Compose
- Plateforme: Linux x86_64 pour la production (recommandé). Windows possible pour dev/tests via Docker Desktop, à éviter en production; préférer un serveur Linux ou une VM/WSL2.
- DNS/hosts: faire résoudre `GeoDock.intra` (ou un FQDN interne) vers l’hôte Docker (ou utiliser l’IP pour tester).

## Démarrage rapide

### Option A — Proxy only
- Diagnostic: `bash scripts/doctor.sh`
- Démarrer le proxy: `bash scripts/proxy_up.sh`
- Vérifier: `bash scripts/proxy_verify.sh`
  - Mode par défaut: TLS bridge (HTTP accepté, proxy → amont en HTTPS).
  - Redirection HTTP→HTTPS désactivée par défaut (`REDIRECT_HTTP_TO_HTTPS=false`).
  - Option: exposer/masquer `/_health` en HTTP via `EXPOSE_HEALTH_ON_HTTP=true|false` (false = 100 % HTTPS).
  - Parité rapide vs officiel: `BASE=http://localhost REMOTE_BASE=https://api-adresse.data.gouv.fr python3 scripts/parity_check.py`

Guide détaillé: voir `docs/install/proxy.md`.

### Option B — Stack unifiée
- Copier `.env.example` vers `.env`
- Renseigner `MODE=proxy|local|failback|hybrid`
- Renseigner les URLs d’archives HTTP :
  - `ADDRESS_ARCHIVE_URL`
  - `PARCEL_ARCHIVE_URL`
  - `POI_ARCHIVE_URL`
- Démarrer: `bash scripts/unified_up.sh`
- Vérifier le mode actif: `bash scripts/mode_verify.sh`

Guide détaillé: voir `docs/install/unified.md`.

## Fonctionnement
- `proxy` ou `remote`: 100 % des requêtes vers l’API officielle
- `local`: 100 % vers le backend local
- `failback`: distant puis repli local sur erreur amont
- `hybrid`: local puis repli distant sur erreur locale

Les réponses exposent les en-têtes de debug :

- `X-Geodock-Mode`
- `X-Geodock-Upstream`

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

## Runtime local
- Le runtime local repose sur le dépôt officiel `gpf-geocodeur`, construit via `docker-compose.git.yml`.
- Le contrat d’échange retenu avec le builder privé est simple :
  - `index-address-latest.tar.gz`
  - `index-parcel-latest.tar.gz`
  - `index-poi-latest.tar.gz`
- `catalog.json` reste un artefact de métadonnées et d’audit ; le runtime public consomme directement les archives HTTP.
- Les variables `*_ARCHIVE_URL_RESOLVER` restent supportées pour un endpoint texte brut renvoyant l’URL finale de l’archive.

## Qualité
- Lint shell en CI (shellcheck). Les hooks pre-commit et Dependabot sont fournis à titre optionnel; aucune action n’est requise pour déployer.

## Licence
- MIT — voir le fichier `LICENSE`.

## Attributions
- Ce projet agit comme un proxy de l’API Adresse officielle: `https://api-adresse.data.gouv.fr`.
- Les dénominations et marques citées appartiennent à leurs propriétaires.
- Non‑affiliation: GeoDock est un projet tiers, non affilié, validé ou sponsorisé par Etalab, La Poste, l’IGN ou tout autre organisme. Il consomme uniquement l’API publique et ne modifie pas les données.
