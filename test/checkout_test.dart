import 'package:event_pulse/checkout.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds an API-shaped entry so tests exercise the same parsing path as the app.
Map<String, dynamic> entry({
  Object? firstName = 'Ada',
  Object? lastName = 'Lovelace',
  Object? checkedOutAt = '2026-09-16T14:05:00Z',
}) {
  return {
    'id': '1',
    'attributes': {
      'first_name': firstName,
      'last_name': lastName,
      'checked_out_at': checkedOutAt,
    },
  };
}

/// A local-time [DateTime] so "today" comparisons are not skewed by the
/// machine's timezone when the test runs.
DateTime localAt(int year, int month, int day, [int hour = 12]) =>
    DateTime(year, month, day, hour);

Checkout checkout(String name, DateTime time) => Checkout(
      name: name,
      checkedOutAt: time,
      rawTime: time.toIso8601String(),
    );

void main() {
  group('buildName', () {
    test('joins both parts', () {
      expect(buildName('Ada', 'Lovelace'), 'Ada Lovelace');
    });

    test('does not render a literal "null" when a part is missing', () {
      expect(buildName('Ada', null), 'Ada');
      expect(buildName(null, 'Lovelace'), 'Lovelace');
      expect(buildName('Ada', ''), 'Ada');
    });

    test('falls back to Unknown when nothing usable is present', () {
      expect(buildName(null, null), 'Unknown');
      expect(buildName('  ', ''), 'Unknown');
    });

    test('ignores non-string values', () {
      expect(buildName(42, 'Lovelace'), 'Lovelace');
    });
  });

  group('parseCheckouts', () {
    test('drops entries with no check-out time', () {
      final result = parseCheckouts(
        [entry(), entry(checkedOutAt: null)],
        onlyToday: false,
      );
      expect(result, hasLength(1));
    });

    test('drops entries with an unparseable time instead of throwing', () {
      final result = parseCheckouts(
        [entry(checkedOutAt: 'not-a-date'), entry()],
        onlyToday: false,
      );
      expect(result, hasLength(1));
    });

    test('drops malformed entries instead of throwing', () {
      final result = parseCheckouts(
        ['nonsense', <String, dynamic>{}, entry()],
        onlyToday: false,
      );
      expect(result, hasLength(1));
    });

    test('keeps every day when onlyToday is off', () {
      final result = parseCheckouts(
        [
          entry(checkedOutAt: localAt(2026, 9, 16).toIso8601String()),
          entry(checkedOutAt: localAt(2026, 9, 15).toIso8601String()),
        ],
        onlyToday: false,
        now: localAt(2026, 9, 16),
      );
      expect(result, hasLength(2));
    });

    test('keeps only the current local day when onlyToday is on', () {
      final result = parseCheckouts(
        [
          entry(checkedOutAt: localAt(2026, 9, 16, 9).toIso8601String()),
          entry(checkedOutAt: localAt(2026, 9, 15, 23).toIso8601String()),
          entry(checkedOutAt: localAt(2026, 9, 17, 1).toIso8601String()),
        ],
        onlyToday: true,
        now: localAt(2026, 9, 16),
      );
      expect(result, hasLength(1));
      expect(result.single.checkedOutAt.day, 16);
    });

    test('includes the first and last moment of today', () {
      final result = parseCheckouts(
        [
          entry(checkedOutAt: localAt(2026, 9, 16, 0).toIso8601String()),
          entry(checkedOutAt: localAt(2026, 9, 16, 23).toIso8601String()),
        ],
        onlyToday: true,
        now: localAt(2026, 9, 16),
      );
      expect(result, hasLength(2));
    });
  });

  group('sortCheckouts by time', () {
    // These months are deliberately chosen so that alphabetical ordering of the
    // formatted string ("Apr", "Feb", "Jan") disagrees with chronological
    // ordering -- the bug this sort replaced.
    final jan = checkout('Carol', localAt(2026, 1, 5));
    final feb = checkout('Alice', localAt(2026, 2, 5));
    final apr = checkout('Bob', localAt(2026, 4, 5));

    test('ascending is chronological, not alphabetical by month name', () {
      final sorted = sortCheckouts(
        [apr, jan, feb],
        CheckoutSort.checkedOutAt,
        ascending: true,
      );
      expect(sorted.map((c) => c.name), ['Carol', 'Alice', 'Bob']);
    });

    test('descending is reverse chronological', () {
      final sorted = sortCheckouts(
        [jan, apr, feb],
        CheckoutSort.checkedOutAt,
        ascending: false,
      );
      expect(sorted.map((c) => c.name), ['Bob', 'Alice', 'Carol']);
    });

    test('orders times within one day correctly across the 12-hour boundary', () {
      final nine = checkout('Nine', localAt(2026, 3, 2, 9));
      final ten = checkout('Ten', localAt(2026, 3, 2, 10));
      final sorted = sortCheckouts(
        [ten, nine],
        CheckoutSort.checkedOutAt,
        ascending: true,
      );
      expect(sorted.map((c) => c.name), ['Nine', 'Ten']);
    });

    test('leaves the input list untouched', () {
      final input = [apr, jan, feb];
      sortCheckouts(input, CheckoutSort.checkedOutAt, ascending: true);
      expect(input.map((c) => c.name), ['Bob', 'Carol', 'Alice']);
    });
  });

  group('sortCheckouts by name', () {
    final time = localAt(2026, 5, 5);

    test('is case-insensitive and ascending', () {
      final sorted = sortCheckouts(
        [checkout('bravo', time), checkout('Alpha', time)],
        CheckoutSort.name,
        ascending: true,
      );
      expect(sorted.map((c) => c.name), ['Alpha', 'bravo']);
    });

    test('reverses when descending', () {
      final sorted = sortCheckouts(
        [checkout('Alpha', time), checkout('bravo', time)],
        CheckoutSort.name,
        ascending: false,
      );
      expect(sorted.map((c) => c.name), ['bravo', 'Alpha']);
    });
  });

  group('Checkout.key', () {
    test('distinguishes same name at different times', () {
      final a = checkout('Ada', localAt(2026, 9, 16, 9));
      final b = checkout('Ada', localAt(2026, 9, 16, 10));
      expect(a.key, isNot(b.key));
    });

    test('matches for the same person and time', () {
      final time = localAt(2026, 9, 16, 9);
      expect(checkout('Ada', time).key, checkout('Ada', time).key);
    });
  });

  group('Checkout.initials', () {
    final time = localAt(2026, 5, 5);

    test('uses first and last name', () {
      expect(checkout('Ada Lovelace', time).initials, 'AL');
    });

    test('uses first and last of three parts', () {
      expect(checkout('Ada King Lovelace', time).initials, 'AL');
    });

    test('handles a single name', () {
      expect(checkout('Ada', time).initials, 'A');
    });

    test('handles the Unknown fallback', () {
      expect(checkout('Unknown', time).initials, 'U');
    });

    test('does not split a multi-byte grapheme', () {
      expect(checkout('Emoji', time).initials, 'E');
      expect(checkout('Ada Lovelace', time).initials.length, 2);
    });
  });

  group('relativeTime', () {
    final now = localAt(2026, 9, 16, 12);

    test('reads as just now under a minute', () {
      expect(relativeTime(now.subtract(const Duration(seconds: 30)), now: now),
          'just now');
    });

    test('reads in minutes under an hour', () {
      expect(relativeTime(now.subtract(const Duration(minutes: 5)), now: now),
          '5 min ago');
    });

    test('singularises one hour', () {
      expect(relativeTime(now.subtract(const Duration(minutes: 75)), now: now),
          '1 hour ago');
    });

    test('reads in hours under a day', () {
      expect(relativeTime(now.subtract(const Duration(hours: 5)), now: now),
          '5 hours ago');
    });

    test('reads as yesterday, then days, then a date', () {
      expect(relativeTime(now.subtract(const Duration(days: 1)), now: now),
          'yesterday');
      expect(relativeTime(now.subtract(const Duration(days: 3)), now: now),
          '3 days ago');
      expect(relativeTime(localAt(2026, 1, 4), now: now), 'Jan 4');
    });

    test('does not produce a negative label for clock skew', () {
      expect(relativeTime(now.add(const Duration(minutes: 2)), now: now),
          'just now');
    });
  });

  group('isSameLocalDay', () {
    test('true within a day, false across midnight', () {
      expect(
        isSameLocalDay(localAt(2026, 9, 16, 0), localAt(2026, 9, 16, 23)),
        isTrue,
      );
      expect(
        isSameLocalDay(localAt(2026, 9, 16, 23), localAt(2026, 9, 17, 0)),
        isFalse,
      );
    });
  });
}
