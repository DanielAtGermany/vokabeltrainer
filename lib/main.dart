// lib/main.dart

import 'package:flutter/material.dart';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'vokabel.dart';

// Benachrichtigungen und lokaler Speicher
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  await _setLocalTimeZone();
  await AppUpdateService.initialisieren();
  runApp(const VokabelTrainerApp());
}

Future<void> _setLocalTimeZone() async {
  try {
    final zone = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(zone.identifier));
  } catch (e) {
    debugPrint('Zeitzone konnte nicht gesetzt werden: $e');
  }
}

const String _notificationChannelId = 'vokabel_channel_v5';

Future<void> _initNotifications() async {
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const darwin = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const settings = InitializationSettings(android: android, iOS: darwin);
  await flutterLocalNotificationsPlugin.initialize(settings: settings);

  const channel = AndroidNotificationChannel(
    _notificationChannelId,
    'Vokabel Erinnerungen',
    description: 'Erinnerungen zum Vokabeln lernen',
    importance: Importance.max,
    playSound: true,
  );

  final androidPlugin = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  if (androidPlugin != null) {
    await androidPlugin.createNotificationChannel(channel);
    await androidPlugin.requestNotificationsPermission();
    try {
      await androidPlugin.requestExactAlarmsPermission();
    } catch (e) {
      debugPrint('Exact-Alarm-Permission nicht verfügbar: $e');
    }
  }

  final iosPlugin = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
  if (iosPlugin != null) {
    await iosPlugin.requestPermissions(alert: true, badge: true, sound: true);
  }
}

Vokabel _waehleErinnerungsVokabel(List<Vokabel> vokabeln, Set<String> verwendet) {
  final freie = vokabeln.where((v) => !verwendet.contains(_vokabelKey(v))).toList();
  final pool = freie.isEmpty ? List<Vokabel>.from(vokabeln) : freie;
  final weights = pool.map((v) => 0.35 + v.lernPrioritaet * v.lernPrioritaet * 3.2).toList();
  final sum = weights.fold<double>(0, (a, b) => a + b);
  var r = Random().nextDouble() * sum;
  for (int i = 0; i < pool.length; i++) {
    r -= weights[i];
    if (r <= 0) return pool[i];
  }
  return pool.last;
}

String _vokabelKey(Vokabel v) => '${v.fremdsprache.toLowerCase()}|${v.deutsch.toLowerCase()}';

Future<void> _scheduleNotification({
  required int id,
  required String title,
  required String body,
  required tz.TZDateTime date,
}) async {
  const details = NotificationDetails(
    android: AndroidNotificationDetails(
      _notificationChannelId,
      'Vokabel Erinnerungen',
      channelDescription: 'Erinnerungen zum Vokabeln lernen',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    ),
  );

  try {
    await flutterLocalNotificationsPlugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: date,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  } catch (e) {
    debugPrint('Exact Alarm fehlgeschlagen: $e');
    try {
      await flutterLocalNotificationsPlugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: date,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (e2) {
      debugPrint('Benachrichtigung konnte nicht geplant werden: $e2');
    }
  }
}

Future<void> planeKategorieErinnerungen(List<VokabelGruppe> gruppen) async {
  await flutterLocalNotificationsPlugin.cancelAll();
  if (gruppen.isEmpty) return;

  final now = tz.TZDateTime.now(tz.local);
  int id = 1000;

  for (final gruppe in gruppen) {
    if (gruppe.vokabeln.isEmpty || gruppe.benachrichtigungenProTag <= 0) continue;

    final start = gruppe.startStunde.clamp(0, 23).toInt();
    final end = gruppe.endStunde.clamp(start + 1, 24).toInt();
    final count = gruppe.benachrichtigungenProTag.clamp(1, 15).toInt();
    final interval = count == 1 ? 0.0 : (end - start) / (count - 1);

    // Eine Woche im Voraus. So ändern sich die Vokabeln der Erinnerungen,
    // statt jeden Tag denselben Text zu zeigen.
    for (int day = 0; day < 7; day++) {
      final used = <String>{};
      int scheduledToday = 0;
      final remainingToday = maxInt(0, count - gruppe.sessionsHeute);
      for (int i = 0; i < count; i++) {
        final hour = (start + interval * i).round().clamp(0, 23).toInt();
        final date = tz.TZDateTime(
          tz.local,
          now.year,
          now.month,
          now.day,
          hour,
        ).add(Duration(days: day));
        if (!date.isAfter(now)) continue;

        // Nach bereits erledigten Sessions heute werden nur noch so viele
        // Erinnerungen geplant, wie für das Tagesziel tatsächlich fehlen.
        if (day == 0 && scheduledToday >= remainingToday) continue;

        final word = _waehleErinnerungsVokabel(gruppe.vokabeln, used);
        used.add(_vokabelKey(word));
        scheduledToday++;
        await _scheduleNotification(
          id: id++,
          title: '${gruppe.name}: Zeit für eine kurze Session!',
          body: 'Wie heißt „${word.deutsch}“ in der Fremdsprache?',
          date: date,
        );
      }
    }

    // Warnung kurz vor Ende des Lernfensters. Sie wird nach jeder
    // abgeschlossenen Session neu geplant und dadurch entfernt, sobald das
    // Tagesziel erreicht wurde.
    gruppe.synchronisiereStreak(now);
    if (gruppe.streak > 0 && !gruppe.tageszielErreicht) {
      final warningHour = gruppe.endStunde.clamp(0, 23).toInt();
      final warningDate = tz.TZDateTime(
        tz.local,
        now.year,
        now.month,
        now.day,
        warningHour,
        55,
      );
      if (warningDate.isAfter(now)) {
        await _scheduleNotification(
          id: id++,
          title: '🔥 ${gruppe.name}: Deine Streak läuft ab!',
          body: 'Noch ${gruppe.fehlendeSessionsHeute} Session${gruppe.fehlendeSessionsHeute == 1 ? '' : 's'} bis ${gruppe.streak} Tage Streak.',
          date: warningDate,
        );
      }
    }
  }
}

String holeNaechsteErinnerungText(VokabelGruppe gruppe) {
  if (gruppe.vokabeln.isEmpty || gruppe.benachrichtigungenProTag <= 0)
    return 'Keine Erinnerungen aktiv';

  final nun = tz.TZDateTime.now(tz.local);
  int stundenBereich = gruppe.endStunde - gruppe.startStunde;
  if (stundenBereich <= 0) stundenBereich = 1;

  double intervall =
      stundenBereich /
      (gruppe.benachrichtigungenProTag > 1
          ? (gruppe.benachrichtigungenProTag - 1)
          : 1);
  tz.TZDateTime? naechsteZeit;

  for (int tag = 0; tag <= 1; tag++) {
    for (int i = 0; i < gruppe.benachrichtigungenProTag; i++) {
      int berechneteStunde = gruppe.startStunde + (i * intervall).round();
      if (berechneteStunde > gruppe.endStunde)
        berechneteStunde = gruppe.endStunde;

      var pruefZeit = tz.TZDateTime(
        tz.local,
        nun.year,
        nun.month,
        nun.day,
        berechneteStunde,
        0,
      );
      if (tag == 1) pruefZeit = pruefZeit.add(const Duration(days: 1));

      if (pruefZeit.isAfter(nun)) {
        naechsteZeit = pruefZeit;
        break;
      }
    }
    if (naechsteZeit != null) break;
  }

  if (naechsteZeit == null) return 'Keine Termine';
  final unterschied = naechsteZeit.difference(nun);

  if (unterschied.inMinutes < 60)
    return 'Nächste: in ${unterschied.inMinutes} Min.';
  if (naechsteZeit.day == nun.day)
    return 'Nächste: heute um ${naechsteZeit.hour}:00 Uhr';
  return 'Nächste: morgen um ${naechsteZeit.hour}:00 Uhr';
}


// --- GITHUB-VOKABELBIBLIOTHEK ---

/// Die App kann entweder eine normale GitHub-Repository-URL oder weiterhin
/// eine direkte library.json-URL verwenden. Für die neue Ordneransicht ist
/// eine Repository-URL am praktischsten, z.B.:
/// https://github.com/DEIN-NAME/vokabel-library
const String githubBibliothekIndexUrl = 'https://github.com/DanielAtGermany/vokabel-library';
const String _githubBibliothekUrlKey = 'github_bibliothek_url_v1';
const String _darkModeKey = 'dark_mode_v1';

String _normalisiereGitHubRawUrl(String url) {
  var value = url.trim();
  if (value.isEmpty) return '';
  if (value.startsWith('git@github.com:')) {
    value = value.replaceFirst('git@github.com:', 'https://github.com/');
    if (value.endsWith('.git')) value = value.substring(0, value.length - 4);
  }

  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme) return value;
  if (uri.host == 'raw.githubusercontent.com') return value;

  if (uri.host == 'github.com' || uri.host == 'www.github.com') {
    final parts = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    if (parts.length >= 5 && parts[2] == 'blob') {
      final owner = parts[0];
      final repo = parts[1];
      final branch = parts[3];
      final filePath = parts.sublist(4).join('/');
      return 'https://raw.githubusercontent.com/$owner/$repo/$branch/$filePath';
    }
    if (parts.length >= 4 && parts[2] == 'raw') {
      final owner = parts[0];
      final repo = parts[1];
      final branch = parts[3];
      final filePath = parts.length > 4 ? parts.sublist(4).join('/') : 'library.json';
      return 'https://raw.githubusercontent.com/$owner/$repo/$branch/$filePath';
    }
  }
  return value;
}

