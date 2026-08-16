# Vokabeltrainer V3 – Download-/Update-System

## Was wurde geändert?

### Android APK Installer
`MainActivity.kt` verwendet jetzt `Intent.ACTION_VIEW` mit der
`application/vnd.android.package-archive` MIME-Type und dem
`FileProvider`. Das ist auf Android-Geräten kompatibler als
`ACTION_INSTALL_PACKAGE`.

### APK-Download
Der vorhandene Stream-Download bleibt erhalten:
- Fortschrittsanzeige
- Redirects
- Prüfung des APK-Headers
- Prüfung der Dateigröße
- erst danach Start des Android-Installers

### Benachrichtigungen
Mehrere Gruppen, die auf dieselbe Minute geplant sind, werden jetzt
zu EINER Benachrichtigung zusammengefasst.

Beispiel:

📚 Zeit für Vokabeln (2 Gruppen)

• Englisch: Wie heißt „Haus“ in der Fremdsprache?
• Französisch: Wie heißt „livre“ in der Fremdsprache?

Auch gleichzeitig fällige Streak-Warnungen werden zusammengefasst.

## Update testen

1. Neue APK bauen:
   `flutter build apk --release`
2. APK als GitHub-Release-Asset hochladen.
3. In `update/update.json` die neue Version und den direkten APK-Link
   hinterlegen.
4. In der App `Einstellungen -> Nach Updates suchen`.
5. `Jetzt aktualisieren`.

Die `apkUrl` muss direkt auf die APK zeigen, z.B. auf ein GitHub-Release-Asset,
nicht auf die Release-Webseite.

## Wichtig
Der Browser-Button ist ein manueller Download. Wenn man eine APK-URL im
Browser öffnet, übernimmt Android/Chrome den Download und zeigt diesen im
Download-Bereich an. Das ist unabhängig vom automatischen In-App-Installer.
