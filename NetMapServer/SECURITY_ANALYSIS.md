# NetMapServer — Analyse de sécurité

> Analyse effectuée le 3 mars 2026 sur la base du code source Vapor 4 / SQLite.

---

## ✅ Ce qui est bien fait

| Point | Détail |
|---|---|
| **Mots de passe** | Bcrypt — coût adaptatif, résistant au brute-force |
| **Tokens** | 32 octets aléatoires cryptographiquement sûrs (`UInt8.random`), 64 hex chars = 256 bits d'entropie |
| **TTL tokens** | `expiresAt` + `TokenCleanupLifecycle` — bonne pratique |
| **Isolation du rôle admin** | `AdminMiddleware` + `BearerAuthMiddleware` en composition — propre |
| **SQL injection** | Fluent ORM + `\(bind:)` sur les raw queries — pas de concaténation manuelle |
| **Dernier admin** | Impossible de supprimer le dernier admin — protège contre le lockout |

---

## 🔴 Problèmes critiques

### 1. Pas de TLS — tout transite en clair
Les tokens Bearer, les mots de passe au login, les données de capteurs — tout est en HTTP sur le LAN
(ou pire, sur internet si le port est ouvert). Un simple `tcpdump` sur le réseau suffit à capturer
les credentials.

**Correction** : mettre nginx en front avec TLS (voir section dédiée ci-dessous).

### 2. Clé API `netmap-dev` par défaut
```
[ WARNING ] Using default API key 'netmap-dev'
```
Tout le monde qui a lu le README peut écrire des données dans la DB. La DB accepte en ce moment
des `POST /api/records` sans aucune barrière réelle.

**Correction** : forcer `API_KEY` en variable d'environnement ; refuser le démarrage si la valeur
est `netmap-dev` en production.

### 3. Aucun rate limiting sur `/api/auth/login`
Brute-force illimité sur les mots de passe. Bcrypt ralentit mais n'arrête pas une attaque distribuée.

**Correction** : `limit_req` nginx (5 req/min par IP) ou middleware Vapor custom.

### 4. Aucune limite de taille de requête
Un `POST /api/vehicle-events` avec un payload de 100 MB passe. Vapor bufférise tout en mémoire
→ vecteur DoS.

**Correction** : `client_max_body_size 1m` dans nginx, ou `app.routes.defaultMaxBodySize = "1mb"` dans Vapor.

---

## 🟠 Problèmes importants

### 5. `/api/auth/setup` ouvert au démarrage
Entre le démarrage du serveur et la première connexion admin, `POST /api/auth/setup` accepte
n'importe qui comme premier admin. Race condition exploitable si le serveur est accessible réseau.

**Correction** : exiger un secret de setup (`SETUP_SECRET` env var) ou désactiver l'endpoint après
configuration.