Future<String> _holeGitHubBibliothekUrl() async {
  final prefs = await SharedPreferences.getInstance();
  final gespeicherte = prefs.getString(_githubBibliothekUrlKey)?.trim() ?? '';
  if (gespeicherte.isNotEmpty) return gespeicherte;
  return githubBibliothekIndexUrl.trim();
}

class GitHubRepoInfo {
  final String owner;
  final String repo;
  final String branch;
  final String startPath;

  const GitHubRepoInfo({
    required this.owner,
    required this.repo,
    required this.branch,
    this.startPath = '',
  });

  String get apiBase => 'https://api.github.com/repos/$owner/$repo/contents';

  String apiUrl([String path = '']) {
    final clean = path.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    final encodedPath = clean.isEmpty ? '' : Uri.encodeComponent(clean).replaceAll('%2F', '/');
    final uri = Uri.parse('$apiBase/${encodedPath.isEmpty ? '' : encodedPath}');
    return uri.replace(queryParameters: {'ref': branch}).toString();
  }

  static GitHubRepoInfo? tryParse(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.host != 'github.com') return null;
    final parts = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) return null;

    final owner = parts[0];
    final repo = parts[1].replaceFirst(RegExp(r'\.git$'), '');
    var branch = 'main';
    var path = '';

    if (parts.length >= 4 && (parts[2] == 'tree' || parts[2] == 'blob')) {
      branch = parts[3];
      if (parts.length > 4) path = parts.sublist(4).join('/');
    }

    return GitHubRepoInfo(
      owner: owner,
      repo: repo,
      branch: branch,
      startPath: path,
    );
  }
}

class GitHubLibraryEntry {
  final String name;
  final String path;
  final String type;
  final String? downloadUrl;

  const GitHubLibraryEntry({
    required this.name,
    required this.path,
    required this.type,
    this.downloadUrl,
  });

  bool get isFolder => type == 'dir';
  bool get isJsonFile => type == 'file' && name.toLowerCase().endsWith('.json');

  factory GitHubLibraryEntry.fromJson(Map<String, dynamic> json) {
    return GitHubLibraryEntry(
      name: '${json['name'] ?? 'Unbenannt'}',
      path: '${json['path'] ?? ''}',
      type: '${json['type'] ?? ''}',
      downloadUrl: json['download_url']?.toString(),
    );
  }
}

Future<List<GitHubLibraryEntry>> _holeGitHubOrdner(GitHubRepoInfo repo, String path) async {
  final uri = Uri.parse(repo.apiUrl(path));
  final response = await http.get(uri, headers: const {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'Vokabeltrainer',
  }).timeout(const Duration(seconds: 15));

  if (response.statusCode != 200) {
    final angezeigterPfad = path.isEmpty ? '/' : '/$path';
    if (response.statusCode == 404) {
      throw Exception(
        'GitHub-Ordner nicht gefunden (HTTP 404): $angezeigterPfad\n'
        'Prüfe Repository, Branch und ob der Ordner genau so geschrieben ist.',
      );
    }
    throw Exception(
      'GitHub antwortete mit HTTP ${response.statusCode} für $angezeigterPfad.',
    );
  }

  dynamic decoded;
  try {
    decoded = jsonDecode(utf8.decode(response.bodyBytes));
  } on FormatException catch (e) {
    throw Exception('GitHub lieferte kein gültiges JSON (${e.message}).');
  }

  if (decoded is! List) {
    throw Exception('Der angegebene GitHub-Pfad ist keine Ordneransicht.');
  }

  return decoded
      .whereType<Map>()
      .map((e) => GitHubLibraryEntry.fromJson(Map<String, dynamic>.from(e)))
      .where((e) => e.isFolder || e.isJsonFile)
      .toList()
    ..sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
}

Future<List<Vokabel>> _ladeGitHubVokabelDatei(String url) async {
  final normalisierteUrl = _normalisiereGitHubRawUrl(url);
  final uri = Uri.tryParse(normalisierteUrl);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw Exception('Die Vokabeldatei-URL ist ungültig.');
  }

  final response = await http.get(uri, headers: const {
    'Accept': 'application/json',
    'User-Agent': 'Vokabeltrainer',
  }).timeout(const Duration(seconds: 15));

  if (response.statusCode != 200) {
    throw Exception('GitHub antwortete mit HTTP ${response.statusCode}.');
  }

  final text = utf8.decode(response.bodyBytes).trim();
  if (text.startsWith('<!DOCTYPE') || text.startsWith('<html') || text.startsWith('<HTML')) {
    throw Exception('Die Vokabeldatei liefert HTML statt JSON.');
  }

  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw Exception('Die Vokabeldatei ist kein gültiges JSON (${e.message}).');
  }

  final list = decoded is List ? decoded : (decoded is Map ? decoded['vokabeln'] : null);
  if (list is! List) {
    throw Exception('Die Vokabeldatei enthält kein "vokabeln"-Array.');
  }

  return list
      .whereType<Map>()
      .map((item) => Vokabel.fromJson(Map<String, dynamic>.from(item)))
      .where((v) => v.deutsch.trim().isNotEmpty && v.fremdsprache.trim().isNotEmpty)
      .toList();
}

class VokabelBibliothekScreen extends StatefulWidget {
  final List<VokabelGruppe> gruppen;
  final VokabelGruppe? zielGruppe;

  const VokabelBibliothekScreen({
    super.key,
    required this.gruppen,
    this.zielGruppe,
  });

  @override
  State<VokabelBibliothekScreen> createState() => _VokabelBibliothekScreenState();
}

class _VokabelBibliothekScreenState extends State<VokabelBibliothekScreen> {
  GitHubRepoInfo? _repo;
  List<GitHubLibraryEntry> _entries = [];
  final List<String> _pathStack = [];
  VokabelGruppe? _zielGruppe;
  bool _laden = true;
  String? _fehler;
  String _titel = 'Bibliothek';

  @override
  void initState() {
    super.initState();
    _zielGruppe = widget.zielGruppe ?? (widget.gruppen.isNotEmpty ? widget.gruppen.first : null);
    _ladeStart();
  }

