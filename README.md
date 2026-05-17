# GeoDock V2

[![CI](https://github.com/jbjardine/GeoDock/actions/workflows/proxy-ci.yml/badge.svg?branch=main)](https://github.com/jbjardine/GeoDock/actions/workflows/proxy-ci.yml)
[![Release](https://img.shields.io/github/v/release/jbjardine/GeoDock?sort=semver)](https://github.com/jbjardine/GeoDock/releases/latest)
[![License](https://img.shields.io/github/license/jbjardine/GeoDock)](LICENSE)
[![GHCR proxy](https://img.shields.io/badge/GHCR-geodock--proxy-2496ED?logo=docker&logoColor=white)](https://github.com/users/jbjardine/packages/container/package/geodock-proxy)
[![GHCR runtime](https://img.shields.io/badge/GHCR-geodock--runtime-2496ED?logo=docker&logoColor=white)](https://github.com/users/jbjardine/packages/container/package/geodock-runtime)

GeoDock V2 expose une API locale compatible avec `https://api-adresse.data.gouv.fr`.
Le paquet fournit le proxy, le runtime local, le bootstrap des index, le suivi
d'etat et les scripts d'exploitation.

Modes officiels :

- `proxy` : toutes les requetes passent par l'API officielle.
- `local` : toutes les requetes passent par le backend local.
- `hybrid` : le local est prioritaire, avec repli distant si le local n'est pas pret.
- `failback` : le distant est prioritaire, avec repli local si l'amont echoue.

## Prerequis

- Linux x86_64 recommande pour la production.
- Docker Engine avec Docker Compose v2.
- Acces reseau sortant vers les sources publiques utilisees par le bootstrap local.
- En production, un FQDN interne stable, par exemple `geodock.intra`.

L'utilisateur doit pouvoir executer Docker. Utiliser `sudo`, ou ajouter
l'utilisateur au groupe `docker` selon la politique de la machine.

## Demarrage rapide

```bash
bash scripts/doctor.sh
bash scripts/geodock_up.sh
```

Le script guide les choix utiles :

- mode `proxy`, `local`, `hybrid` ou `failback`;
- nom d'hote / FQDN;
- portee locale : departements choisis ou France entiere;
- liste des departements si necessaire;
- mise a jour locale automatique hebdomadaire.

Verifier ensuite :

```bash
bash scripts/geodock_status.sh
bash scripts/geodock_verify.sh
```

## Fonctionnement

La stack expose par defaut :

- HTTP : port `80`;
- HTTPS : port `443`;
- healthcheck : `/_health`;
- statut detaille : `/_status`.

Les ports peuvent etre changes avec `HOST_PORT_HTTP` et `HOST_PORT_HTTPS`.
Les certificats se placent dans `proxy/certs/tls.crt` et
`proxy/certs/tls.key`. Si aucun certificat n'est fourni, le conteneur proxy
genere un certificat auto-signe.

Le statut JSON indique le mode actif, l'upstream utilise, la disponibilite de
`address`, `parcel`, `poi` et `api`, l'etape courante et la progression.

## Configuration

Les exemples publics sont :

- `.env.example` pour GeoDock V2 complet;
- `.env.proxy.example` pour le proxy seul.

Ne jamais commiter `.env`, certificats prives, cles ou artefacts de
qualification. Ils sont ignores par defaut.

Variables principales :

- `MODE=proxy|local|hybrid|failback`
- `SERVER_NAME=geodock.intra`
- `LOCAL_SCOPE=departements|france`
- `LOCAL_DEPARTEMENTS=75,92,93,94`
- `LOCAL_AUTO_UPDATE=true|false`
- `LOCAL_UPDATE_SCHEDULE_CRON=0 3 * * 1`
- `GEODOCK_USE_GHCR=true|false`

## Commandes

- Installation / premier demarrage : `bash scripts/geodock_up.sh`
- Statut : `bash scripts/geodock_status.sh`
- Verification : `bash scripts/geodock_verify.sh`
- Reconfiguration : `bash scripts/geodock_reconfigure.sh`
- Mise a jour locale immediate : `bash scripts/geodock_update_now.sh`
- Arret : `bash scripts/stack_stop.sh --down`
- Package release : `bash scripts/release_v2.sh`

## Documentation

- Installation complete : `docs/install/unified.md`
- Proxy seul : `docs/install/proxy.md`
- Qualification V2 : `docs/ops/v2-qualification.md`
- Certificats : `docs/ops/certificates.md`
- Durcissement : `docs/ops/hardening.md`

## Qualification

La CI publique valide la syntaxe YAML/shell/Python, les tests QA cibles,
la configuration Compose, le build proxy, le smoke HTTP/HTTPS et le package V2.

Le gate long prod-like, le restart Docker root-level et le reboot hote restent
des validations operateur documentees dans `docs/ops/v2-qualification.md`.

## Licence

MIT - voir `LICENSE`.
