# Installation - Mode proxy seul

Ce guide deploie uniquement le proxy Nginx. Toutes les requetes sont relayees
vers l'API officielle, sans backend local ni construction d'index.

Pour GeoDock V2 complet avec les modes `local`, `hybrid` et `failback`, voir
`docs/install/unified.md`.

## 1. Prerequis

- Linux x86_64.
- Docker Engine et Docker Compose v2.
- Droits Docker pour l'utilisateur.

Le proxy expose par defaut les ports `80` et `443`.

## 2. Configuration

Le fichier public de reference est `.env.proxy.example`.

Variables principales :

- `MODE=remote`
- `SERVER_NAME=geodock.intra`
- `UPSTREAM_BAN=https://api-adresse.data.gouv.fr`
- `HOST_PORT_HTTP=80`
- `HOST_PORT_HTTPS=443`
- `REDIRECT_HTTP_TO_HTTPS=false`
- `EXPOSE_HEALTH_ON_HTTP=true`

Le mode par defaut est un pont TLS : HTTP est accepte cote clients, et le proxy
contacte l'amont officiel en HTTPS.

## 3. Demarrer

```bash
bash scripts/doctor.sh
bash scripts/proxy_up.sh
```

Le script cree `.env` si absent, force le mode proxy seul et demarre le service.

## 4. Verifier

```bash
bash scripts/proxy_verify.sh
curl -sS http://localhost/_health
curl -k -sS https://localhost/_health
```

Une recherche simple doit renvoyer une reponse GeoJSON :

```bash
curl -sS "http://localhost/search/?q=paris&limit=1"
```

## 5. Certificats

Monter les certificats dans :

- `proxy/certs/tls.crt`
- `proxy/certs/tls.key`

Ces fichiers sont ignores par Git. Si aucun certificat n'est fourni, un
certificat auto-signe est genere au demarrage.

## 6. Arret

```bash
bash scripts/stack_stop.sh --down
```

## 7. Parite optionnelle

```bash
BASE=http://localhost \
REMOTE_BASE=https://api-adresse.data.gouv.fr \
python3 scripts/parity_check.py
```