  Future<void> _ladeStart() async {
    setState(() {
      _laden = true;
      _fehler = null;
      _pathStack.clear();
    });
    try {
      final url = await _holeGitHubBibliothekUrl();
      if (url.isEmpty) {
        throw Exception('Noch keine GitHub-Bibliothek eingerichtet. Öffne ⚙️ Einstellungen und hinterlege die Repository-URL.');
      }

      final repo = GitHubRepoInfo.tryParse(url);
      if (repo != null) {
        _repo = repo;
        if (repo.startPath.isNotEmpty) _pathStack.add(repo.startPath);
        await _ladeOrdner();
        return;
      }

      // Kompatibilität mit der alten library.json bleibt erhalten.
      final normalisiert = _normalisiereGitHubRawUrl(url);
      final response = await http.get(Uri.parse(normalisiert), headers: const {'Accept': 'application/json'}).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw Exception('GitHub antwortete mit HTTP ${response.statusCode}.');
      final text = utf8.decode(response.bodyBytes).trim();
      if (text.startsWith('<!DOCTYPE') || text.startsWith('<html') || text.startsWith('<HTML')) {
        throw Exception('GitHub hat HTML statt JSON geliefert. Nutze am besten direkt die Repository-URL.');
      }
      final decoded = jsonDecode(text);
      final rawList = decoded is List ? decoded : (decoded is Map ? (decoded['sammlungen'] ?? decoded['sets']) : null);
      if (rawList is! List) throw Exception('Die library.json muss ein "sammlungen"-Array enthalten.');
      final legacy = rawList.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
      _repo = null;
      if (mounted) {
        setState(() {
          _entries = legacy.map((e) => GitHubLibraryEntry(
            name: '${e['name'] ?? e['id'] ?? 'Sammlung'}',
            path: '${e['url'] ?? ''}',
            type: 'legacy',
            downloadUrl: e['url']?.toString(),
          )).toList();
          _titel = 'Bibliothek';
          _laden = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _laden = false;
        _fehler = 'Bibliothek konnte nicht geladen werden:\n$e';
      });
    }
  }

  Future<void> _ladeOrdner() async {
    if (_repo == null) return;
    setState(() {
      _laden = true;
      _fehler = null;
    });
    try {
      // Jeder Eintrag von der GitHub-API enthält bereits den vollständigen
      // Pfad (z. B. "Englisch/Access 5"). Deshalb darf hier nicht
      // _pathStack.join('/') verwendet werden, sonst entsteht beim
      // Weiteröffnen fälschlich "Englisch/Englisch/Access 5".
      final path = _pathStack.isEmpty ? '' : _pathStack.last;
      final entries = await _holeGitHubOrdner(_repo!, path);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _titel = path.isEmpty ? 'Bibliothek' : path.split('/').last;
        _laden = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _laden = false;
        _fehler = 'Ordner konnte nicht geladen werden:\n$e';
      });
    }
  }

  Future<void> _oeffneEntry(GitHubLibraryEntry entry) async {
    if (entry.isFolder && _repo != null) {
      _pathStack.add(entry.path);
      await _ladeOrdner();
      return;
    }

    if (entry.isJsonFile || entry.type == 'legacy') {
      final url = entry.downloadUrl ?? entry.path;
      await _importiereSeite(entry.name, url);
    }
  }

  Future<void> _importiereSeite(String dateiname, String url) async {
    if (widget.gruppen.isEmpty || _zielGruppe == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Erstelle zuerst eine Vokabelgruppe.')));
      return;
    }
    try {
      final vokabeln = await _ladeGitHubVokabelDatei(url);
      if (vokabeln.isEmpty) {
        throw Exception('Diese Seite enthält keine Vokabeln.');
      }
      final ziel = _zielGruppe!;
      final vorhandene = ziel.vokabeln.map(_vokabelKey).toSet();
      final neue = vokabeln.where((v) => !vorhandene.contains(_vokabelKey(v))).toList();
      if (neue.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Alle Vokabeln aus "$dateiname" sind bereits vorhanden.')));
        return;
      }
      ziel.vokabeln.addAll(neue);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${neue.length} Vokabeln aus "$dateiname" importiert.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import fehlgeschlagen: $e'), behavior: SnackBarBehavior.floating));
    }
  }

  void _zurueckOrdner() {
    if (_repo == null || _pathStack.isEmpty) return;
    _pathStack.removeLast();
    _ladeOrdner();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('📚 $_titel'),
        leading: _repo != null && _pathStack.isNotEmpty
            ? IconButton(onPressed: _zurueckOrdner, icon: const Icon(Icons.arrow_back))
            : null,
        actions: [
          IconButton(tooltip: 'Neu laden', onPressed: _laden ? null : _ladeStart, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          if (widget.gruppen.isNotEmpty && widget.zielGruppe == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: DropdownButtonFormField<VokabelGruppe>(
                initialValue: _zielGruppe,
                decoration: const InputDecoration(labelText: 'Vokabeln hinzufügen zu', prefixIcon: Icon(Icons.folder_outlined), border: OutlineInputBorder()),
                items: widget.gruppen.map((g) => DropdownMenuItem(value: g, child: Text(g.name))).toList(),
                onChanged: (g) => setState(() => _zielGruppe = g),
              ),
            ),
          if (_repo != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _pathStack.isEmpty ? 'Sprachen / Bücher / Seiten' : _pathStack.join('  ›  '),
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                ),
              ),
            ),
          Expanded(
            child: _laden
                ? const Center(child: CircularProgressIndicator())
                : _fehler != null
                    ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.error_outline, size: 48), const SizedBox(height: 12), Text(_fehler!, textAlign: TextAlign.center), const SizedBox(height: 16), FilledButton.icon(onPressed: _ladeStart, icon: const Icon(Icons.refresh), label: const Text('Erneut versuchen'))])))
                    : _entries.isEmpty
                        ? const Center(child: Text('Dieser Ordner enthält noch keine Unterordner oder JSON-Seiten.'))
                        : ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: _entries.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final entry = _entries[index];
                              final isFolder = entry.isFolder;
                              final title = entry.name.replaceFirst(RegExp(r'\.json$', caseSensitive: false), '');
                              return Card(
                                child: ListTile(
                                  leading: Icon(isFolder ? Icons.folder_rounded : Icons.menu_book_rounded, color: isFolder ? Colors.amber.shade700 : Colors.indigo),
                                  title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                                  subtitle: Text(isFolder ? 'Buch / Ordner öffnen' : 'Seite mit Vokabeln importieren'),
                                  trailing: Icon(isFolder ? Icons.chevron_right : Icons.download_rounded),
                                  onTap: () => _oeffneEntry(entry),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}



// --- APP-/DATEN-UPDATE ---
const String appVersion = '1.1.0';
const String _updateManifestUrlKey = 'update_manifest_url_v1';
const String _installedVersionKey = 'installed_app_version_v1';
const String _managedUpdateFolder = 'managed_update';

class AppUpdateInfo {
  final String version;
  final String notes;
  final String? releaseUrl;
  final List<Map<String, String>> files;
  const AppUpdateInfo({required this.version, this.notes = '', this.releaseUrl, this.files = const []});
  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    final files = <Map<String, String>>[];
    final rawFiles = json['files'];
    if (rawFiles is List) {
      for (final item in rawFiles) {
        if (item is Map) {
          final path = item['path']?.toString();
          final url = item['url']?.toString();
          if (path != null && path.isNotEmpty && url != null && url.isNotEmpty) files.add({'path': path, 'url': url});
        }
      }
    }
    return AppUpdateInfo(version: '${json['version'] ?? '0.0.0'}', notes: '${json['notes'] ?? ''}', releaseUrl: json['releaseUrl']?.toString(), files: files);
  }
}

