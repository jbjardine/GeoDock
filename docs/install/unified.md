# Installation — Stack unifiee

Ce guide deploye le proxy GeoDock et le runtime local `gpf-geocodeur` pour les modes `proxy`, `local`, `failback` et `hybrid`.

Prérequis:

- Linux x86_64
- Docker Engine + Compose v2
- URLs d'archives HTTP pour `address`, `parcel` et `poi`, ou endpoints `*_ARCHIVE_URL_RESOLVER`

## 1) Initialiser l'environnement

```bash
cp .env.example .env
```

Renseigner au minimum :

- `MODE=proxy|local|failback|hybrid`
- `SERVER_NAME`
- `ADDRESS_ARCHIVE_URL`, `PARCEL_ARCHIVE_URL`, `POI_ARCHIVE_URL`

Les variables `*_ARCHIVE_URL_RESOLVER` restent possibles si votre serveur d'index publie des endpoints texte brut pointant vers l'archive finale.

Si vos archives `poi` sont volumineuses, laissez `POI_ADDOK_CLUSTER_NUM_NODES=1` au depart. Cela evite un burst de demarrage Addok trop agressif sur des petites machines.

## 2) Démarrer la stack

```bash
bash scripts/unified_up.sh
```

Le script construit l'image `geodock/geocodeur:local` depuis le dépôt officiel `gpf-geocodeur`, puis lance le proxy et le backend local.

## 3) Vérifier le mode actif

```bash
bash scripts/mode_verify.sh
```

En HTTPS avec certificat auto-signé :

```bash
BASE=https://localhost INSECURE_SSL=1 bash scripts/mode_verify.sh
```

## 4) Mises a jour optionnelles

Pour activer le service `updater` et Watchtower :

```bash
docker compose -f docker-compose.yml -f docker-compose.git.yml --profile local --profile ops up -d
```

Le service `updater` compare l'ETag ou la date de modification des archives et recharge les index locaux si necessaire.
