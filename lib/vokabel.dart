// lib/vokabel.dart
import 'package:flutter/material.dart';

/// Ein einzelnes Lernwort.
///
/// Die alten Felder richtigGezaehlt/abgefragtGezaehlt bleiben erhalten,
/// damit vorhandene gespeicherte Daten weiter funktionieren.
class Vokabel {
  String deutsch;
  String fremdsprache;
  int richtigGezaehlt;
  int abgefragtGezaehlt;

  // Neue Felder für einen stabileren Lernalgorithmus.
  bool letzteAntwortRichtig;
  int aufeinanderfolgendRichtig;
  int aufeinanderfolgendFalsch;
  int letzteAbfrageMillis;

  Vokabel({
    required this.deutsch,
    required this.fremdsprache,
    this.richtigGezaehlt = 0,
    this.abgefragtGezaehlt = 0,
    this.letzteAntwortRichtig = false,
    this.aufeinanderfolgendRichtig = 0,
    this.aufeinanderfolgendFalsch = 0,
    this.letzteAbfrageMillis = 0,
  });

  /// Bayesianisch geglättete Kenntnis statt einer nackten Quote.
  ///
  /// Dadurch wird 1/1 nicht fälschlich als "100 % sicher" behandelt.
  /// Gleichzeitig ist 5/8 (62,5 %) schlechter als 1/1 (100 %), ohne dass
  /// eine einzige richtige Antwort sofort zu einem perfekten Score führt.
  double get kenntnisQuote {
    // Beta(2,2)-Prior: bei 0 Antworten starten wir bei 50 %.
    return ((richtigGezaehlt + 2) / (abgefragtGezaehlt + 4)).clamp(0.0, 1.0).toDouble();
  }

  int get kenntnisProzent => (kenntnisQuote * 100).round();

  /// Prioritätswert für den Abfragealgorithmus.
  /// Höher = sollte eher abgefragt werden.
  double get lernPrioritaet {
    if (abgefragtGezaehlt == 0) return 0.72;

    final fehler = 1.0 - kenntnisQuote;
    final unsicherheit = 0.22 / sqrtDouble(abgefragtGezaehlt + 1.0);
    final wiederholungsBonus = aufeinanderfolgendFalsch > 0
        ? minDouble(0.28, aufeinanderfolgendFalsch * 0.09)
        : 0.0;
    final erfolgsDaempfer = aufeinanderfolgendRichtig > 0
        ? minDouble(0.24, aufeinanderfolgendRichtig * 0.045)
        : 0.0;

    // Nach einer falschen Antwort wird das Wort deutlich wichtiger, aber
    // nicht so stark, dass es fünfmal hintereinander erscheint.
    final basis = fehler * 0.82 + unsicherheit + wiederholungsBonus - erfolgsDaempfer;

    // Alte Wörter bekommen einen kleinen "Vergessen mit der Zeit"-Bonus.
    if (letzteAbfrageMillis > 0) {
      final tage = DateTime.now()
              .difference(DateTime.fromMillisecondsSinceEpoch(letzteAbfrageMillis))
              .inHours /
          24.0;
      final zeitBonus = (tage / 10.0).clamp(0.0, 0.22);
      return (basis + zeitBonus).clamp(0.02, 1.0).toDouble();
    }

    return basis.clamp(0.02, 1.0).toDouble();
  }


  void registriereAntwort(bool richtig) {
    abgefragtGezaehlt++;
    if (richtig) {
      richtigGezaehlt++;
      aufeinanderfolgendRichtig++;
      aufeinanderfolgendFalsch = 0;
    } else {
      aufeinanderfolgendFalsch++;
      aufeinanderfolgendRichtig = 0;
    }
    letzteAntwortRichtig = richtig;
    letzteAbfrageMillis = DateTime.now().millisecondsSinceEpoch;
  }

