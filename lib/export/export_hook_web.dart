import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Stellt `window.drivetimeExport` bereit:
/// - `step()` rechnet genau ein Bild (1/30 s) weiter, liefert die Zeit (s),
/// - `total()` die Gesamtdauer (s),
/// - `pending()` wie viele Fahrzeugbilder noch entstehen – 0 erst, wenn das
///   Bild exakt die berechneten Fahrzeugbilder zeigt,
/// - `state()` gewünschtes und gezeigtes Fahrzeugbild (JSON, Nachweis).
/// Ein Aufnahmeskript ruft `step()`, wartet bis `pending()` 0 ist und die
/// Karte fertig gezeichnet hat, und nimmt dann das Bild auf.
void registerExportHook({
  required double Function() step,
  required double Function() total,
  required int Function() pending,
  required String Function() state,
}) {
  final o = JSObject();
  o['step'] = (() => step()).toJS;
  o['total'] = (() => total()).toJS;
  o['pending'] = (() => pending()).toJS;
  o['state'] = (() => state()).toJS;
  globalContext['drivetimeExport'] = o;
}
