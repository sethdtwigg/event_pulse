import 'package:intl/intl.dart';

/// Columns the check-out table can be sorted by.
enum CheckoutSort { name, checkedOutAt }

final DateFormat _displayFormat = DateFormat('MMM d y, h:mm a');

/// A single checked-out person, with the check-out time kept as a real
/// [DateTime] so it can be sorted and compared correctly. The formatted string
/// is derived for display only -- sorting on it would order by month *name*.
class Checkout {
  const Checkout({
    required this.name,
    required this.checkedOutAt,
    required this.rawTime,
  });

  final String name;
  final DateTime checkedOutAt;
  final String rawTime;

  String get formattedTime => _displayFormat.format(checkedOutAt);

  /// Stable identity for "is this row new since the last poll?".
  String get key => '$rawTime|$name';

  /// Builds a [Checkout] from one `data` entry of the check-ins API.
  /// Returns null when the entry has no usable check-out timestamp.
  static Checkout? fromApi(dynamic entry) {
    if (entry is! Map) return null;
    final attrs = entry['attributes'];
    if (attrs is! Map) return null;

    final rawTime = attrs['checked_out_at'];
    if (rawTime is! String || rawTime.isEmpty) return null;

    final parsed = DateTime.tryParse(rawTime);
    if (parsed == null) return null;

    return Checkout(
      name: buildName(attrs['first_name'], attrs['last_name']),
      checkedOutAt: parsed.toLocal(),
      rawTime: rawTime,
    );
  }
}

/// Joins name parts without rendering a literal "null" when one is missing.
String buildName(dynamic firstName, dynamic lastName) {
  final parts = [firstName, lastName]
      .map((part) => part is String ? part.trim() : '')
      .where((part) => part.isNotEmpty);
  final name = parts.join(' ');
  return name.isEmpty ? 'Unknown' : name;
}

/// True when [a] and [b] fall on the same day in local time.
bool isSameLocalDay(DateTime a, DateTime b) {
  final localA = a.toLocal();
  final localB = b.toLocal();
  return localA.year == localB.year &&
      localA.month == localB.month &&
      localA.day == localB.day;
}

/// Converts the API's `data` array into checkouts, dropping unusable entries
/// and, when [onlyToday] is set, anything not from the current local day.
List<Checkout> parseCheckouts(
  List<dynamic> data, {
  required bool onlyToday,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final checkouts = <Checkout>[];

  for (final entry in data) {
    final checkout = Checkout.fromApi(entry);
    if (checkout == null) continue;
    if (onlyToday && !isSameLocalDay(checkout.checkedOutAt, today)) continue;
    checkouts.add(checkout);
  }

  return checkouts;
}

/// Comparator for the table. Times compare as instants, not as display strings.
int compareCheckouts(
  Checkout a,
  Checkout b,
  CheckoutSort sortBy, {
  required bool ascending,
}) {
  final int result;
  switch (sortBy) {
    case CheckoutSort.name:
      result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    case CheckoutSort.checkedOutAt:
      result = a.checkedOutAt.compareTo(b.checkedOutAt);
  }
  return ascending ? result : -result;
}

/// Returns a new list sorted by [sortBy]; the input is left untouched.
List<Checkout> sortCheckouts(
  List<Checkout> checkouts,
  CheckoutSort sortBy, {
  required bool ascending,
}) {
  final sorted = [...checkouts];
  sorted.sort((a, b) => compareCheckouts(a, b, sortBy, ascending: ascending));
  return sorted;
}
