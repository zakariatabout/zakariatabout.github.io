import 'package:timezone/data/latest_10y.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

bool _initialized = false;

timezone.Location get _paris {
  if (!_initialized) {
    timezone_data.initializeTimeZones();
    _initialized = true;
  }
  return timezone.getLocation('Europe/Paris');
}

/// Convertit un instant vers l'heure civile de Paris avec les règles IANA,
/// notamment les transitions heure d'été / heure d'hiver.
DateTime atParis(DateTime instant) => timezone.TZDateTime.from(instant, _paris);

/// Prochaine occurrence d'une heure pleine dans le fuseau de Paris.
DateTime nextParisHour(DateTime instant, int hour) {
  final now = atParis(instant);
  var planned = timezone.TZDateTime(_paris, now.year, now.month, now.day, hour);
  if (!planned.isAfter(now)) {
    planned = timezone.TZDateTime(
      _paris,
      now.year,
      now.month,
      now.day + 1,
      hour,
    );
  }
  return planned;
}
