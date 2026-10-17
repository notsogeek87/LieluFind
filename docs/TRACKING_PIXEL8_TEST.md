# Protocole de test du tracking en arrière-plan (Pixel 8)

À exécuter sur le téléphone concerné avec l'APK de la release `main` la plus récente.
Aucun point de ce protocole ne doit être considéré comme validé sans test réel sur l'appareil.

## 0. Préparation
1. Installer l'APK par-dessus la version existante (ne pas désinstaller).
2. Ouvrir LieluFind une fois : cela relance le service si besoin (journal : « Relance à l'ouverture… »).
3. Réglages Android → Applications → LieluFind → Autorisations → Position : **Autoriser tout le temps** et **Utiliser la position exacte**.
4. Réglages Android → Applications → LieluFind → Batterie : **Sans restriction** (ou « Non optimisée »).
5. Vérifier que la notification du service est visible (elle peut être réduite, mais ne doit pas être bloquée dans les réglages de notifications).
6. Dans LieluFind, activer le tracking si ce n'est pas déjà le cas.

## 1. Vérification immédiate
- Réglages LieluFind → **Journal du tracking** : on doit voir « Service de fond démarré », « Réglage tracking auto = true », « Tracking démarré ».
- Sur la carte familiale d'un autre téléphone : la position de Sylvie doit passer à « il y a moins d'1 min ».

## 2. Écran éteint (test principal)
1. Verrouiller le téléphone, le laisser **immobile** 30 min, puis le déplacer (marche) 10 min, puis le laisser à nouveau immobile 1 h.
2. Regarder la carte familiale : immobile, un point toutes les ≤ 5 min ; en marchant, un point toutes les ~10 s.
3. Laisser tourner plusieurs heures (idéalement une nuit complète) puis relire le journal.

## 3. Pannes provoquées (une à la fois, journal relu après chacune)
| Test | Action | Résultat attendu |
|---|---|---|
| Perte de réseau | Mode avion 10 min, puis retour | Points conservés localement, journal « Envoi des points échoué (conservés localement) », puis envoi automatique au retour du réseau |
| GPS coupé | Désactiver la localisation 3 min, la réactiver | Journal « Suivi bloqué (localisation du téléphone désactivée) » puis « Blocage levé » et « relance #n » ; le bouton reste activé |
| Redémarrage | Redémarrer le téléphone, ne PAS ouvrir l'app | Le service redémarre seul (récepteur de démarrage du plugin) ; les positions reprennent. Sinon, noter l'heure et ouvrir l'app : le journal doit indiquer la relance |
| Mise à jour | Réinstaller un APK par-dessus | Même attendu que pour le redémarrage |
| Permission | Passer la position sur « Seulement pendant l'utilisation », attendre 2 min, remettre « Tout le temps » | Journal « permission … absente » puis reprise ; le bouton reste activé |

## 4. Lecture du journal
Réglages → Journal du tracking → Copier. Lignes à chercher :
- `ARRÊT du service : …` : raison d'un arrêt volontaire du service.
- `Panne détectée : <cause> → relance #n` : le superviseur a relancé le suivi (causes : `streamDone`, `streamError`, `timerSilent`, `noPoint`, `neverStarted`).
- `Suivi bloqué (…)` / `Blocage levé` : permission, GPS.
- `Service présent mais sans réponse` : isolate de fond muet.
- `Point enregistré` : au plus une ligne toutes les 10 min.
- Absence totale de lignes pendant des heures alors que l'app est supposée tourner : le processus a été tué par Android. Noter l'heure et le modèle de notification restant.

## 5. Ce qu'il faut me renvoyer
Le journal complet, l'heure du dernier point visible sur la carte, et pour chaque test ci-dessus : réussi / échoué.
