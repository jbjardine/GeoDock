# Durcissement (optionnel)

Ces réglages réduisent l’empreinte et le périmètre d’attaque du conteneur. Tester avant déploiement.

## Compose override

Utiliser l’override suivant en plus du fichier principal:

```
 docker compose -f docker-compose.proxy.yml -f docker-compose.hardening.yml up -d --build proxy
```

Contenu de `docker-compose.hardening.yml`:

- `read_only: true`: système de fichiers racine en lecture seule.
- `tmpfs: [/var/cache/nginx, /var/run]`: points d’écriture en mémoire pour Nginx.
- `security_opt: no-new-privileges`: empêche l’élévation de privilèges.
- `cap_drop: [ALL]` + `cap_add: [NET_BIND_SERVICE]`: supprime toutes les capabilities sauf le binding sur 80/443.

## Notes

- Rester en Linux x86_64, comme décidé.
- Non-root possible mais nécessite des ajustements (ports >1024 ou reverse proxy externe). Non traité ici.
- Journaux: Nginx écrit sur stdout/stderr (format classique). JSON possible via `log_format` si besoin.