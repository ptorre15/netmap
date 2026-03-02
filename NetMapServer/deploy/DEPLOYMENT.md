# NetMapServer — Déploiement bare metal (Linux)

Cible supportée : **Ubuntu 22.04 LTS** et **Ubuntu 24.04 LTS**.

---

## Prérequis

- Serveur Linux avec accès root
- Accès SSH par clé publique depuis votre Mac
- Port `8765` ouvert (ou configurez `PORT`)

---

## Première installation

### 1. Copier les sources sur le serveur

Depuis votre Mac, dans le dossier `NetMapServer/` :

```bash
SERVER=admin@192.168.1.x   # ajustez selon votre serveur

ssh $SERVER "mkdir -p /opt/netmap/src"
rsync -az --exclude='.build/' --exclude='*.db' --exclude='.DS_Store' \
  ./ $SERVER:/opt/netmap/src/
```

### 2. Lancer le script d'installation

Sur le serveur :

```bash
sudo bash /opt/netmap/src/deploy/install.sh
```

Le script effectue automatiquement :

| Étape | Détail |
|---|---|
| Dépendances système | `libsqlite3-dev`, `libcurl4-openssl-dev`, etc. |
| Swift 6.0.3 | Installé dans `/usr/local/swift` |
| Utilisateur système | `netmap` (sans shell) |
| Répertoires | `/opt/netmap/{bin,Public,data}` |
| Compilation | `swift build -c release` |
| Fichier d'env | `/etc/netmap/netmap-server.env` (généré à la première install) |
| Service systemd | `netmap-server` activé et démarré |

> **⚠️ API_KEY** : générée automatiquement à la première installation et affichée **une seule fois** dans la console. Notez-la.

---

## Variables d'environnement

Fichier : `/etc/netmap/netmap-server.env`

| Variable | Défaut | Description |
|---|---|---|
| `PORT` | `8765` | Port d'écoute TCP |
| `DB_PATH` | `/opt/netmap/data/netmap_data.db` | Chemin de la base SQLite |
| `API_KEY` | *(générée)* | Clé API requise par l'app iOS |

Après modification du fichier, redémarrer le service :

```bash
sudo systemctl restart netmap-server
```

---

## Mises à jour

Depuis votre Mac, dans le dossier `NetMapServer/` :

```bash
./deploy/update.sh admin@192.168.1.x
```

Le script :
1. Synchronise les sources via `rsync`
2. Compile en Release **sur le serveur**
3. Remplace le binaire de façon atomique
4. Redémarre le service

---

## Commandes utiles (sur le serveur)

```bash
# Statut du service
sudo systemctl status netmap-server

# Logs en direct
sudo journalctl -u netmap-server -f

# Dernières 50 lignes de logs
sudo journalctl -u netmap-server -n 50

# Redémarrage manuel
sudo systemctl restart netmap-server

# Arrêt
sudo systemctl stop netmap-server
```

---

## Structure des répertoires (sur le serveur)

```
/opt/netmap/
├── bin/
│   └── netmap-server        ← binaire compilé
├── data/
│   └── netmap_data.db       ← base SQLite (à sauvegarder)
├── Public/
│   ├── index.html
│   ├── app.js
│   └── style.css
└── src/                     ← sources synchronisées
    ├── Sources/
    ├── Public/
    └── Package.swift

/etc/netmap/
└── netmap-server.env        ← variables d'environnement (PORT, DB_PATH, API_KEY)
```

---

## Sauvegarde

Le seul fichier à sauvegarder est la base de données :

```bash
/opt/netmap/data/netmap_data.db
```

Exemple de sauvegarde quotidienne via cron (`crontab -e` en root) :

```cron
0 3 * * * cp /opt/netmap/data/netmap_data.db /opt/netmap/data/netmap_data.db.$(date +\%Y\%m\%d)
```
