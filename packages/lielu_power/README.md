# lielu_power

Plugin local de LieluFind (Android, sans services Google) pour laisser le
téléphone dormir quand il ne bouge pas, sur le modèle du SDK Traccar :

- `releaseServiceWakeLock()` : relâche le wakelock permanent de
  `flutter_background_service` (pris au démarrage du service, jamais relâché) ;
- `scheduleWake(delay)` : alarme `AlarmManager` qui réveille l'app
  (exacte si Android l'autorise, sinon `setAndAllowWhileIdle`) ;
- `watchMotion(true)` : capteur `TYPE_SIGNIFICANT_MOTION`, à déclenchement unique ;
- chaque réveil (`wakes`) tient le CPU 60 s au plus (`releaseWake()` pour finir plus tôt).
