# Certificats TLS (HTTPS côté clients)

Ce projet fonctionne en « TLS bridge » par défaut: les clients peuvent parler en HTTP au proxy, et le proxy chiffre en HTTPS vers l’API amont. Si vous souhaitez forcer HTTPS côté clients, suivez ce guide.

## Choisir un nom (FQDN)
- Demander à l’IT un enregistrement DNS interne (A/AAAA), ex: `GeoDock.intra`.
- Éviter `.local` (mDNS), préférer un FQDN de votre domaine interne.

## Obtenir un certificat
- Recommandé: certificat émis par la PKI interne pour le FQDN, avec SAN (SubjectAltName) au minimum `DNS:GeoDock.intra`. Optionnel: `IP:<adresse>`.
- Chaîne complète: le fichier `.crt` doit contenir le certificat serveur suivi des intermédiaires (full chain).

Exemple CSR avec SAN (OpenSSL ≥ 1.1.1):

```
openssl genrsa -out tls.key 2048
openssl req -new -key tls.key -out tls.csr -subj "/CN=GeoDock.intra" \
  -addext "subjectAltName=DNS:GeoDock.intra"
```

Faites signer `tls.csr` par la PKI et récupérez la chaîne complète dans `tls.crt`.

## Déposer les certificats (Docker)
- Placer les fichiers sur le serveur dans `proxy/certs/`:
  - `proxy/certs/tls.crt` (chaîne complète)
  - `proxy/certs/tls.key` (clé privée)
- Lancer/recharger:

```
docker compose -f docker-compose.proxy.yml up -d --build proxy
```

Vous pouvez utiliser le script d’aide `scripts/certs_install.sh` (voir ci‑dessous).

## Basculer en HTTPS strict
- Dans `.env`:
  - `SERVER_NAME=GeoDock.intra`
  - `REDIRECT_HTTP_TO_HTTPS=true`
  - Option: `EXPOSE_HEALTH_ON_HTTP=false` pour rediriger aussi `/_health`.

## Vérifier

```
curl -vkI https://GeoDock.intra/_health
```

Si la PKI interne est approuvée par vos postes, vous pouvez enlever `-k`.

## Dépôt automatisé (script)
Le script `scripts/certs_install.sh` copie, vérifie et recharge Nginx.

Usage:

```
bash scripts/certs_install.sh -c /chemin/vers/tls.crt -k /chemin/vers/tls.key
```

Le script:
- vérifie l’existence des fichiers,
- sauvegarde l’ancien couple,
- compare que la clé et le cert correspondent,
- copie dans `proxy/certs/`, corrige les permissions,
- redéploie le service `proxy`.

## Permissions et remarques
- Accès Docker: pour installer “dans le conteneur”, l’utilisateur doit avoir accès à Docker (`docker ps`).
  - Sinon, lancer avec `sudo` (ex.: `sudo bash scripts/certs_install.sh ...`) ou ajouter l’utilisateur au groupe `docker` puis se reconnecter.
- Bind mount `proxy/certs/`: si les fichiers existants appartiennent à `root` en `600`, l’écriture locale peut nécessiter `sudo`.
- Conteneur non démarré: le script tente une installation sur l’hôte puis démarre le proxy; si les permissions locales manquent, relancer avec `sudo`.
