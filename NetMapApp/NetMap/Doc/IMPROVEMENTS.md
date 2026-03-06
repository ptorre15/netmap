# NetMap — Pistes d'amélioration

Ce document liste les améliorations possibles, classées par domaine et par priorité estimée.

---

## Sécurité & Production

### 🔴 Priorité haute

**HTTPS obligatoire**
Le serveur écoute en HTTP. Tout le trafic (tokens Bearer, clé API, données GPS) transite en clair.
→ Ajouter un reverse proxy (nginx / Caddy) avec certificat Let's Encrypt, ou activer TLS directement dans Vapor via `app.http.server.configuration.tlsConfiguration`.

**Rotation de la clé API**
La clé `X-API-Key` est statique. Une compromission nécessite un redémarrage du serveur.
→ Stocker la clé en DB, ajouter un endpoint admin `POST /api/api-key/rotate` qui génère une nouvelle clé et invalide l'ancienne.

**Expiration configurable des tokens**
Les tokens Bearer durent 7 jours en dur dans le code.
→ Rendre la durée configurable via env var `TOKEN_TTL_DAYS`, ajouter une route `POST /api/auth/refresh` pour renouveler sans re-authentification.

**Nettoyage automatique des tokens expirés**
Les tokens expirés restent en DB indéfiniment.
→ Ajouter un job planifié Vapor (`app.queues` ou une `ScheduledJob`) qui purge les tokens expirés quotidiennement.

### 🟡 Priorité moyenne

**Rate limiting**
Aucune protection contre le brute force sur `/api/auth/login`.
→ Intégrer `vapor/rate-limit` ou un middleware maison basé sur l'IP + compteur in-memory.

**Audit log**
Les actions admin (création de véhicule, suppression de données) ne sont pas tracées.
→ Ajouter une table `AuditLog(action, username, entityType, entityID, timestamp)` alimentée par les controllers.

---

## Données & Analytics

### 🔴 Priorité haute

**Détection de crevaison lente (côté serveur)**
`slowPunctureDetected()` a été supprimé du client iOS car il dépendait de l'historique local. La logique n'existe nulle part.
→ Implémenter dans `RecordController` : comparer la pression moyenne des 30 dernières minutes à la moyenne de la session, déclencher une alerte si la chute dépasse un seuil configurable.

**Notifications push iOS**
L'app ne prévient pas l'utilisateur d'une anomalie de pression.
→ Envoyer des notifications APNs via le serveur (Apple Push Notification service) quand une alerte est générée. Nécessite : enregistrement du device token, endpoint `POST /api/devices/push-token`, intégration APNs.

### 🟡 Priorité moyenne

**Agrégation des données historiques**
`GET /api/records/by-sensor/:id` peut retourner jusqu'à 100 000 lignes, ce qui est lourd pour les graphiques.
→ Ajouter un endpoint `GET /api/records/by-sensor/:id/aggregate?resolution=1h` qui renvoie une moyenne par intervalle (1 min, 5 min, 1 h) calculée en SQL.

**Statistiques par véhicule**
Aucun endpoint ne résume la santé globale d'un véhicule.
→ `GET /api/vehicles/:id/summary` : pression min/max/avg par capteur, nombre d'alertes, dernière position GPS.

**Rétention configurable**
`DELETE /api/records/purge` supprime tout en une seule opération.
→ Ajouter `?olderThanDays=90` au purge. Ajouter un job de rétention automatique configurable via `DATA_RETENTION_DAYS`.

**Export CSV / JSON**
Pas d'export des données.
→ `GET /api/records/export?vehicle=&from=&to=&format=csv` pour l'historique complet.

---

## Application iOS/macOS

### 🔴 Priorité haute

**Suppression des anciennes clés UserDefaults**
La clé `history_v1` existe potentiellement sur les installations existantes ayant eu l'historique local.
→ Ajouter une migration one-shot dans `NetMapApp.init()` qui retire `history_v1` de UserDefaults.

**Gestion des erreurs réseau dans `SensorHistoryView`**
Les erreurs réseau affichent un message générique.
→ Distinguer les cas (serveur injoignable, token expiré → redirection login, pas de données).

**Reconnexion automatique en cas d'expiration de token**
Si le token serveur expire, les requêtes iOS échouent silencieusement.
→ Détecter `401` dans `NetMapServerClient`, effacer les credentials, notifier l'utilisateur.

### 🟡 Priorité moyenne

**Mode hors-ligne avec file d'attente**
Si le serveur est injoignable, les relevés BLE sont perdus.
→ Ajouter une file d'attente locale (CoreData ou SQLite) qui bufferise les `SensorPayload` non envoyés et les rejoue à la reconnexion.

**Widget iOS (WidgetKit)**
Afficher la pression actuelle de chaque roue dans un widget écran d'accueil.
→ Créer une `AppIntentTimelineProvider` qui lit le dernier relevé en cache `UserDefaults` (shared App Group).