int _compareVersion(String a, String b) {
  List<int> parse(String value) => value.split('+').first.split('.').map((part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0).toList();
  final aa = parse(a), bb = parse(b);
  for (int i = 0; i < max(aa.length, bb.length); i++) {
    final av = i < aa.length ? aa[i] : 0;
    final bv = i < bb.length ? bb[i] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  return 0;
}

class AppUpdateService {
  static Future<String> _manifestUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_updateManifestUrlKey)?.trim() ?? '';
  }
  static Future<void> initialisieren() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_installedVersionKey, appVersion);
  }
  static Future<AppUpdateInfo?> pruefe() async {
    final url = await _manifestUrl();
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(_normalisiereGitHubRawUrl(url));
    if (uri == null || !uri.hasScheme) throw Exception('Update-Manifest-URL ist ungültig.');
    final response = await http.get(uri, headers: const {'Accept': 'application/json', 'User-Agent': 'Vokabeltrainer'}).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw Exception('Update-Server antwortete mit HTTP ${response.statusCode}.');
    final text = utf8.decode(response.bodyBytes).trim();
    if (text.startsWith('<!DOCTYPE') || text.startsWith('<html') || text.startsWith('<HTML')) throw Exception('Das Update-Manifest liefert HTML statt JSON.');
    final decoded = jsonDecode(text);
    if (decoded is! Map) throw Exception('Update-Manifest muss ein JSON-Objekt sein.');
    final info = AppUpdateInfo.fromJson(Map<String, dynamic>.from(decoded));
    return _compareVersion(info.version, appVersion) > 0 ? info : null;
  }
  static Future<Directory> _updateDirectory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_managedUpdateFolder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
  static Future<int> ladeDaten(AppUpdateInfo info) async {
    final dir = await _updateDirectory();
    int count = 0;
    for (final file in info.files) {
      final relative = file['path']!;
      final uri = Uri.tryParse(_normalisiereGitHubRawUrl(file['url']!));
      if (uri == null || !uri.hasScheme) continue;
      final response = await http.get(uri, headers: const {'User-Agent': 'Vokabeltrainer'}).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) continue;
      final target = File('${dir.path}/$relative');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(response.bodyBytes, flush: true);
      count++;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('managed_data_version_v1', info.version);
    return count;
  }
  static Future<String> leseManagedDatei(String relativePath) async {
    final dir = await _updateDirectory();
    final file = File('${dir.path}/$relativePath');
    if (!await file.exists()) return '';
    return file.readAsString();
  }
  static Future<void> setManifestUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    if (url.trim().isEmpty) await prefs.remove(_updateManifestUrlKey);
    else await prefs.setString(_updateManifestUrlKey, url.trim());
  }
}

class AppSettingsScreen extends StatefulWidget {
  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  const AppSettingsScreen({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
  });

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  late bool _darkMode;
  late final TextEditingController _githubController;
  late final TextEditingController _updateController;
  bool _speichertUrl = false;
  bool _updateLaedt = false;
  AppUpdateInfo? _updateInfo;
  String? _updateFehler;

  @override
  void initState() {
    super.initState();
    _darkMode = widget.darkMode;
    _githubController = TextEditingController();
    _updateController = TextEditingController();
    _ladeEinstellungen();
  }

  Future<void> _ladeEinstellungen() async {
    final prefs = await SharedPreferences.getInstance();
    final gespeicherteUrl = prefs.getString(_githubBibliothekUrlKey) ?? '';
    final updateUrl = prefs.getString(_updateManifestUrlKey) ?? '';
    if (!mounted) return;
    setState(() { _githubController.text = gespeicherteUrl; _updateController.text = updateUrl; });
  }

  Future<void> _pruefeUpdate() async {
    setState(() { _updateLaedt = true; _updateFehler = null; });
    try {
      final info = await AppUpdateService.pruefe();
      if (!mounted) return;
      setState(() { _updateInfo = info; _updateLaedt = false; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(info == null ? 'Du verwendest bereits die neueste Version.' : 'Neue Version ${info.version} verfügbar.')));
    } catch (e) {
      if (!mounted) return;
      setState(() { _updateLaedt = false; _updateFehler = '$e'; });
    }
  }

  Future<void> _speichereUpdateUrl() async {
    await AppUpdateService.setManifestUrl(_updateController.text);
    if (!mounted) return;
    await _pruefeUpdate();
  }

  Future<void> _installiereDatenupdate() async {
    final info = _updateInfo;
    if (info == null) return;
    setState(() => _updateLaedt = true);
    try {
      final count = await AppUpdateService.ladeDaten(info);
      if (!mounted) return;
      setState(() => _updateLaedt = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$count Datendateien aktualisiert.')));
    } catch (e) {
      if (!mounted) return;
      setState(() { _updateLaedt = false; _updateFehler = '$e'; });
    }
  }

  Future<void> _speichereGitHubUrl() async {
    setState(() => _speichertUrl = true);
    final prefs = await SharedPreferences.getInstance();
    final url = _githubController.text.trim();
    if (url.isEmpty) {
      await prefs.remove(_githubBibliothekUrlKey);
    } else {
      await prefs.setString(_githubBibliothekUrlKey, url);
    }
    if (!mounted) return;
    setState(() => _speichertUrl = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('GitHub-Bibliothek gespeichert.')),
    );
  }

  @override
  void dispose() {
    _githubController.dispose();
    _updateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Darstellung',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: SwitchListTile(
              secondary: Icon(_darkMode ? Icons.dark_mode : Icons.light_mode),
              title: const Text('Dark Mode'),
              subtitle: Text(
                _darkMode ? 'Dunkles Erscheinungsbild aktiviert' : 'Helles Erscheinungsbild aktiviert',
              ),
              value: _darkMode,
              onChanged: (value) async {
                setState(() => _darkMode = value);
                widget.onDarkModeChanged(value);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool(_darkModeKey, value);
              },
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Vokabelbibliothek',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'GitHub library.json',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Du kannst eine GitHub-Datei-URL oder eine Raw-URL eintragen. Beispiel: github.com/Benutzer/Repository/blob/main/library.json',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _githubController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'URL der library.json',
                      hintText: 'https://github.com/.../blob/main/library.json',
                      prefixIcon: Icon(Icons.link),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _speichertUrl ? null : _speichereGitHubUrl,
                      icon: _speichertUrl
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save),
                      label: const Text('Speichern'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Updates',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Installierte App-Version: $appVersion', style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('Die App kann Datenpakete automatisch aus GitHub aktualisieren. Der eigentliche Flutter-Programmcode kann sich auf Android/iOS nicht selbst ersetzen.'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _updateController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'URL von update.json', hintText: 'https://github.com/.../blob/main/update.json', prefixIcon: Icon(Icons.system_update_alt), border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: OutlinedButton.icon(onPressed: _updateLaedt ? null : _speichereUpdateUrl, icon: const Icon(Icons.save), label: const Text('Speichern & prüfen'))),
                    const SizedBox(width: 8),
                    IconButton(onPressed: _updateLaedt ? null : _pruefeUpdate, tooltip: 'Nach Update suchen', icon: _updateLaedt ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh)),
                  ]),
                  if (_updateInfo != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Neue Version ${_updateInfo!.version}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        if (_updateInfo!.notes.isNotEmpty) ...[const SizedBox(height: 4), Text(_updateInfo!.notes)],
                        if (_updateInfo!.files.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          FilledButton.icon(onPressed: _updateLaedt ? null : _installiereDatenupdate, icon: const Icon(Icons.download), label: const Text('Datenupdate installieren')),
                        ],
                      ]),
                    ),
                  ],
                  if (_updateFehler != null) ...[const SizedBox(height: 8), Text(_updateFehler!, style: TextStyle(color: Colors.red))],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Weitere Einstellungen',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Erinnerungen'),
              subtitle: const Text('Die Erinnerungen werden pro Vokabelgruppe festgelegt.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Die Erinnerungen stellst du aktuell in der jeweiligen Gruppe ein.')),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class VokabelTrainerApp extends StatefulWidget {
  const VokabelTrainerApp({super.key});

  @override
  State<VokabelTrainerApp> createState() => _VokabelTrainerAppState();
}

