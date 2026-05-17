# Qualification V2

Cette page decrit les controles de publication GeoDock V2.

## CI publique

La CI GitHub Actions execute les controles courts suivants :

- parsing du workflow YAML;
- syntaxe shell;
- ShellCheck;
- compilation Python;
- tests QA cibles;
- validation Docker Compose;
- build proxy;
- smoke HTTP/HTTPS du proxy;
- creation du package V2.

La CI ne lance pas la qualification France entiere 24 h ni les tests root-level,
car ces controles dependent d'un serveur dedie.

## Scripts de qualification

- `bash scripts/qa_preflight.sh`
- `bash scripts/qa_smoke_matrix.sh`
- `bash scripts/qa_distribution.sh`
- `bash scripts/qa_upgrade.sh`
- `bash scripts/qa_prodlike_long.sh`
- `MASTER_ID=<id> bash scripts/qa_terminal_gate.sh forensics`
- `MASTER_ID=<id> bash scripts/qa_terminal_gate.sh prodlike`
- `MASTER_ID=<id> bash scripts/qa_terminal_gate.sh rootdocker`
- `MASTER_ID=<id> bash scripts/qa_terminal_gate.sh pre-reboot`
- `MASTER_ID=<id> bash scripts/qa_terminal_gate.sh post-reboot`
- `MASTER_ID=<id> bash scripts/qa_terminal_gate.sh all`

## Ordre recommande

Staging court :

```bash
bash scripts/qa_preflight.sh
bash scripts/qa_smoke_matrix.sh
bash scripts/qa_distribution.sh
bash scripts/qa_upgrade.sh
```

Gate terminal prod-like :

```bash
MASTER_ID=finalgate-$(date -u +%Y%m%dT%H%M%SZ) bash scripts/qa_terminal_gate.sh forensics
MASTER_ID=finalgate-<ts> QA_MIN_DISK_GIB=390 QA_MIN_RAM_GIB=30 QA_SOAK_HOURS=24 QA_SOAK_INTERVAL_SEC=300 bash scripts/qa_terminal_gate.sh prodlike
MASTER_ID=finalgate-<ts> QA_MIN_DISK_GIB=390 QA_MIN_RAM_GIB=30 QA_SCOPE_DEPARTEMENTS=11,75,92 bash scripts/qa_terminal_gate.sh rootdocker
MASTER_ID=finalgate-<ts> bash scripts/qa_terminal_gate.sh pre-reboot
```

La phase `pre-reboot` installe le service post-reboot et declenche le reboot
hote. Le service relance ensuite `post-reboot`, puis ecrit `reboot.ok` et
`PUBLIC_GO` si tous les marqueurs precedents sont presents.

## Profil low-RAM explicite

Sur un banc 11-12 GiB qui prouve bien `ready` France entiere :

```bash
MASTER_ID=finalgate-<ts> QA_MIN_DISK_GIB=390 QA_MIN_RAM_GIB=11 QA_RAM_STABLE_MODE=swap QA_MIN_SWAP_FREE_MIB=8192 QA_SOAK_HOURS=24 QA_SOAK_INTERVAL_SEC=300 bash scripts/qa_terminal_gate.sh prodlike
MASTER_ID=finalgate-<ts> QA_MIN_DISK_GIB=390 QA_MIN_RAM_GIB=11 QA_RAM_STABLE_MODE=swap QA_MIN_SWAP_FREE_MIB=8192 QA_SCOPE_DEPARTEMENTS=11,75,92 bash scripts/qa_terminal_gate.sh rootdocker
```

Ce profil ne remplace pas les verifications fonctionnelles : le runtime doit
rester `ready`, sans `error` ni `degraded`, avec `address`, `parcel`, `poi` et
`api` disponibles.

## Marqueurs terminaux

Les marqueurs sont ecrits dans `qa-artifacts/<MASTER_ID>/` :

- `prodlike.ok`
- `rootdocker.ok`
- `reboot.pending`
- `reboot.ok`
- `PUBLIC_GO`
- `FAILED`

Pour publication, `PUBLIC_GO` doit etre present et `FAILED` absent.

## Gates rappeles

- Proxy pret en `<= 10 min`.
- Premiere reponse utile `hybrid` / `failback` en `<= 5 min`.
- Smoke local `11,75,92` pret en `<= 2 h`.
- France entiere prete en `<= 24 h`.
- `>= 80 GiB` libres apres qualification France.
- RAM stable par defaut : `QA_MIN_RAM_FREE_PERCENT=20`.
- Profil low-RAM : `QA_RAM_STABLE_MODE=swap` avec `QA_MIN_SWAP_FREE_MIB`.