### 6. Headers HTTP de sécurité absents
Aucun des headers standard n'est positionné :
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Content-Security-Policy`
- `Strict-Transport-Security` (HSTS)

**Correction** : middleware Vapor ou nginx (voir config ci-dessous).

### 7. CORS non configuré
Vapor laisse passer tous les `Origin`. Le dashboard web est donc appelable depuis n'importe quel
site tiers (vol de session via CSRF).

**Correction** : restreindre `Access-Control-Allow-Origin` à l'origine du dashboard.

### 8. `FileMiddleware` sert `Public/` sans restrictions
Si un fichier `.env`, `.db` ou autre sensible se retrouve dans `Public/`, il est téléchargeable
directement.

**Correction** : vérifier que seuls `index.html`, `app.js`, `style.css` sont dans `Public/`.
La DB (`netmap_data.db`) ne doit jamais être dans ce dossier.

### 9. Endpoints GET entièrement publics
`/api/sensors/latest`, `/api/assets`, `/api/vehicle-events` ne requièrent aucune authentification.
Toutes les données de capteurs, positions GPS, et télémétrie sont accessibles sans credentials.

**Correction** : requérir au minimum un token valide (même utilisateur non-admin) pour les GET
sensibles, ou activer le filtrage via `OptionalBearerAuthMiddleware` déjà en place.

---

## 🟡 Points mineurs

- `hostname = "0.0.0.0"` — écoute sur toutes les interfaces, y compris publiques. Préférable de
  lier à `127.0.0.1` et laisser nginx gérer l'exposition.
- Token invalidation partielle : `logout` invalide le token mais il n'y a pas de mécanisme de
  révocation globale ("déconnecter toutes les sessions").
- Les logs exposent les emails en clair dans les `INFO` (ex. `User created: phil@...`).

---

## Nginx en front — recommandation

**Fortement recommandé**, même pour un usage LAN.

```
Internet / LAN  ──→  nginx :443 (TLS)  ──→  Vapor 127.0.0.1:8765
```

| Besoin | nginx | Vapor seul |
|---|---|---|
| **TLS / HTTPS** (Let's Encrypt ou mkcert) | ✅ natif | ❌ complexe |
| **Rate limiting** par IP sur `/api/auth/login` | ✅ `limit_req` | ❌ aucun |
| **Limite taille requête** | ✅ `client_max_body_size` | ❌ aucun |
| **Headers de sécurité** | ✅ 3 lignes | ⚠️ middleware custom |
| **CORS** | ✅ | ⚠️ middleware custom |
| **Masquer `Server: vapor`** | ✅ `server_tokens off` | ❌ |
| **Gzip** | ✅ | ❌ |
| **Protection slowloris** | ✅ | ❌ |
| **Binding interne** (Vapor sur 127.0.0.1 seulement) | ✅ | ❌ |

### Config nginx minimale

```nginx
# Rate limiting — zone définie au niveau http {}
limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;

server {
    listen 443 ssl http2;
    server_name netmap.local;

    ssl_certificate     /etc/letsencrypt/live/netmap.local/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/netmap.local/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Headers de sécurité
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options    "nosniff"                             always;
    add_header X-Frame-Options           "DENY"                                always;
    add_header Content-Security-Policy   "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'" always;
    server_tokens off;

    # Limite taille requête (protège POST /api/vehicle-events batch)
    client_max_body_size 1m;

    # Rate limiting sur login uniquement
    location /api/auth/login {
        limit_req zone=login burst=3 nodelay;
        proxy_pass         http://127.0.0.1:8765;
        proxy_set_header   Host            $host;
        proxy_set_header   X-Real-IP       $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location / {
        proxy_pass         http://127.0.0.1:8765;
        proxy_set_header   Host            $host;
        proxy_set_header   X-Real-IP       $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 30s;
    }
}

# Redirect HTTP → HTTPS
server {
    listen 80;
    server_name netmap.local;
    return 301 https://$host$request_uri;
}
```

### Pour un usage LAN sans domaine public

Utiliser [mkcert](https://github.com/FiloSottile/mkcert) pour générer un CA local reconnu par vos
appareils (macOS, iOS) sans avertissement de certificat :

```bash
brew install mkcert
mkcert -install                        # installe le CA dans le trousseau macOS + iOS via profil
mkcert netmap.local 192.168.1.18       # génère le certificat
```

Ensuite changer le binding Vapor dans `configure.swift` :

```swift
// Lier uniquement sur loopback — nginx gère l'exposition
app.http.server.configuration.hostname = "127.0.0.1"
```

---

## Actions prioritaires (par ordre)

1. **[ CRITIQUE ]** Changer la clé API par défaut (`API_KEY` env var)
2. **[ CRITIQUE ]** Mettre nginx en front + TLS (mkcert pour LAN)
3. **[ IMPORTANT ]** Lier Vapor sur `127.0.0.1` uniquement
4. **[ IMPORTANT ]** Ajouter `client_max_body_size 1m` (nginx) ou Vapor middleware
5. **[ IMPORTANT ]** Rate limiting login via nginx `limit_req`
6. **[ MOYEN ]** Restreindre les GET publics aux utilisateurs authentifiés
7. **[ MINEUR ]** Headers de sécurité via nginx