class _VokabelTrainerAppState extends State<VokabelTrainerApp> {
  bool _darkMode = false;
  bool _geladen = false;

  @override
  void initState() {
    super.initState();
    _ladeDarstellung();
    _autonomesDatenupdate();
  }

  Future<void> _ladeDarstellung() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _darkMode = prefs.getBool(_darkModeKey) ?? false;
      _geladen = true;
    });
  }

  Future<void> _autonomesDatenupdate() async {
    try {
      final info = await AppUpdateService.pruefe();
      if (info != null && info.files.isNotEmpty) await AppUpdateService.ladeDaten(info);
    } catch (e) {
      debugPrint('Automatisches Datenupdate fehlgeschlagen: $e');
    }
  }

  Future<void> _setDarkMode(bool value) async {
    setState(() => _darkMode = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkModeKey, value);
  }

  ThemeData _theme(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: brightness == Brightness.light
          ? const Color(0xFFF5F7FB)
          : const Color(0xFF111318),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF5B5FEF),
        brightness: brightness,
        surface: brightness == Brightness.dark
            ? const Color(0xFF191B20)
            : const Color(0xFFFFFFFF),
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: brightness == Brightness.dark
            ? const Color(0xFF1E2128)
            : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(22)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: brightness == Brightness.dark
            ? const Color(0xFF1E2128)
            : Colors.white,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.dark
            ? const Color(0xFF252932)
            : Colors.white,
      ),
      listTileTheme: ListTileThemeData(
        tileColor: Colors.transparent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_geladen) {
      return MaterialApp(
        title: 'Vokabeltrainer Pro',
        theme: _theme(Brightness.light),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
        debugShowCheckedModeBanner: false,
      );
    }

    return MaterialApp(
      title: 'Vokabeltrainer Pro',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: _darkMode ? ThemeMode.dark : ThemeMode.light,
      home: MainMenuScreen(
        darkMode: _darkMode,
        onDarkModeChanged: _setDarkMode,
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}

// --- HAUPTMENÜ SCREEN ---
class MainMenuScreen extends StatefulWidget {
  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  const MainMenuScreen({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
  });

  @override
  State<MainMenuScreen> createState() => _MainMenuScreenState();
}

class _MainMenuScreenState extends State<MainMenuScreen> {
  Timer? _refreshTimer;
  final List<VokabelGruppe> _gruppen = [];

  @override
  void initState() {
    super.initState();
    _appStartProzess();
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      for (final gruppe in _gruppen) {
        gruppe.synchronisiereStreak();
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _appStartProzess() async {
    await _initNotifications();
    await _loadDataFromStorage();
    for (final gruppe in _gruppen) {
      gruppe.synchronisiereStreak();
    }
    await planeKategorieErinnerungen(_gruppen);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _saveDataToStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _gruppen.map((g) => g.toJson()).toList();
    await prefs.setString('vokabel_daten_speicher_v3', jsonEncode(jsonList));
  }

  Future<void> _loadDataFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    String? jsonString = prefs.getString('vokabel_daten_speicher_v3');
    if (jsonString == null || jsonString.isEmpty) {
      jsonString = prefs.getString('vokabel_daten_speicher_v2');
    }
    if (jsonString == null || jsonString.isEmpty) {
      jsonString = prefs.getString('vokabel_daten_speicher');
    }

    if (jsonString != null && jsonString.isNotEmpty) {
      try {
        List<dynamic> decoded = jsonDecode(jsonString);
        setState(() {
          _gruppen.clear();
          for (var item in decoded) {
            _gruppen.add(VokabelGruppe.fromJson(item));
          }
        });
      } catch (e) {
        debugPrint("Fehler beim Laden: $e");
      }
    }
  }

  void _aktualisiereBenachrichtigungenUndSpeichern() async {
    for (final gruppe in _gruppen) {
      gruppe.synchronisiereStreak();
    }
    await _saveDataToStorage();
    await planeKategorieErinnerungen(_gruppen);
    if (mounted) setState(() {});
  }

  void _neueGruppeErstellen() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Neue Gruppe erstellen'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'z.B. Englisch'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                setState(() {
                  _gruppen.add(
                    VokabelGruppe(
                      name: controller.text.trim(),
                      vokabeln: [],
                      kartenFarbe: Colors.white,
                    ),
                  );
                });
                _aktualisiereBenachrichtigungenUndSpeichern();
                Navigator.pop(context);
              }
            },
            child: const Text('Erstellen'),
          ),
        ],
      ),
    );
  }

  void _gruppeLoeschen(int index) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Gruppe löschen?'),
        content: Text(
          'Möchtest du "${_gruppen[index].name}" wirklich löschen?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              setState(() {
                _gruppen.removeAt(index);
              });
              _aktualisiereBenachrichtigungenUndSpeichern();
              Navigator.pop(context);
            },
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meine Vokabelgruppen'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Einstellungen',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AppSettingsScreen(
                    darkMode: widget.darkMode,
                    onDarkModeChanged: widget.onDarkModeChanged,
                  ),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: _gruppen.isEmpty
          ? const Center(child: Text('Keine Gruppen erstellt. Klicke auf +'))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _gruppen.length,
              itemBuilder: (context, index) {
                final gruppe = _gruppen[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  elevation: 3,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Theme.of(context).colorScheme.surfaceContainerHighest
                      : gruppe.kartenFarbe.withOpacity(0.8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: InkWell(
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => GruppeDetailScreen(
                            gruppe: gruppe,
                            onChanged:
                                _aktualisiereBenachrichtigungenUndSpeichern,
                          ),
                        ),
                      );
                      _aktualisiereBenachrichtigungenUndSpeichern();
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  gruppe.name,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${gruppe.vokabeln.length} Vokabeln • Session: ${gruppe.vokabelnProSession} Stk.',
                                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                ),
                                const SizedBox(height: 5),
                                Row(
                                  children: [
                                    const Text('🔥', style: TextStyle(fontSize: 14)),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${gruppe.streak} Tage • ${gruppe.sessionsHeute}/${gruppe.tagesziel} heute',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.deepOrange,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.alarm,
                                      size: 14,
                                      color: Colors.blueGrey,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      holeNaechsteErinnerungText(gruppe),
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.blueGrey,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.play_arrow,
                              color: Colors.green,
                              size: 30,
                            ),
                            onPressed: gruppe.vokabeln.isEmpty
                                ? null
                                : () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => FlashcardScreen(
                                          gruppe: gruppe,
                                          onFinished:
                                              _aktualisiereBenachrichtigungenUndSpeichern,
                                        ),
                                      ),
                                    );
                                  },
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                            ),
                            onPressed: () => _gruppeLoeschen(index),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton(
            heroTag: 'main_library_button',
            tooltip: 'Vokabelbibliothek',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => VokabelBibliothekScreen(
                    gruppen: _gruppen,
                  ),
                ),
              );
              _aktualisiereBenachrichtigungenUndSpeichern();
            },
            child: const Icon(Icons.menu_book),
          ),
          const SizedBox(width: 14),
          FloatingActionButton(
            heroTag: 'main_add_group_button',
            tooltip: 'Neue Gruppe',
            onPressed: _neueGruppeErstellen,
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

// --- KATEGORIE DETAIL SCREEN ---
class GruppeDetailScreen extends StatefulWidget {
  final VokabelGruppe gruppe;
  final VoidCallback onChanged;

  const GruppeDetailScreen({
    super.key,
    required this.gruppe,
    required this.onChanged,
  });

  @override
  State<GruppeDetailScreen> createState() => _GruppeDetailScreenState();
}

class _GruppeDetailScreenState extends State<GruppeDetailScreen> {
  final List<Color> _farbOptionen = [
    Colors.white,
    Colors.blue[50]!,
    Colors.green[50]!,
    Colors.orange[50]!,
    Colors.purple[50]!,
    Colors.red[50]!,
    Colors.yellow[50]!,
  ];

  List<Vokabel> get _sortierteVokabeln {
    final liste = List<Vokabel>.from(widget.gruppe.vokabeln);
    if (!widget.gruppe.priorisiereSchlechte) {
      liste.shuffle();
      return liste;
    }
    liste.sort((a, b) {
      final p = b.lernPrioritaet.compareTo(a.lernPrioritaet);
      return p != 0 ? p : a.fremdsprache.compareTo(b.fremdsprache);
    });
    return liste;
  }

  Color _ermittleScoreFarbe(Vokabel v) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (v.abgefragtGezaehlt == 0) {
      return dark ? const Color(0xFF18304A) : Colors.blue[50]!;
    }
    final q = v.kenntnisQuote;
    if (q < .45) return dark ? const Color(0xFF452025) : Colors.red[100]!;
    if (q < .70) return dark ? const Color(0xFF49351D) : Colors.orange[100]!;
    if (q < .85) return dark ? const Color(0xFF48411A) : Colors.yellow[100]!;
    return dark ? const Color(0xFF193D2A) : Colors.green[100]!;
  }

  void _zeigeFehler(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _vokabelManuellHinzufuegenOderBearbeiten({Vokabel? vokabel}) {
    final istBearbeiten = vokabel != null;
    final deController = TextEditingController(
      text: istBearbeiten ? vokabel.deutsch : '',
    );
    final foreignController = TextEditingController(
      text: istBearbeiten ? vokabel.fremdsprache : '',
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(istBearbeiten ? 'Vokabel bearbeiten' : 'Neue Vokabel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: deController,
              decoration: const InputDecoration(labelText: 'Deutsches Wort'),
              autofocus: true,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: foreignController,
              decoration: const InputDecoration(labelText: 'Fremdsprache'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            onPressed: () {
              if (deController.text.trim().isNotEmpty &&
                  foreignController.text.trim().isNotEmpty) {
                setState(() {
                  if (istBearbeiten) {
                    vokabel.deutsch = deController.text.trim();
                    vokabel.fremdsprache = foreignController.text.trim();
                  } else {
                    widget.gruppe.vokabeln.add(
                      Vokabel(
                        deutsch: deController.text.trim(),
                        fremdsprache: foreignController.text.trim(),
                      ),
                    );
                  }
                });
                widget.onChanged();
                Navigator.pop(context);
              }
            },
            child: Text(istBearbeiten ? 'Speichern' : 'Hinzufügen'),
          ),
        ],
      ),
    );
  }

  void _oeffneKategorieEinstellungen() {
    double tempAnzahl = widget.gruppe.benachrichtigungenProTag.toDouble();
    double tempStart = widget.gruppe.startStunde.toDouble();
    double tempEnd = widget.gruppe.endStunde.toDouble();
    double tempProSession = widget.gruppe.vokabelnProSession.toDouble();
    bool tempPriorisierung = widget.gruppe.priorisiereSchlechte;
    Color tempFarbe = widget.gruppe.kartenFarbe;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          double r = tempFarbe.red.toDouble();
          double g = tempFarbe.green.toDouble();
          double b = tempFarbe.blue.toDouble();

          return Padding(
            padding: EdgeInsets.only(
              top: 20,
              left: 20,
              right: 20,
              bottom: MediaQuery.of(context).viewInsets.bottom + 30,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.gruppe.name} konfigurieren',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 15),

                  const Text(
                    '1. Presets für Kartenfarbe:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 40,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _farbOptionen.length,
                      itemBuilder: (context, idx) {
                        final f = _farbOptionen[idx];
                        return GestureDetector(
                          onTap: () {
                            setModalState(() {
                              tempFarbe = f;
                            });
                          },
                          child: Container(
                            margin: const EdgeInsets.only(right: 10),
                            width: 40,
                            decoration: BoxDecoration(
                              color: f,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: tempFarbe.value == f.value
                                    ? Colors.blue
                                    : Colors.grey[400]!,
                                width: tempFarbe.value == f.value ? 3 : 1,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 15),

                  const Text(
                    'Oder eigene Farbe mischen (RGB-Regler):',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey,
                    ),
                  ),
                  Row(
                    children: [
                      const Text(
                        'R ',
                        style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: r,
                          min: 0,
                          max: 255,
                          activeColor: Colors.red,
                          onChanged: (v) => setModalState(() {
                            tempFarbe = Color.fromARGB(
                              255,
                              v.round(),
                              g.round(),
                              b.round(),
                            );
                          }),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text(
                        'G ',
                        style: TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: g,
                          min: 0,
                          max: 255,
                          activeColor: Colors.green,
                          onChanged: (v) => setModalState(() {
                            tempFarbe = Color.fromARGB(
                              255,
                              r.round(),
                              v.round(),
                              b.round(),
                            );
                          }),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text(
                        'B ',
                        style: TextStyle(
                          color: Colors.blue,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: b,
                          min: 0,
                          max: 255,
                          activeColor: Colors.blue,
                          onChanged: (v) => setModalState(() {
                            tempFarbe = Color.fromARGB(
                              255,
                              r.round(),
                              v.round(),
                              b.round(),
                            );
                          }),
                        ),
                      ),
                    ],
                  ),

                  Container(
                    height: 35,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: tempFarbe,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey[300]!),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Vorschau gewählte Farbe',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: tempFarbe.computeLuminance() > 0.5
                            ? Colors.black
                            : Colors.white,
                      ),
                    ),
                  ),
                  const Divider(height: 30),

                  Text(
                    '2. Vokabeln pro Abfrage-Session: ${tempProSession.round()}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Slider(
                    value: tempProSession,
                    min: 5,
                    max: 50,
                    divisions: 9,
                    onChanged: (val) {
                      setModalState(() {
                        tempProSession = val;
                      });
                    },
                  ),

                  const Text(
                    '3. Abfrage-Algorithmus:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SwitchListTile(
                    title: Text(
                      tempPriorisierung
                          ? 'Schlechte Vokabeln priorisieren'
                          : 'Alles zufällig mischen',
                    ),
                    subtitle: Text(
                      tempPriorisierung
                          ? 'Fokus auf rote/orange Vokabeln'
                          : 'Gleiche Chance für alle Wörter',
                    ),
                    value: tempPriorisierung,
                    onChanged: (val) {
                      setModalState(() {
                        tempPriorisierung = val;
                      });
                    },
                  ),
                  const Divider(height: 20),

                  Text(
                    'Erinnerungen pro Tag: ${tempAnzahl.round()} mal',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Slider(
                    value: tempAnzahl,
                    min: 0,
                    max: 15,
                    divisions: 15,
                    onChanged: (val) {
                      setModalState(() {
                        tempAnzahl = val;
                      });
                    },
                  ),

                  Text(
                    'Zeitfenster: ${tempStart.round()}:00 bis ${tempEnd.round()}:00 Uhr',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  RangeSlider(
                    values: RangeValues(tempStart, tempEnd),
                    min: 0,
                    max: 24,
                    divisions: 24,
                    labels: RangeLabels(
                      '${tempStart.round()}:00',
                      '${tempEnd.round()}:00',
                    ),
                    onChanged: (val) {
                      if (val.end > val.start)
                        setModalState(() {
                          tempStart = val.start;
                          tempEnd = val.end;
                        });
                    },
                  ),
                  const SizedBox(height: 20),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          widget.gruppe.kartenFarbe = tempFarbe;
                          widget.gruppe.benachrichtigungenProTag = tempAnzahl
                              .round();
                          widget.gruppe.startStunde = tempStart.round();
                          widget.gruppe.endStunde = tempEnd.round();
                          widget.gruppe.vokabelnProSession = tempProSession
                              .round();
                          widget.gruppe.priorisiereSchlechte =
                              tempPriorisierung;
                        });
                        widget.onChanged();
                        Navigator.pop(context);
                      },
                      child: const Text('Konfiguration Speichern'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    widget.gruppe.synchronisiereStreak();
    final sortierteListe = _sortierteVokabeln;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.gruppe.name),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.bar_chart,
              color: Colors.deepPurple,
              size: 28,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => StatistikScreen(gruppe: widget.gruppe),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Vokabelbibliothek',
            icon: const Icon(Icons.menu_book, color: Colors.indigo),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => VokabelBibliothekScreen(
                    gruppen: [widget.gruppe],
                    zielGruppe: widget.gruppe,
                  ),
                ),
              );
              widget.onChanged();
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _oeffneKategorieEinstellungen,
          ),
        ],
      ),
      body: Stack(
        children: [
          sortierteListe.isEmpty
              ? const Center(
                  child: Text(
                    'Keine Vokabeln. Klicke auf 📚 für die GitHub-Bibliothek oder auf + zum Hinzufügen.',
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: sortierteListe.length,
                  itemBuilder: (context, index) {
                    final vokabel = sortierteListe[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: _ermittleScoreFarbe(vokabel),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          child: Text(
                            vokabel.abgefragtGezaehlt == 0
                                ? 'neu'
                                : '${vokabel.kenntnisProzent}%',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          vokabel.fremdsprache,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(vokabel.deutsch),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, color: Colors.blue),
                              onPressed: () =>
                                  _vokabelManuellHinzufuegenOderBearbeiten(
                                    vokabel: vokabel,
                                  ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.grey,
                              ),
                              onPressed: () {
                                setState(() {
                                  widget.gruppe.vokabeln.remove(vokabel);
                                });
                                widget.onChanged();
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _vokabelManuellHinzufuegenOderBearbeiten(),
        child: const Icon(Icons.add),
      ),
    );
  }
}

// --- TRAINER SCREEN (FLASHCARDS) ---
class FlashcardScreen extends StatefulWidget {
  final VokabelGruppe gruppe;
  final VoidCallback onFinished;

  const FlashcardScreen({
    super.key,
    required this.gruppe,
    required this.onFinished,
  });

  @override
  State<FlashcardScreen> createState() => _FlashcardScreenState();
}

class _FlashcardScreenState extends State<FlashcardScreen>
    with SingleTickerProviderStateMixin {
  late List<Vokabel> _aktuelleVokabeln;
  int _currentIndex = 0;
  int _richtigZaehler = 0;
  late AnimationController _animationController;
  late Animation<double> _animation;
  bool _darfSwipen = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _animation = Tween<double>(begin: 0, end: 1).animate(_animationController);
    _animationController.addStatusListener((status) {
      setState(() {
        _darfSwipen = (status == AnimationStatus.completed);
      });
    });
    _spielStarten();
  }

  void _spielStarten() {
    var pool = List<Vokabel>.from(widget.gruppe.vokabeln);

    if (widget.gruppe.priorisiereSchlechte) {
      final selected = <Vokabel>[];
      final remaining = List<Vokabel>.from(pool);
      final target = min(remaining.length, widget.gruppe.vokabelnProSession);

      while (selected.length < target && remaining.isNotEmpty) {
        final weights = remaining
            .map((v) => (0.25 + pow(v.lernPrioritaet, 2.0) * 4.0).toDouble())
            .toList();
        final sum = weights.fold<double>(0, (a, b) => a + b);
        var r = Random().nextDouble() * sum;
        var index = remaining.length - 1;
        for (int i = 0; i < remaining.length; i++) {
          r -= weights[i];
          if (r <= 0) {
            index = i;
            break;
          }
        }
        selected.add(remaining.removeAt(index));
      }
      pool = selected;
    } else {
      pool.shuffle();
    }

    _aktuelleVokabeln = pool.take(widget.gruppe.vokabelnProSession).toList();
    _currentIndex = 0;
    _richtigZaehler = 0;
    _animationController.reset();
    _darfSwipen = false;
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _flipCard() {
    if (_animationController.isCompleted) {
      _animationController.reverse();
    } else {
      _animationController.forward();
    }
  }

  void _naechsteKarte(bool warRichtig) {
    final vokabel = _aktuelleVokabeln[_currentIndex];
    vokabel.registriereAntwort(warRichtig);
    if (warRichtig) _richtigZaehler++;

    setState(() {
      _currentIndex++;
      _animationController.reset();
      _darfSwipen = false;
    });

    if (_currentIndex >= _aktuelleVokabeln.length) {
      final datumStr = "${DateTime.now().day}.${DateTime.now().month}.";
      final gesamt = _aktuelleVokabeln.length;
      final sessionQuote = gesamt == 0 ? 0.0 : _richtigZaehler / gesamt;
      widget.gruppe.statistikHistorie.add(
        SessionStat(
          datum: datumStr,
          richtigQuote: sessionQuote,
          richtig: _richtigZaehler,
          gesamt: gesamt,
          lernstandQuote: widget.gruppe.durchschnittlicheKenntnis,
        ),
      );
      if (widget.gruppe.statistikHistorie.length > 30) {
        widget.gruppe.statistikHistorie.removeAt(0);
      }

      // Eine abgeschlossene Session zählt für das Tagesziel.
      // Die Streak steigt erst, wenn alle für heute erforderlichen Sessions
      // abgeschlossen wurden.
      final streakErhoeht = widget.gruppe.registriereSessionAbschluss();
      widget.onFinished();

      if (mounted && streakErhoeht) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '🔥 ${widget.gruppe.streak} Tage Streak! Tagesziel geschafft.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_currentIndex >= _aktuelleVokabeln.length) {
      String naechsteInfo = holeNaechsteErinnerungText(widget.gruppe);
      bool istLetzteSessionHeute = naechsteInfo.contains("morgen");

      return Scaffold(
        appBar: AppBar(
          title: const Text('Ergebnis'),
          automaticallyImplyLeading: false,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Session beendet!',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                Text(
                  '$_richtigZaehler von ${_aktuelleVokabeln.length} richtig!',
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 20),
                _StreakResultCard(gruppe: widget.gruppe),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        istLetzteSessionHeute
                            ? Icons.nights_stay
                            : Icons.schedule,
                        color: istLetzteSessionHeute
                            ? Colors.indigo
                            : Colors.blue,
                        size: 40,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        istLetzteSessionHeute
                            ? "Klasse gemacht! Gute Nacht, das war die letzte Session für heute."
                            : naechsteInfo,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
                ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.check),
                  label: const Text('Zurück zum Menü'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final aktuelleVokabel = _aktuelleVokabeln[_currentIndex];

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.gruppe.name} (${_currentIndex + 1}/${_aktuelleVokabeln.length})',
        ),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: Dismissible(
              key: ValueKey('card_$_currentIndex'),
              direction: _darfSwipen
                  ? DismissDirection.horizontal
                  : DismissDirection.none,
              onDismissed: (direction) {
                _naechsteKarte(direction == DismissDirection.startToEnd);
              },
              background: _buildSwipeBackground(
                Colors.green,
                Icons.check,
                Alignment.centerLeft,
              ),
              secondaryBackground: _buildSwipeBackground(
                Colors.red,
                Icons.close,
                Alignment.centerRight,
              ),
              child: GestureDetector(
                onTap: _flipCard,
                child: AnimatedBuilder(
                  animation: _animation,
                  builder: (context, child) {
                    final angle = _animation.value * pi;
                    final isFront = angle < (pi / 2);
                    return Transform(
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.001)
                        ..rotateY(angle),
                      alignment: Alignment.center,
                      child: isFront
                          ? _buildCardSide(
                              aktuelleVokabel.deutsch,
                              Theme.of(context).brightness == Brightness.dark
                                  ? const Color(0xFF202B3A)
                                  : (widget.gruppe.kartenFarbe == Colors.white
                                      ? Colors.blue[50]!
                                      : widget.gruppe.kartenFarbe),
                              Theme.of(context).brightness == Brightness.dark
                                  ? const Color(0xFFB9D7FF)
                                  : Colors.blue[900]!,
                            )
                          : Transform(
                              transform: Matrix4.identity()..rotateY(pi),
                              alignment: Alignment.center,
                              child: _buildCardSide(
                                aktuelleVokabel.fremdsprache,
                                Theme.of(context).brightness == Brightness.dark
                                    ? const Color(0xFF24262D)
                                    : widget.gruppe.kartenFarbe,
                                Theme.of(context).brightness == Brightness.dark
                                    ? Colors.white
                                    : Colors.black,
                              ),
                            ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSwipeBackground(
    Color color,
    IconData icon,
    Alignment alignment,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 60),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Icon(icon, color: Colors.white, size: 40),
    );
  }

  Widget _buildCardSide(String text, Color bgColor, Color textColor) {
    return Container(
      width: double.infinity,
      height: 450,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.shadow.withOpacity(0.18),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
          textAlign: TextAlign.center,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}


class _StreakResultCard extends StatelessWidget {
  final VokabelGruppe gruppe;

  const _StreakResultCard({required this.gruppe});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: Theme.of(context).brightness == Brightness.dark
              ? [const Color(0xFF3B2A16), const Color(0xFF4A3518)]
              : [Colors.orange.shade50, Colors.amber.shade100],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF76531E)
              : Colors.orange.shade200,
        ),
      ),
      child: Row(
        children: [
          const Text('🔥', style: TextStyle(fontSize: 30)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              gruppe.tageszielErreicht
                  ? '${gruppe.streak} Tage Streak • Tagesziel geschafft!'
                  : '${gruppe.sessionsHeute}/${gruppe.tagesziel} Sessions heute • Noch ${gruppe.fehlendeSessionsHeute} nötig',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

// --- STATISTIK ---
class StatistikScreen extends StatelessWidget {
  final VokabelGruppe gruppe;
  const StatistikScreen({super.key, required this.gruppe});

  @override
  Widget build(BuildContext context) {
    final sorgenkinder = gruppe.vokabeln
        .where((v) => v.abgefragtGezaehlt > 0 && v.kenntnisQuote < .45)
        .length;
    final sichere = gruppe.vokabeln
        .where((v) => v.abgefragtGezaehlt > 0 && v.kenntnisQuote >= .85)
        .length;
    final neue = gruppe.vokabeln.where((v) => v.abgefragtGezaehlt == 0).length;
    final durchschnitt = gruppe.durchschnittlicheKenntnisProzent;

    return Scaffold(
      appBar: AppBar(title: Text('Statistik: ${gruppe.name}')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatHero(prozent: durchschnitt, anzahl: gruppe.vokabeln.length),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(child: _StatTile(Icons.warning_amber_rounded, '$sorgenkinder', 'Üben', Colors.red)),
              const SizedBox(width: 10),
              Expanded(child: _StatTile(Icons.auto_awesome, '$sichere', 'Sicher', Colors.green)),
              const SizedBox(width: 10),
              Expanded(child: _StatTile(Icons.fiber_new_rounded, '$neue', 'Neu', Colors.blue)),
            ]),
            const SizedBox(height: 24),
            const Text('Dein Lernstand über die Zeit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Container(
              height: 250,
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(.05), blurRadius: 24, offset: const Offset(0, 10))],
              ),
              child: gruppe.statistikHistorie.isEmpty
                  ? const Center(child: Text('Noch keine Session-Daten.\nStarte zuerst ein Training.', textAlign: TextAlign.center))
                  : RepaintBoundary(
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: LineChartPainter(
                          gruppe.statistikHistorie.length > 30
                              ? gruppe.statistikHistorie.sublist(gruppe.statistikHistorie.length - 30)
                              : gruppe.statistikHistorie,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 22),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Theme.of(context).colorScheme.primaryContainer, Theme.of(context).colorScheme.secondaryContainer]),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.psychology_alt_rounded, size: 32),
                const SizedBox(width: 12),
                Expanded(child: Text(
                  sorgenkinder > 0
                      ? 'Der Algorithmus fokussiert automatisch stärker auf $sorgenkinder schwierige Vokabeln. Starke Wörter bleiben aber im Pool.'
                      : 'Sehr gut! Aktuell gibt es keine stark problematischen Vokabeln. Sichere Wörter werden trotzdem regelmäßig wiederholt.',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                )),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatHero extends StatelessWidget {
  final int prozent;
  final int anzahl;
  const _StatHero({required this.prozent, required this.anzahl});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.tertiary]),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [BoxShadow(color: Theme.of(context).colorScheme.primary.withOpacity(.25), blurRadius: 28, offset: const Offset(0, 14))],
      ),
      child: Row(children: [
        SizedBox(
          width: 92,
          height: 92,
          child: Stack(fit: StackFit.expand, children: [
            CircularProgressIndicator(value: (prozent / 100).clamp(0.0, 1.0), strokeWidth: 9, backgroundColor: Colors.white.withOpacity(.22), color: Colors.white),
            Center(child: Text('$prozent%', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900))),
          ]),
        ),
        const SizedBox(width: 18),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Aktueller Lernstand', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text('$anzahl Vokabeln im Pool', style: TextStyle(color: Colors.white.withOpacity(.88))),
        ])),
      ]),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;
  const _StatTile(this.icon, this.value, this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
      child: Column(children: [
        Icon(icon, color: color),
        const SizedBox(height: 5),
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: color)),
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class LineChartPainter extends CustomPainter {
  final List<SessionStat> stats;
  LineChartPainter(this.stats);

  @override
  void paint(Canvas canvas, Size size) {
    if (stats.isEmpty || size.width <= 10 || size.height <= 10) return;
    const left = 36.0, right = 10.0, top = 14.0, bottom = 30.0;
    final chart = Rect.fromLTRB(left, top, max(left + 10, size.width - right), max(top + 10, size.height - bottom));
    final grid = Paint()..color = Colors.grey.shade200..strokeWidth = 1;
    final line = Paint()..color = Colors.indigo..strokeWidth = 3..style = PaintingStyle.stroke..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    final dot = Paint()..color = Colors.indigo..style = PaintingStyle.fill;
    final text = TextPainter(textDirection: TextDirection.ltr);

    for (int i = 0; i <= 4; i++) {
      final y = chart.bottom - chart.height * i / 4;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
      text.text = TextSpan(text: '${i * 25}%', style: TextStyle(color: Colors.grey.shade600, fontSize: 9));
      text.layout();
      text.paint(canvas, Offset(0, y - text.height / 2));
    }

    final dx = stats.length == 1 ? 0.0 : chart.width / (stats.length - 1);
    final path = Path();
    for (int i = 0; i < stats.length; i++) {
      final value = stats[i].lernstandQuote.clamp(0.0, 1.0).toDouble();
      final x = stats.length == 1 ? chart.center.dx : chart.left + i * dx;
      final y = chart.bottom - value * chart.height;
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
      canvas.drawCircle(Offset(x, y), 5, dot);
      if (stats.length <= 12 || i == 0 || i == stats.length - 1) {
        text.text = TextSpan(text: stats[i].datum, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700));
        text.layout();
        final labelX = (x - text.width / 2).clamp(chart.left, chart.right - text.width).toDouble();
        text.paint(canvas, Offset(labelX, chart.bottom + 7));
      }
    }
    if (stats.length > 1) canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant LineChartPainter oldDelegate) => true;
}