**Alertes visuelles par seuil**
Il n'y a pas d'indicateur coloré si la pression est hors tolérance.
→ Comparer `latestPressureBar` à `targetPressureBar ± 15 %` et colorier les badges (vert/orange/rouge) dans `VehicleDetailView` et `VehicleMapView`.

**Conformité Swift 6 / Sendable**
Un warning `CBCentralManagerDelegate` crosses into main actor-isolated code subsiste dans `BLEScanner.swift`.
→ Marquer `BLEScanner` comme `@MainActor` ou isoler les callbacks de delegate dans un `Task { @MainActor in … }`.

### 🟢 Priorité basse

**Partage de live data entre appareils**
Si plusieurs iPhones roulent ensemble, chacun envoie ses propres relevés mais ne voit pas ceux des autres.
→ Le tableau de bord web agrège déjà tout ; l'app iOS pourrait consommer `GET /api/sensors/latest` pour afficher les capteurs des autres véhicules.

**WatchOS companion app**
Glance rapide de la pression sur Apple Watch.

---

## Tableau de bord web

### 🟡 Priorité moyenne

**Authentification par rôle `user`**
Les comptes de rôle `user` existent en DB mais l'interface web ne différencie pas encore finement leurs droits (ex. : lecture seule de l'historique).
→ Masquer les boutons d'édition véhicule si `AUTH.role !== "admin"`, déjà partiellement fait ; vérifier les cas restants.

**Graphique de tendance multi-capteurs**
Le graphique actuel ne permet pas de comparer plusieurs capteurs sur le même axe.
→ Ajouter un mode multi-ligne avec légende interactive (Chart.js ou D3).

**Carte historique (replay)**
La carte affiche uniquement la dernière position connue.
→ Ajouter un curseur temporel qui rejoue le trajet d'un véhicule sur la carte (données GPS des relevés).

**Responsive / mobile**
Le tableau de bord n'est pas optimisé pour mobile.
→ Refactorer le CSS en CSS Grid / Flexbox responsive, tester sur viewport < 768 px.

**PWA (Progressive Web App)**
→ Ajouter un `manifest.json` et un service worker pour permettre l'installation sur l'écran d'accueil et un accès hors-ligne basique.

---

## Infrastructure & DevOps

### 🟡 Priorité moyenne

**Dockerfile**
Aucune image Docker n'existe.
→ Créer un `Dockerfile` multi-stage (builder swift:5.10 → runner ubuntu:22.04) et un `docker-compose.yml` avec montage du volume DB.

**Sauvegarde automatique de la DB**
`netmap_data.db` n'est pas sauvegardé.
→ Ajouter un script `backup.sh` qui copie le fichier SQLite dans un dossier horodaté (ou vers S3/rclone) via cron.

**Migration vers PostgreSQL**
SQLite est acceptable en usage personnel ; des I/O concurrentes élevées peuvent le saturer.
→ Le driver Fluent PostgreSQL est un remplacement quasi transparent ; envisager si plusieurs instances serveur sont nécessaires.

**Health check enrichi**
`/health` retourne `{ status: "ok" }` mais ne vérifie pas la DB.
→ Ajouter un ping DB : `try await SensorReading.query(on: req.db).count()`, retourner `{ db: "ok" | "error" }`.

### 🟢 Priorité basse

**OpenAPI / Swagger**
Aucune documentation machine-lisible de l'API.
→ Intégrer `vapor-openapi` ou générer un fichier `openapi.yaml` pour faciliter les intégrations tierces.

**Tests automatisés**
Aucun test unitaire ni test d'intégration n'est présent.
→ Ajouter des `XCTest` côté serveur (Vapor `XCTVapor`) couvrant au minimum : setup admin, login, CRUD véhicules, écriture et lecture de relevés.

---

## Tableau récapitulatif des priorités

| # | Amélioration | Domaine | Priorité | Effort estimé |
|---|-------------|---------|----------|---------------|
| 1 | HTTPS via reverse proxy | Sécu | 🔴 | Faible |
| 2 | Détection crevaison lente (serveur) | Analytics | 🔴 | Moyen |
| 3 | Notifications push APNs | iOS | 🔴 | Élevé |
| 4 | Mode hors-ligne (file d'attente iOS) | iOS | 🟡 | Moyen |
| 5 | Rate limiting sur login | Sécu | 🟡 | Faible |
| 6 | Agrégation historique (résolution) | Données | 🟡 | Faible |
| 7 | Alertes visuelles par seuil de pression | iOS | 🟡 | Faible |
| 8 | Conformité Swift 6 (`BLEScanner`) | iOS | 🟡 | Faible |
| 9 | Dockerfile + docker-compose | DevOps | 🟡 | Moyen |
| 10 | Tests automatisés (serveur) | Qualité | 🟢 | Élevé |
| 11 | Widget WidgetKit iOS | iOS | 🟢 | Moyen |
| 12 | Carte historique / replay GPS | Web | 🟢 | Élevé |