  factory Vokabel.fromJson(Map<String, dynamic> json) {
    return Vokabel(
      deutsch: json['deutsch'] ?? '',
      fremdsprache: json['fremdsprache'] ?? '',
      richtigGezaehlt: _int(json['richtigGezaehlt']),
      abgefragtGezaehlt: _int(json['abgefragtGezaehlt']),
      letzteAntwortRichtig: json['letzteAntwortRichtig'] == true,
      aufeinanderfolgendRichtig: _int(json['aufeinanderfolgendRichtig']),
      aufeinanderfolgendFalsch: _int(json['aufeinanderfolgendFalsch']),
      letzteAbfrageMillis: _int(json['letzteAbfrageMillis']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'deutsch': deutsch,
      'fremdsprache': fremdsprache,
      'richtigGezaehlt': richtigGezaehlt,
      'abgefragtGezaehlt': abgefragtGezaehlt,
      'letzteAntwortRichtig': letzteAntwortRichtig,
      'aufeinanderfolgendRichtig': aufeinanderfolgendRichtig,
      'aufeinanderfolgendFalsch': aufeinanderfolgendFalsch,
      'letzteAbfrageMillis': letzteAbfrageMillis,
    };
  }
}

class SessionStat {
  final String datum;
  final double richtigQuote;
  final int richtig;
  final int gesamt;
  final double lernstandQuote;

  SessionStat({
    required this.datum,
    required this.richtigQuote,
    this.richtig = 0,
    this.gesamt = 0,
    double? lernstandQuote,
  }) : lernstandQuote = lernstandQuote ?? richtigQuote;

  factory SessionStat.fromJson(Map<String, dynamic> json) {
    return SessionStat(
      datum: json['datum'] ?? '',
      richtigQuote: (json['richtigQuote'] ?? 0.0).toDouble().clamp(0.0, 1.0).toDouble(),
      richtig: _int(json['richtig']),
      gesamt: _int(json['gesamt']),
      lernstandQuote: (json['lernstandQuote'] ?? json['richtigQuote'] ?? 0.0).toDouble().clamp(0.0, 1.0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'datum': datum,
      'richtigQuote': richtigQuote,
      'richtig': richtig,
      'gesamt': gesamt,
      'lernstandQuote': lernstandQuote,
    };
  }
}

class VokabelGruppe {
  String name;
  List<Vokabel> vokabeln;
  Color kartenFarbe;
  int benachrichtigungenProTag;
  int startStunde;
  int endStunde;
  int vokabelnProSession;
  bool priorisiereSchlechte;
  List<SessionStat> statistikHistorie;

  // Tagesziel/Streak. Eine Session zählt genau einmal zum Tagesziel.
  int streak;
  String? streakLetzterErfuellterTag;
  int sessionsHeute;
  String sessionsHeuteDatum;

  VokabelGruppe({
    required this.name,
    required this.vokabeln,
    required this.kartenFarbe,
    this.benachrichtigungenProTag = 3,
    this.startStunde = 8,
    this.endStunde = 20,
    this.vokabelnProSession = 15,
    this.priorisiereSchlechte = true,
    List<SessionStat>? statistikHistorie,
    this.streak = 0,
    this.streakLetzterErfuellterTag,
    this.sessionsHeute = 0,
    this.sessionsHeuteDatum = '',
  }) : statistikHistorie = statistikHistorie ?? [];

  String _tagKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// Setzt den Tageszähler beim Wechsel auf einen neuen Kalendertag zurück.
  /// Wenn das gestrige Tagesziel nicht erfüllt wurde, verfällt die Streak.
  void synchronisiereStreak([DateTime? jetzt]) {
    final heute = jetzt ?? DateTime.now();
    final heuteKey = _tagKey(heute);
    if (sessionsHeuteDatum == heuteKey) return;

    if (streakLetzterErfuellterTag != null) {
      final letzter = DateTime.tryParse(streakLetzterErfuellterTag!);
      if (letzter != null) {
        final tage = DateTime(heute.year, heute.month, heute.day)
            .difference(DateTime(letzter.year, letzter.month, letzter.day))
            .inDays;
        if (tage > 1) streak = 0;
      }
    }

    sessionsHeute = 0;
    sessionsHeuteDatum = heuteKey;
  }

