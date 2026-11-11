import 'package:intl/intl.dart';

import 'eta_calculator.dart';
import 'speed_profile.dart';

class TourExport {
  static String asText({
    required EtaResult result,
    required String origin,
    required String destination,
    RoadMixAnalysis? roadMix,
  }) {
    final summary = result.summary;
    final arrival = result.arrival;
    if (summary == null || arrival == null) return '';

    final buffer = StringBuffer()
      ..writeln('🚛 DriverRoute ETA')
      ..writeln('${_shortPlace(origin)} → ${_shortPlace(destination)}')
      ..writeln()
      ..writeln(
        '🏁 Ankunft: ${DateFormat('EEEE, dd.MM.yyyy – HH:mm', 'de').format(arrival)}',
      )
      ..writeln('🛣️ Distanz: ${summary.distanceKm.toStringAsFixed(0)} km')
      ..writeln('🚛 Fahrzeit: ${_duration(summary.drivingMinutes)}')
      ..writeln(
        '💨 Planungsschnitt: ${_speed(summary.averageKmh)} km/h',
      )
      ..writeln('☕ Pausen/Ruhe: ${_duration(summary.nonDrivingMinutes)}');

    if (roadMix != null && roadMix.hasBreakdown) {
      buffer
        ..writeln()
        ..writeln(
          'Straßenmix (Schätzung): ${roadMix.fastPercent} % schnell, '
          '${roadMix.mainRoadPercent} % Haupt-/Bundesstraße, '
          '${roadMix.slowPercent} % langsam/lokal',
        );
    }

    final visibleSteps = result.steps.where((step) => !step.technical);
    if (visibleSteps.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Tourablauf:');
      for (final step in visibleSteps) {
        buffer.writeln('• ${_stepText(step)}');
      }
    }

    buffer
      ..writeln()
      ..write('Erstellt mit DriverRoute ETA');
    return buffer.toString();
  }

  static String _stepText(EtaStep step) {
    final title = step.title ?? step.text;
    if (step.start == null) return title;
    final start = DateFormat('EEE dd.MM. HH:mm', 'de').format(step.start!);
    final end = step.end;
    if (end == null || end == step.start) return '$start · $title';
    return '$start–${DateFormat('HH:mm').format(end)} · $title';
  }

  static String _duration(int minutes) {
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    if (hours == 0) return '$rest min';
    if (rest == 0) return '$hours h';
    return '$hours h ${rest.toString().padLeft(2, '0')} min';
  }

  static String _speed(double kmh) => kmh == kmh.roundToDouble()
      ? kmh.toStringAsFixed(0)
      : kmh.toStringAsFixed(1);

  static String _shortPlace(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? '–' : trimmed.split(',').first.trim();
  }
}
