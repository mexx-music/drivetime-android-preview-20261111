/// Ohne Web: nichts zu registrieren.
void registerExportHook({
  required double Function() step,
  required double Function() total,
  required int Function() pending,
  required String Function() state,
}) {}