  /// Meldet eine abgeschlossene Lernsession.
  /// Erst wenn das konfigurierte Tagesziel erreicht ist, wird die Streak
  /// für diesen Tag um 1 erhöht.
  bool registriereSessionAbschluss([DateTime? jetzt]) {
    synchronisiereStreak(jetzt);
    if (vokabeln.isEmpty) return false;

    final ziel = tagesziel;
    if (ziel <= 0) return false;
    sessionsHeute++;

    if (sessionsHeute < ziel) return false;

    final heute = jetzt ?? DateTime.now();
    final heuteKey = _tagKey(heute);

    // Der heutige Streak-Punkt darf nur einmal vergeben werden.
    if (streakLetzterErfuellterTag == heuteKey) return false;

    final letzter = streakLetzterErfuellterTag == null
        ? null
        : DateTime.tryParse(streakLetzterErfuellterTag!);

    if (letzter != null) {
      final tage = DateTime(heute.year, heute.month, heute.day)
          .difference(DateTime(letzter.year, letzter.month, letzter.day))
          .inDays;
      if (tage == 1) {
        streak++;
      } else if (tage > 1) {
        streak = 1;
      }
    } else {
      streak = 1;
    }

    streakLetzterErfuellterTag = heuteKey;
    return true;
  }

  int get tagesziel => benachrichtigungenProTag <= 0
      ? 0
      : benachrichtigungenProTag.clamp(1, 15).toInt();

  bool get tageszielErreicht => tagesziel > 0 && sessionsHeute >= tagesziel;

  int get fehlendeSessionsHeute =>
      maxInt(0, tagesziel - sessionsHeute);

  double get durchschnittlicheKenntnis {
    final bewertet = vokabeln.where((v) => v.abgefragtGezaehlt > 0).toList();
    if (bewertet.isEmpty) return 0;
    return bewertet.map((v) => v.kenntnisQuote).reduce((a, b) => a + b) /
        bewertet.length;
  }

  int get durchschnittlicheKenntnisProzent =>
      (durchschnittlicheKenntnis * 100).round();

  factory VokabelGruppe.fromJson(Map<String, dynamic> json) {
    final list = json['vokabeln'] as List? ?? [];
    final statsList = json['statistikHistorie'] as List? ?? [];

    return VokabelGruppe(
      name: json['name'] ?? 'Unbenannt',
      vokabeln: list
          .whereType<Map>()
          .map((i) => Vokabel.fromJson(Map<String, dynamic>.from(i)))
          .toList(),
      kartenFarbe: Color(_int(json['kartenFarbe'], fallback: Colors.white.value)),
      benachrichtigungenProTag: _int(json['benachrichtigungenProTag'], fallback: 3),
      startStunde: _int(json['startStunde'], fallback: 8),
      endStunde: _int(json['endStunde'], fallback: 20),
      vokabelnProSession: _int(json['vokabelnProSession'], fallback: 15),
      priorisiereSchlechte: json['priorisiereSchlechte'] ?? true,
      streak: _int(json['streak']),
      streakLetzterErfuellterTag: json['streakLetzterErfuellterTag']?.toString(),
      sessionsHeute: _int(json['sessionsHeute']),
      sessionsHeuteDatum: json['sessionsHeuteDatum']?.toString() ?? '',
      statistikHistorie: statsList
          .whereType<Map>()
          .map((i) => SessionStat.fromJson(Map<String, dynamic>.from(i)))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'vokabeln': vokabeln.map((v) => v.toJson()).toList(),
      'kartenFarbe': kartenFarbe.value,
      'benachrichtigungenProTag': benachrichtigungenProTag,
      'startStunde': startStunde,
      'endStunde': endStunde,
      'vokabelnProSession': vokabelnProSession,
      'priorisiereSchlechte': priorisiereSchlechte,
      'streak': streak,
      'streakLetzterErfuellterTag': streakLetzterErfuellterTag,
      'sessionsHeute': sessionsHeute,
      'sessionsHeuteDatum': sessionsHeuteDatum,
      'statistikHistorie': statistikHistorie.map((s) => s.toJson()).toList(),
    };
  }
}

int _int(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse('$value') ?? fallback;
}

int maxInt(int a, int b) => a > b ? a : b;

double minDouble(double a, double b) => a < b ? a : b;
double sqrtDouble(double x) {
  if (x <= 0) return 0;
  var r = x > 1 ? x : 1.0;
  for (int i = 0; i < 8; i++) {
    r = (r + x / r) / 2;
  }
  return r;
}
