# Vokabeltrainer V3 – robustes Android-Update-System

## Was neu ist

- APK wird als Stream heruntergeladen statt komplett in den RAM geladen.
- Download-Fortschritt wird in der App angezeigt.
- GitHub-Redirects werden unterstützt.
- Die App prüft, ob die heruntergeladene Datei tatsächlich wie eine APK aussieht.
- Unvollständige Downloads werden erkannt und gelöscht.
- Danach wird der normale Android-Paketinstaller geöffnet.
- Der manuelle APK-Link bleibt als Fallback vorhanden.

## GitHub `update/update.json`

Beispiel:

```json
{
  "version": "2.0.0",
  "versionCode": 5,
  "notes": "Neue Funktionen und Fehlerbehebungen.",
  "apkUrl": "https://github.com/DanielAtGermany/vokabeltrainer/releases/download/v2.0.0/vokabeltrainer.apk",
  "releaseUrl": "https://github.com/DanielAtGermany/vokabeltrainer/releases/tag/v2.0.0",
  "files": []
}
```

Die `apkUrl` muss direkt auf die APK zeigen. Für GitHub Releases ist das normalerweise:

`/releases/download/<TAG>/<DATEINAME>.apk`

Nicht die Release-Seite (`/releases/tag/...`).

## Neue Version veröffentlichen

1. In `pubspec.yaml` Version und Buildnummer erhöhen, z. B.:
   `version: 1.2.0+4`
2. In `lib/main.dart` `appVersion` und `appVersionCode` entsprechend erhöhen.
3. `flutter clean`
4. `flutter pub get`
5. `flutter build apk --release`
6. APK als Release-Asset auf GitHub hochladen.
7. `update/update.json` auf dieselbe Version, Buildnummer und APK-URL setzen.
8. `git add .`
9. `git commit -m "Release 1.2.0"`
10. `git push`

## Wichtig

Für öffentliche Updates müssen alle APKs mit demselben privaten Release-Keystore signiert sein. Der Keystore darf niemals auf GitHub hochgeladen werden.

Die automatische APK-Installation funktioniert nur unter Android. Auf Web/iOS kann der hinterlegte APK-Link weiterhin extern geöffnet werden.
