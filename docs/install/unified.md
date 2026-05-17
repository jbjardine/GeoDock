# Installation - GeoDock V2 tout-en-un

GeoDock V2 installe dans un seul paquet :

- le proxy Nginx;
- le runtime local `gpf-geocodeur`;
- le bootstrap local des index `address`, `parcel`, `poi`;
- le refresh local periodique;
- le suivi d'etat CLI et HTTP.

## 1. Prerequis

- Linux x86_64.
- Docker Engine et Docker Compose v2.
- Droits Docker pour l'utilisateur qui lance les scripts.
- Acces sortant vers `api-adresse.data.gouv.fr`, GitHub/GHCR si utilise, et
  les sources publiques des donnees geographiques.

Pour un serveur de production, preparer un FQDN interne stable, par exemple
`geodock.intra`.

## 2. Installation guidee

Depuis la racine du depot ou du tarball :

```bash
bash scripts/doctor.sh
bash scripts/geodock_up.sh
```

Le script demande :

- le mode : `proxy`, `local`, `hybrid`, `failback`;
- le FQDN expose;
- la portee locale : departements choisis ou France entiere;
- la liste des departements si besoin;
- l'activation des mises a jour automatiques.

Le chemin recommande est `LOCAL_SOURCE=build`. Les variables
`ADDRESS_ARCHIVE_URL`, `PARCEL_ARCHIVE_URL` et `POI_ARCHIVE_URL` restent
disponibles pour compatibilite avancee, mais ne sont pas le parcours standard.

## 3. Modes

- `proxy` : demarrage rapide, aucun backend local requis.
- `local` : toutes les requetes utilisent le backend local.
- `hybrid` : le proxy sert le distant pendant le bootstrap, puis privilegie le local.
- `failback` : le distant reste prioritaire, le local prend le relais en cas d'echec amont.

`hybrid` est le mode recommande pour une premiere installation locale, car il
donne une premiere reponse utile pendant la construction des index.

## 4. Suivre l'installation

```bash
bash scripts/geodock_status.sh
curl -sS http://localhost/_status
curl -k -sS https://localhost/_status
```

Le statut expose :

- l'etat global (`starting`, `bootstrapping`, `building`, `ready`, `degraded`, `error`);
- le mode actif;
- l'upstream courant;
- la disponibilite locale de `address`, `parcel`, `poi`, `api`;
- l'etape courante et la progression.

## 5. Verifier

```bash
bash scripts/geodock_verify.sh
```

Pour forcer des attentes precises :

```bash
EXPECT_MODE=hybrid EXPECT_UPSTREAM=local VERIFY_PARCEL=1 VERIFY_POI=1 bash scripts/geodock_verify.sh
```

## 6. Reconfigurer

```bash
bash scripts/geodock_reconfigure.sh
```

La reconfiguration garde les artefacts locaux existants quand ils restent
compatibles avec la nouvelle portee.

## 7. Mise a jour locale

```bash
bash scripts/geodock_update_now.sh
```

La mise a jour automatique utilise `LOCAL_UPDATE_SCHEDULE_CRON`.

## 8. Certificats et secrets

Certificats attendus :

- `proxy/certs/tls.crt`
- `proxy/certs/tls.key`

Ces fichiers sont ignores par Git. Ne pas commiter `.env`, certificats,
cles privees, tokens, dumps ou artefacts `qa-artifacts`.

Si aucun certificat n'est monte, le proxy genere un certificat auto-signe.

## 9. Arret et nettoyage

```bash
bash scripts/stack_stop.sh --down
```

Les volumes Docker et les artefacts locaux doivent etre conserves ou supprimes
selon la politique d'exploitation du serveur.

## 10. Qualification

La CI publique couvre les controles courts. La qualification prod-like longue,
le restart Docker root-level et le reboot hote sont documentes dans
`docs/ops/v2-qualification.md`.
