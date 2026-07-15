import 'package:flutter_test/flutter_test.dart';
import 'package:parking_app/services/paris_time.dart';

void main() {
  test('convertit correctement les heures d’hiver et d’été à Paris', () {
    expect(atParis(DateTime.utc(2026, 1, 15, 12)).hour, 13);
    expect(atParis(DateTime.utc(2026, 7, 15, 12)).hour, 14);
  });

  test('planifie au lendemain quand l’heure parisienne est passée', () {
    final planned = nextParisHour(DateTime.utc(2026, 7, 15, 16, 30), 17);

    expect(planned.year, 2026);
    expect(planned.month, 7);
    expect(planned.day, 16);
    expect(planned.hour, 17);
  });

  test('respecte le saut de l heure de printemps', () {
    final before = atParis(DateTime.utc(2026, 3, 29, 0, 59));
    final after = atParis(DateTime.utc(2026, 3, 29, 1, 1));

    expect(before.hour, 1);
    expect(before.minute, 59);
    expect(after.hour, 3);
    expect(after.minute, 1);
  });

  test('distingue les deux occurrences de 2 h en automne', () {
    final summerOccurrence = atParis(DateTime.utc(2026, 10, 25, 0, 30));
    final winterOccurrence = atParis(DateTime.utc(2026, 10, 25, 1, 30));

    expect(summerOccurrence.hour, 2);
    expect(winterOccurrence.hour, 2);
    expect(summerOccurrence.timeZoneOffset, const Duration(hours: 2));
    expect(winterOccurrence.timeZoneOffset, const Duration(hours: 1));
  });

  test('utilise la date parisienne même quand UTC est encore la veille', () {
    final paris = atParis(DateTime.utc(2026, 7, 15, 22, 30));

    expect(paris.day, 16);
    expect(paris.hour, 0);
    expect(paris.minute, 30);
  });
}
