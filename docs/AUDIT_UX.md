# Audit UX/UI — LieluFind (usage famille)

Périmètre : code Flutter du dépôt (vues auth, timeline, famille, drawer, settings, tracker, thèmes) + état du serveur (conteneurs `dawarich_app/sidekiq/db/redis` up et healthy).
Non vérifié : la **version exacte** du serveur Dawarich (l'accès ops ne l'expose pas) et le rendu sur appareil. Les points marqués *(à confirmer)* sont déduits du code.

## 1. Contrainte serveur (à garder en tête pour toutes les propositions)

L'app parle à Dawarich (`where.lielu.eu`) via `/api/v1/...` (voir `api_endpoints.dart`). Côté famille, elle n'utilise que `GET /api/v1/families/locations`, qui renvoie `user_id`, `name`/`email`, `email_initial`, position, `timestamp`, `battery`.

- **Dawarich n'a pas de photo de profil, de couleur ni de surnom par utilisateur** dans cette API. Toute personnalisation visible par les *autres* membres demande un stockage en plus (voir §4).
- `compat.json` exige un serveur **≥ 1.3.0** pour les versions de l'app ≥ 0.19. Aucune des propositions ci-dessous ne casse cette compatibilité : tout passe par des endpoints déjà utilisés, ou par un ajout optionnel qui échoue en douceur.

## 2. Constats (par gravité)

### Bloquants pour une vraie famille

1. **Connexion réservée aux techniciens.** Il faut copier une clé API. Le bouton « Use Email / Password » ouvre un dialogue « Coming Soon » : impasse (`connect_steps.dart`). Un parent ou un enfant ne s'en sortira pas seul.
2. **Tout est en anglais** (« Preparing the map… », « Permission Required », « Lock after »…), sans localisation (`intl` présent mais aucun `l10n`).
3. **Des écrans de développeur au premier plan.** Tracker (« Seconds (0 = auto) », « Meters », « Device ID », batch), Points, Stats détaillées sont au même niveau que la carte. L'action la plus utile — *partager ma position / voir où sont les autres* — n'a pas d'écran dédié.
4. **Identité des membres fragile et impersonnelle** (`family_layer.dart`, `family_member_location.dart`) :
   - le nom est deviné depuis l'e-mail (`deborah.defranc@x.fr` → « Deborah ») et l'avatar est **2 lettres** (« De ») ;
   - la **couleur dépend du rang parmi les membres visibles** : si quelqu'un disparaît (hors ligne, erreur réseau), les couleurs des autres **changent**. Une personne n'a donc pas une couleur stable ;
   - aucune photo, aucun surnom, aucun emoji.

### Importants

5. **Les erreurs sont avalées** : en cas d'échec réseau, `familyLocationsProvider` renvoie une liste vide → les proches disparaissent de la carte sans message. Impossible de distinguer « personne n'est là » de « pas de réseau ».
6. **Marqueurs famille non interactifs** : pas de tap pour voir détails/batterie/dernière position, pas de liste des membres, pas de « centrer sur Maman ». La batterie est reçue mais jamais affichée.
7. **Fraîcheur peu lisible** : libellé de 10 px (« Pa · 2 d »), pas de distinction visuelle entre « en direct » et « il y a 2 jours ».
8. **Accessibilité** : textes 10 px, points de trajet de 5×5 px, boutons de carte 36 px de large (< 48 dp recommandé), pas de `Semantics`, boutons de carte blancs codés en dur (mauvais en thème sombre).
9. **Écran de chargement bloquant** : la carte n'apparaît qu'une fois la position GPS connue (« Preparing the map… ») ; une erreur affiche `error.toString()` brut.
10. **Tuiles OSM directes** (`tile.openstreetmap.org`) : sans carte sombre, et usage intensif non conforme à la politique OSM (à terme risque de blocage).

### Cohérence visuelle

11. Titres à tailles hétérogènes (20 dans la timeline, 40 dans les réglages), palette noir/gris sans identité, icône et nom upstream (« Dawarich ») encore visibles dans le README et l'icône.
12. Navigation par tiroir uniquement : peu découvrable pour des utilisateurs non techniques ; une barre d'onglets est plus adaptée à 3–4 destinations.

### Points forts à conserver

- Verrouillage biométrique avec délai configurable.
- Thème clair/sombre/système.
- Vérification de compatibilité serveur et mise à jour in-app.
- Connexion simplifiée (hôte pré-rempli, plus que la clé API).

## 3. Propositions

### A. Parcours « première utilisation en 1 minute » (priorité 1)
- **QR code / lien d'invitation par personne** généré par l'admin (David) : l'app contient déjà `auth_qr_payload` et le scan ; il suffit que le QR embarque l'hôte + la clé du membre. Le membre scanne, l'app demande ses permissions, c'est fini.
- Supprimer le bouton « Email / Mot de passe » tant qu'il n'est pas implémenté.
- Onboarding des permissions en 3 écrans courts, en français, avec une phrase par permission (« pour que la famille voie où tu es »).

