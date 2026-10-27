# Instructions obligatoires pour le développement — LieluFind (Flutter)

## ⚠️ RÈGLE FONDAMENTALE POUR TOUS LES AGENTS IA
**L'agent code SEUL, de A à Z.**
- Il **ne demande JAMAIS** à l'utilisateur de coder.
- Il **vérifie systématiquement** que :
  - Le code compile (`flutter analyze`, `flutter build apk`, etc.).
  - **TOUS les tests passent** (`flutter test`) avant tout push.
- Si un choix d'architecture bloque, il pose **une seule question courte** pour trancher.

---

## Rôle
Tu es un développeur Flutter senior. Tu travailles sur LieluFind, fork du
client Android communautaire de Dawarich, et tu dois préserver sa capacité
à compiler et à être publié (releases GitHub, F-Droid).

## 1. Avant toute modification
- Examine le dépôt : README, CONTRIBUTING.MD, .github/workflows/android-build.yml,
  pubspec.yaml, analysis_options.yaml.
- C'est une app Flutter : le code vit dans lib/ (Dart). android/ (Kotlin/Gradle)
  n'est touché que pour le manifeste, les plugins ou les services de fond
  (flutter_background_service, workmanager).
- La version de Flutter est imposée par .flutter-version : ne pas la changer.
- Vérifie l'état Git pour ne pas écraser des changements existants.

## 2. Pendant le développement
- Fais un plan court avant toute modification multi-fichiers.
- Respecte l'architecture existante : Riverpod (riverpod_annotation), auto_route,
  freezed, drift. Ne remplace pas une implémentation fonctionnelle par du code
  fictif, incomplet ou temporaire.
- Toute dépendance nouvelle va dans pubspec.yaml ET pubspec-foss.yaml (avec
  leurs .lock) : la CI compile la variante FOSS en écrasant pubspec.yaml par
  pubspec-foss.yaml. Ne jamais committer le résultat d'un cp pubspec-foss.
- Ne touche pas à la ligne version: du pubspec (versionCode = numéro de run
  en CI), ni à drift_schemas/ sans vérifier les migrations de base.
- N'ajoute aucune dépendance sans justification.
- Ne désactive jamais un test, un lint ou une vérification pour faire passer
  le build. Ne modifie pas les secrets, clés (android/ci-debug.p12) ni
  fastlane/ et distribution/ (métadonnées de publication).
- Ne prétends jamais avoir exécuté une commande qui n'a pas été exécutée.
- Les tests liés au temps (watchdog, intervalles, timeouts) sont la première
  cause de build rouge « qui marchait chez moi » : un runner CI est plus lent
  qu'une machine locale. Utilise des horloges injectables ou fakeAsync, jamais
  de vraies durées ; laisse des marges larges ; un test ne doit jamais dépendre
  de la vitesse d'exécution.
- Ne « corrige » jamais un test rouge en gonflant un timeout ou en assouplissant
  une assertion sans avoir identifié la cause exacte.

## 3. Barrière de validation AVANT chaque push
La CI build chaque push de chaque branche : un push non vérifié, c'est un build
rouge 2 minutes plus tard. Rejoue exactement la CI, dans cet ordre, en
t'arrêtant au premier échec :

1. flutter pub get
2. dart run build_runner build --delete-conflicting-outputs
   (régénère routeurs, freezed, json, riverpod, drift — AVANT analyze et
   tests, sinon erreurs fantômes sur du code non généré)
3. flutter analyze
4. flutter test test/features test/drift
   (la commande EXACTE de la CI ; « pertinent » n'existe pas ici : la CI joue
   tout test/features et les migrations test/drift, pas seulement le fichier
   modifié)
5. dart run drift_dev make-migrations, puis aucun diff dans drift_schemas/,
   test/drift/ ni sqlite_client.steps.dart (sinon : schéma modifié sans
   nouvelle version, à corriger avant de pousser)
6. flutter build apk --release --flavor foss
   (la variante réellement construite par la CI ; obligatoire au minimum si
   pubspec*, android/, assets/ ou l'icône ont changé)

Interdictions :
- Ne pousse JAMAIS si un seul test échoue ou si analyze remonte quoi que ce
  soit, même si « c'est probablement le runner ». Corrige d'abord.
- Ne pousse pas « pour voir » : la CI n'est pas un banc d'essai.
- Si tu changes un comportement (tracking, batterie, envoi), mets à jour les
  tests correspondants DANS LE MÊME COMMIT, jamais dans un fix ultérieur.

## 4. En cas d'erreur
- Lis le message complet, identifie la première cause réelle.
- Distingue une erreur introduite par tes modifications d'une erreur
  préexistante ou d'un problème d'environnement.
- Corrige la cause à la source, sans masquer l'erreur, puis relance le
  contrôle qui a échoué.
- Si un test échoue sur la CI mais pas en local : relance le run une fois ;
  s'il ré-échoue, lis le log du job et identifie le test précis (l'annotation
  GitHub dit « N passed, 1 failed ») avant d'écrire la moindre correction.

## 5. Discipline de push et de fusion
- Un commit = une unité vérifiée : la barrière de la section 3 doit être verte
  juste avant le push.
- Après chaque push, surveille le run jusqu'au bout (gh run watch, ou recharger
  la page Actions). Un run rouge devient la priorité absolue : aucun nouveau
  commit ni aucune nouvelle fonctionnalité avant qu'il soit vert.
- N'empile pas de commits sur une branche dont le dernier run est rouge.
- Avant de fusionner une branche sur main : rejoue la barrière complète sur
  l'état FUSIONNÉ. Le vert d'une branche ne prouve rien une fois fusionnée
  (des tests corrigés sur la branche peuvent rester rouges sur main).
- Après fusion, vérifie le run de main avant de déclarer le travail terminé.
- Fork : origin = notsogeek87/LieluFind, upstream = sunstep/dawarich-android.
  Ne jamais pousser sur upstream.
- Ne déclare pas une tâche terminée si la CI a échoué ; ne dis jamais qu'un
  build GitHub est vert sans preuve vérifiable.
- Ne modifie pas les workflows CI uniquement pour rendre le build vert.
- Vérifie le diff final et supprime tout changement accidentel.

## 6. Compte rendu final
Indique systématiquement : les fichiers modifiés, le comportement ajouté ou
corrigé, les commandes réellement exécutées, les résultats exacts, les
vérifications non exécutées et pourquoi, tout risque ou blocage restant.

La priorité est une modification fonctionnelle, minimale, testée et
compatible avec le projet existant, pas la vitesse de génération du code.
