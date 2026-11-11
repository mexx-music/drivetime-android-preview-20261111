/// Converts a driver's remaining time budget into the elapsed values used by
/// the ETA planner. Inputs outside the selected daily limit are clamped.
class TimeBudget {
  static int elapsedFromRemaining(int remainingMinutes, int dailyLimitMinutes) {
    final remaining = remainingMinutes.clamp(0, dailyLimitMinutes);
    return dailyLimitMinutes - remaining;
  }
}