### B. Écran d'accueil « Famille » (priorité 1)
- Carte plein écran + **bandeau horizontal d'avatars** (style liste d'amis) : tap = la carte se centre sur la personne ; sous chaque avatar : « il y a 3 min », batterie.
- **Un interrupteur clair « Je partage ma position »** avec état visible en permanence (point vert/gris dans la barre).
- Fiche membre (bottom sheet) : nom, dernière position, adresse approximative *(à confirmer : géocodage possible côté serveur)*, batterie, bouton « Itinéraire » (ouvre l'app de cartes).
- États explicites : « Hors ligne — dernière mise à jour il y a 2 h » au lieu de la disparition silencieuse.

### C. Navigation (priorité 2)
- Barre d'onglets : **Famille · Mon historique · Réglages**. Tracker, Points, Batch et Stats détaillées passent dans « Avancé » (masqué par défaut).
- Un seul style de titre, boutons de carte ≥ 48 dp, thèmes clair/sombre cohérents (couleurs issues du `ColorScheme`, pas de `Colors.white` en dur).

### D. Langue et ton (priorité 1, peu coûteux)
- Mettre en place `flutter_localizations` + ARB : **français par défaut**, anglais en secours. Messages d'erreur humains (« Impossible de joindre le serveur, réessaie » plutôt qu'une exception).

### E. Accessibilité (priorité 2)
- Texte ≥ 12 sp pour les étiquettes, respect de l'échelle de police système, `Semantics` sur les marqueurs et boutons, contraste ≥ 4.5:1.
- Réduire le nombre de marqueurs de trajet (afficher seulement le polyline + début/fin) : lisibilité et performance.

## 4. Personnalisation par personne (nom, photo, couleur) — options compatibles serveur

| Option | Ce que chacun peut faire | Visible par les autres ? | Changement serveur | Effort |
|---|---|---|---|---|
| **1. Local seulement** | Choisir son avatar/couleur dans *Réglages → Mon profil* (photo prise/galerie, recadrée, stockée dans l'app) | Non, seulement sur son téléphone | Aucun | Faible |
| **2. Annuaire famille** (fichier JSON versionné ou table, `user_id → prénom, emoji, couleur, URL photo`), maintenu par l'admin et téléchargé par l'app | L'admin règle pour tous ; chacun voit les bons prénoms/photos | Oui | Un fichier statique à héberger (ex. sur le VPS) | Faible–moyen |
| **3. Profil self-service via n8n** (déjà présent sur `auto.lielu.eu`) : l'app envoie son prénom/couleur/photo à un webhook, qui les stocke ; les autres les lisent | Chacun modifie son profil depuis l'app | Oui | Nouveaux webhooks n8n (authentifiés par la clé API) ; le proxy n'autorise aujourd'hui que `/webhook/trusti-alerte`, il faudra autoriser les nouveaux chemins | Moyen |
| **4. Contribution amont à Dawarich** (champ avatar/surnom) | Idem option 3 | Oui | Dépend du projet upstream, hors de notre contrôle | Élevé |

**Recommandation : 1 + 2 maintenant, 3 ensuite.** On obtient tout de suite des prénoms et couleurs **stables et corrects** pour tous, sans toucher à Dawarich, puis chacun gère sa photo et son profil seul. Le repli est toujours le comportement actuel (initiales), donc aucune régression si l'annuaire est indisponible.

Détails de conception :
- Couleur **dérivée de `user_id`** (ou choisie dans le profil), jamais du rang → plus de changement de couleur.
- Photo ronde 96×96 compressée avant envoi (< 50 Ko), cache disque, repli sur initiale colorée.
- Écran *Mon profil* : prénom affiché, photo, couleur, emoji, avec aperçu du marqueur tel que les autres le voient.
- Confidentialité : choix « Partager avec toute la famille / mettre en pause 1 h / aujourd'hui / jusqu'à nouvel ordre », et option « position approximative ».

## 5. Plan proposé

| Lot | Contenu | Effort |
|---|---|---|
| 1 | Francisation + messages d'erreur + suppression de l'impasse e-mail | 1–2 j |
| 2 | Marqueurs famille : couleur stable, prénom propre, batterie, fraîcheur lisible, états d'erreur | 1–2 j |
| 3 | Bandeau d'avatars + fiche membre + interrupteur de partage | 3–4 j |
| 4 | Navigation en onglets + « Avancé » | 2 j |
| 5 | Mon profil local + annuaire famille (options 1+2) | 3 j |
| 6 | Invitation par QR | 2 j |
| 7 | Profil self-service n8n (option 3) | 3–5 j |

Avant le lot 5/7, vérifier sur le serveur : version de Dawarich et contenu réel de `/api/v1/families/locations` (champs `name`, `email_initial`).
