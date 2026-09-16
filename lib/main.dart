import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'api_credentials.dart';
import 'checkout.dart';
import 'planning_center_api.dart';
import 'theme.dart';

const int minPollInterval = 1;
const int maxPollInterval = 3600;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Resolved before the first frame so a saved dark theme does not start with
  // a flash of light, which is exactly what you would notice on a wall display
  // in a dim room.
  final prefs = await SharedPreferences.getInstance();
  runApp(
    CheckoutsApp(
      initialThemeMode: themeModeFromName(prefs.getString('themeMode')),
    ),
  );
}

/// Owns the theme mode, because [MaterialApp] is what applies it and the
/// setting that changes it lives further down the tree.
class CheckoutsApp extends StatefulWidget {
  const CheckoutsApp({super.key, this.initialThemeMode = ThemeMode.system});

  final ThemeMode initialThemeMode;

  @override
  State<CheckoutsApp> createState() => _CheckoutsAppState();
}

class _CheckoutsAppState extends State<CheckoutsApp> {
  late ThemeMode _themeMode = widget.initialThemeMode;

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('themeMode', themeModeName(mode));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Event Pulse',
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: _themeMode,
      home: CheckoutsScreen(
        themeMode: _themeMode,
        onThemeModeChanged: _setThemeMode,
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}

class CheckoutsScreen extends StatefulWidget {
  const CheckoutsScreen({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<CheckoutsScreen> createState() => _CheckoutsScreenState();
}

class _CheckoutsScreenState extends State<CheckoutsScreen> {
  final PlanningCenterApi _api = PlanningCenterApi();

  String? selectedEventId;
  List<Checkout> checkedOutPeople = [];
  List<PcoEvent> events = [];

  CheckoutSort sortBy = CheckoutSort.checkedOutAt;
  bool sortAsc = false;

  /// Keys present on the previous successful poll, used to detect arrivals.
  /// Seeded on an event's first load so the initial fetch does not light up
  /// every row.
  Set<String> _knownKeys = {};

  /// When each currently-listed arrival was first seen, so the highlight can
  /// fade out on its own instead of vanishing after exactly one poll.
  final Map<String, DateTime> _firstSeen = {};
  bool _hasLoadedEvent = false;

  Timer? _countdownTimer;
  int pollInterval = 5;
  int countdown = 5;
  int resultLimit = maxPerPage;
  bool onlyToday = false;
  bool keepAwake = true;
  bool displayMode = false;

  bool _isFetching = false;
  bool _isRefreshing = false;
  bool _loadingEvents = false;
  String? _errorMessage;
  DateTime? _lastUpdated;

  /// Type and spacing multiplier. Display mode is meant to be read from across
  /// a room rather than from a desk.
  double get _scale => displayMode ? 1.6 : 1.0;

  @override
  void initState() {
    super.initState();
    if (!ApiCredentials.isConfigured) return;
    _initialize();
  }

  /// Preferences are awaited before the timer starts so a saved poll interval
  /// takes effect on the very first cycle instead of after one default-length
  /// countdown.
  Future<void> _initialize() async {
    await _loadPreferences();
    await _applyWakelock();
    await _fetchEvents();
    if (!mounted) return;
    _startTimers();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      pollInterval = _clampInterval(prefs.getInt('pollInterval') ?? 5);
      resultLimit = _clampLimit(prefs.getInt('resultLimit') ?? maxPerPage);
      onlyToday = prefs.getBool('onlyToday') ?? false;
      keepAwake = prefs.getBool('keepAwake') ?? true;
      displayMode = prefs.getBool('displayMode') ?? false;
      selectedEventId = prefs.getString('selectedEventId');
      countdown = pollInterval;
    });
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pollInterval', pollInterval);
    await prefs.setInt('resultLimit', resultLimit);
    await prefs.setBool('onlyToday', onlyToday);
    await prefs.setBool('keepAwake', keepAwake);
    await prefs.setBool('displayMode', displayMode);
    final eventId = selectedEventId;
    if (eventId == null) {
      await prefs.remove('selectedEventId');
    } else {
      await prefs.setString('selectedEventId', eventId);
    }
  }

  /// Wakelock is unsupported on some desktop and web targets, where the plugin
  /// throws rather than no-opping. A display that stays on is a nicety, so a
  /// failure here must not take the app down.
  Future<void> _applyWakelock() async {
    try {
      await WakelockPlus.toggle(enable: keepAwake);
    } catch (e) {
      dev.log('Wakelock unavailable on this platform',
          name: 'CheckInAPI', error: e);
    }
  }

  int _clampInterval(int value) =>
      value.clamp(minPollInterval, maxPollInterval).toInt();

  int _clampLimit(int value) => value.clamp(1, maxPerPage).toInt();

  void _startTimers() {
    _countdownTimer?.cancel();
    setState(() => countdown = pollInterval);

    // The one-second tick also drives the arrival highlight fading out.
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (countdown <= 1) {
        setState(() => countdown = pollInterval);
        _fetchCheckouts();
      } else {
        setState(() => countdown--);
      }
    });
  }

  Future<void> _fetchEvents() async {
    setState(() => _loadingEvents = true);
    try {
      final fetched = await _api.fetchEvents();
      if (!mounted) return;

      // Drop a remembered event that no longer exists, otherwise the dropdown
      // would be handed a value that is not among its items.
      final ids = fetched.map((e) => e.id).toSet();
      final remembered = selectedEventId;
      final stillValid = remembered != null && ids.contains(remembered);

      setState(() {
        events = fetched;
        if (!stillValid) selectedEventId = null;
        _errorMessage = null;
      });

      if (stillValid) await _fetchCheckouts();
    } on ApiException catch (e) {
      dev.log('Failed to fetch events', name: 'CheckInAPI', error: e.message);
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } catch (e, stack) {
      dev.log('Exception during fetchEvents',
          name: 'CheckInAPI', error: e, stackTrace: stack);
      if (!mounted) return;
      setState(() => _errorMessage = 'Could not load events.');
    } finally {
      if (mounted) setState(() => _loadingEvents = false);
    }
  }

  Future<void> _fetchCheckouts() async {
    final eventId = selectedEventId;
    // A slow response must not stack up behind a short poll interval.
    if (eventId == null || _isFetching) return;

    _isFetching = true;
    try {
      final data =
          await _api.fetchCheckIns(eventId: eventId, limit: resultLimit);
      final parsed = sortCheckouts(
        parseCheckouts(data, onlyToday: onlyToday),
        sortBy,
        ascending: sortAsc,
      );
      if (!mounted) return;

      final currentKeys = parsed.map((c) => c.key).toSet();
      setState(() {
        if (_hasLoadedEvent) {
          final now = DateTime.now();
          for (final key in currentKeys.difference(_knownKeys)) {
            _firstSeen[key] = now;
          }
        }
        // Keep the map bounded to what is actually on screen.
        _firstSeen.removeWhere((key, _) => !currentKeys.contains(key));

        _knownKeys = currentKeys;
        _hasLoadedEvent = true;
        checkedOutPeople = parsed;
        _lastUpdated = DateTime.now();
        _errorMessage = null;
      });
    } on ApiException catch (e) {
      dev.log('Failed to fetch checkouts',
          name: 'CheckInAPI', error: e.message);
      if (mounted) setState(() => _errorMessage = e.message);
    } catch (e, stack) {
      dev.log('Exception during fetchCheckouts',
          name: 'CheckInAPI', error: e, stackTrace: stack);
      if (mounted) setState(() => _errorMessage = 'Could not load check-outs.');
    } finally {
      _isFetching = false;
    }
  }

  /// Manual refresh, and the recovery path when the initial event load failed.
  Future<void> _refreshAll() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      await _fetchEvents();
      if (!mounted) return;
      _startTimers();
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  bool _isNew(String key) {
    final seen = _firstSeen[key];
    if (seen == null) return false;
    return DateTime.now().difference(seen) < highlightDuration;
  }

  void _onEventChanged(String? value) {
    setState(() {
      selectedEventId = value;
      checkedOutPeople = [];
      _knownKeys = {};
      _firstSeen.clear();
      _hasLoadedEvent = false;
      _errorMessage = null;
      _lastUpdated = null;
    });
    _savePreferences();
    _fetchCheckouts();
  }

  void _onSort(CheckoutSort column) {
    setState(() {
      if (sortBy == column) {
        sortAsc = !sortAsc;
      } else {
        sortBy = column;
        // Names read best A-Z; times read best newest-first.
        sortAsc = column == CheckoutSort.name;
      }
      checkedOutPeople =
          sortCheckouts(checkedOutPeople, sortBy, ascending: sortAsc);
    });
  }

  void _toggleDisplayMode() {
    setState(() => displayMode = !displayMode);
    _savePreferences();
  }

  void _openSettings() {
    showDialog(
      context: context,
      builder: (_) => SettingsDialog(
        pollInterval: pollInterval,
        resultLimit: resultLimit,
        onlyToday: onlyToday,
        keepAwake: keepAwake,
        themeMode: widget.themeMode,
        onApply: (
          newInterval,
          newLimit,
          newOnlyToday,
          newKeepAwake,
          newThemeMode,
        ) {
          final awakeChanged = newKeepAwake != keepAwake;
          if (newThemeMode != widget.themeMode) {
            widget.onThemeModeChanged(newThemeMode);
          }
          setState(() {
            pollInterval = newInterval;
            resultLimit = newLimit;
            onlyToday = newOnlyToday;
            keepAwake = newKeepAwake;
          });
          _savePreferences();
          if (awakeChanged) _applyWakelock();
          _startTimers();
          // Apply the new settings now instead of after a full countdown.
          _fetchCheckouts();
        },
      ),
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _api.dispose();
    WakelockPlus.toggle(enable: false).catchError((Object _) {});
    super.dispose();
  }

  String? get _selectedEventName {
    final id = selectedEventId;
    if (id == null) return null;
    for (final event in events) {
      if (event.id == id) return event.name;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (!ApiCredentials.isConfigured) return const _CredentialsMissingScreen();

    return Scaffold(
      appBar: displayMode ? null : _buildAppBar(),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                if (_errorMessage != null) _buildErrorBanner(),
                _buildHeader(),
                const Divider(),
                Expanded(child: _buildBody()),
                _buildFooter(),
              ],
            ),
            if (displayMode)
              Positioned(
                top: 4,
                right: 4,
                child: Opacity(
                  opacity: 0.35,
                  child: IconButton(
                    tooltip: 'Exit display mode',
                    onPressed: _toggleDisplayMode,
                    icon: const Icon(Icons.fullscreen_exit),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: const Text('Event Pulse'),
      actions: [
        IconButton(
          tooltip: 'Refresh now',
          onPressed: _isRefreshing ? null : _refreshAll,
          icon: _isRefreshing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Display mode',
          onPressed: _toggleDisplayMode,
          icon: const Icon(Icons.fullscreen),
        ),
        PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'settings') _openSettings();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'settings', child: Text('Settings')),
          ],
        ),
      ],
    );
  }

  Widget _buildHeader() {
    final scheme = Theme.of(context).colorScheme;
    final eventName = _selectedEventName;

    return Padding(
      padding: EdgeInsets.fromLTRB(20 * _scale, 12 * _scale, 20 * _scale, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: displayMode
                ? Text(
                    eventName ?? 'Event Pulse',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 26 * _scale,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  )
                : _buildEventSelector(),
          ),
          SizedBox(width: 16 * _scale),
          _buildCountBadge(),
        ],
      ),
    );
  }

  Widget _buildEventSelector() {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: selectedEventId,
          borderRadius: BorderRadius.circular(12),
          hint: Text(_loadingEvents ? 'Loading events...' : 'Select an event'),
          style: TextStyle(fontSize: 18, color: scheme.onSurface),
          onChanged: _onEventChanged,
          items: events
              .map(
                (event) => DropdownMenuItem<String>(
                  value: event.id,
                  child: Text(event.name, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _buildCountBadge() {
    final scheme = Theme.of(context).colorScheme;
    final count = checkedOutPeople.length;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 16 * _scale,
        vertical: 8 * _scale,
      ),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$count',
            style: TextStyle(
              fontSize: 22 * _scale,
              fontWeight: FontWeight.w700,
              color: scheme.onPrimaryContainer,
            ),
          ),
          SizedBox(width: 8 * _scale),
          Text(
            'checked out',
            style: TextStyle(
              fontSize: 13 * _scale,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    final scheme = Theme.of(context).colorScheme;
    final updated = _lastUpdated;

    return Padding(
      padding: EdgeInsets.fromLTRB(20 * _scale, 8, 20 * _scale, 10),
      child: Row(
        children: [
          if (!displayMode && checkedOutPeople.isNotEmpty) ...[
            _buildSortButton('Name', CheckoutSort.name),
            const SizedBox(width: 4),
            _buildSortButton('Time', CheckoutSort.checkedOutAt),
          ],
          const Spacer(),
          Text(
            updated == null
                ? 'Refreshing in $countdown s'
                : 'Updated ${DateFormat('h:mm:ss a').format(updated)}  -  '
                    'refreshing in $countdown s',
            style: TextStyle(
              fontSize: 12 * _scale,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSortButton(String label, CheckoutSort column) {
    final scheme = Theme.of(context).colorScheme;
    final active = sortBy == column;

    return TextButton.icon(
      onPressed: () => _onSort(column),
      style: TextButton.styleFrom(
        foregroundColor: active ? scheme.primary : scheme.onSurfaceVariant,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        visualDensity: VisualDensity.compact,
      ),
      icon: Icon(
        active
            ? (sortAsc ? Icons.arrow_upward : Icons.arrow_downward)
            : Icons.unfold_more,
        size: 16,
      ),
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }

  Widget _buildErrorBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 20, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _errorMessage!,
                style: TextStyle(color: scheme.onErrorContainer, fontSize: 14),
              ),
            ),
            TextButton(
              onPressed: _isRefreshing ? null : _refreshAll,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final scheme = Theme.of(context).colorScheme;

    if (selectedEventId == null) {
      return _buildPlaceholder(
        icon: Icons.event_outlined,
        message:
            _loadingEvents ? 'Loading events...' : 'Select an event to begin.',
      );
    }

    if (!_hasLoadedEvent && _errorMessage == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (checkedOutPeople.isEmpty) {
      return _buildPlaceholder(
        icon: Icons.check_circle_outline,
        message: onlyToday
            ? 'No check-outs today for this event.'
            : 'No check-outs for this event.',
      );
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(16 * _scale, 8, 16 * _scale, 8),
      itemCount: checkedOutPeople.length,
      itemBuilder: (context, index) =>
          _buildPersonRow(checkedOutPeople[index], scheme),
    );
  }

  Widget _buildPlaceholder({required IconData icon, required String message}) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48 * _scale, color: scheme.outline),
          SizedBox(height: 16 * _scale),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16 * _scale,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersonRow(Checkout person, ColorScheme scheme) {
    final isNew = _isNew(person.key);
    final background =
        isNew ? newArrivalColor(scheme) : scheme.surfaceContainerHighest;
    final foreground = isNew ? onNewArrivalColor(scheme) : scheme.onSurface;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOut,
      margin: EdgeInsets.only(bottom: 8 * _scale),
      padding: EdgeInsets.symmetric(
        horizontal: 16 * _scale,
        vertical: 12 * _scale,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isNew ? scheme.tertiary : Colors.transparent,
          width: 2,
        ),
      ),
      // In display mode the name is the whole point, so it gets the full width
      // of the card and room to wrap rather than competing with an avatar, two
      // timestamps and a badge. Arrivals still read as new from the card colour.
      child: displayMode
          ? Text(
              person.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w600,
                height: 1.15,
                color: foreground,
              ),
            )
          : Row(
              children: [
                CircleAvatar(
                  radius: 22 * _scale,
                  backgroundColor:
                      isNew ? scheme.tertiary : scheme.primaryContainer,
                  child: Text(
                    person.initials,
                    style: TextStyle(
                      fontSize: 16 * _scale,
                      fontWeight: FontWeight.w600,
                      color:
                          isNew ? scheme.onTertiary : scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                SizedBox(width: 16 * _scale),
                Expanded(
                  child: Text(
                    person.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 20 * _scale,
                      fontWeight: FontWeight.w600,
                      color: foreground,
                    ),
                  ),
                ),
                if (isNew) ...[
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 10 * _scale,
                      vertical: 4 * _scale,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.tertiary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'NEW',
                      style: TextStyle(
                        fontSize: 11 * _scale,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: scheme.onTertiary,
                      ),
                    ),
                  ),
                ],
                // Keeps a long name from butting up against the timestamp.
                SizedBox(width: 12 * _scale),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      relativeTime(person.checkedOutAt),
                      style: TextStyle(
                        fontSize: 15 * _scale,
                        fontWeight: FontWeight.w500,
                        color: foreground,
                      ),
                    ),
                    SizedBox(height: 2 * _scale),
                    Text(
                      person.formattedTime,
                      style: TextStyle(
                        fontSize: 12 * _scale,
                        color: isNew
                            ? onNewArrivalColor(scheme)
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _CredentialsMissingScreen extends StatelessWidget {
  const _CredentialsMissingScreen();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Event Pulse')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.key_off_outlined, size: 48, color: scheme.outline),
              const SizedBox(height: 20),
              Text(
                'Planning Center credentials are not set',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Copy secrets.example.json to secrets.json, fill in PCO_APP_ID '
                'and PCO_SECRET, then launch with:',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  'flutter run --dart-define-from-file=secrets.json',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsDialog extends StatefulWidget {
  final int pollInterval;
  final int resultLimit;
  final bool onlyToday;
  final bool keepAwake;
  final ThemeMode themeMode;
  final void Function(
    int newInterval,
    int newLimit,
    bool onlyToday,
    bool keepAwake,
    ThemeMode themeMode,
  ) onApply;

  const SettingsDialog({
    super.key,
    required this.pollInterval,
    required this.resultLimit,
    required this.onlyToday,
    required this.keepAwake,
    required this.themeMode,
    required this.onApply,
  });

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late TextEditingController _pollController;
  late TextEditingController _limitController;
  late bool _onlyToday;
  late bool _keepAwake;
  late ThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    _pollController =
        TextEditingController(text: widget.pollInterval.toString());
    _limitController =
        TextEditingController(text: widget.resultLimit.toString());
    _onlyToday = widget.onlyToday;
    _keepAwake = widget.keepAwake;
    _themeMode = widget.themeMode;
  }

  @override
  void dispose() {
    _pollController.dispose();
    _limitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              keyboardType: TextInputType.number,
              controller: _pollController,
              decoration: const InputDecoration(
                labelText: 'Poll Interval (sec)',
                helperText: 'Between $minPollInterval and $maxPollInterval',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              keyboardType: TextInputType.number,
              controller: _limitController,
              decoration: const InputDecoration(
                labelText: 'Result Limit',
                helperText: 'Between 1 and $maxPerPage (API maximum)',
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Only Today'),
              subtitle: const Text('Hide check-outs from previous days'),
              value: _onlyToday,
              onChanged: (value) => setState(() => _onlyToday = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep Screen Awake'),
              subtitle: const Text('For unattended displays'),
              value: _keepAwake,
              onChanged: (value) => setState(() => _keepAwake = value),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(child: Text('Theme')),
                DropdownButton<ThemeMode>(
                  value: _themeMode,
                  onChanged: (value) {
                    if (value != null) setState(() => _themeMode = value);
                  },
                  items: ThemeMode.values
                      .map(
                        (mode) => DropdownMenuItem(
                          value: mode,
                          child: Text(themeModeLabel(mode)),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            // Out-of-range or unparseable input is clamped rather than
            // accepted: an interval of 0 would otherwise fire a request on
            // every tick, and a limit above the API maximum would silently
            // return fewer rows than the user asked for.
            final newInterval = (int.tryParse(_pollController.text.trim()) ??
                    widget.pollInterval)
                .clamp(minPollInterval, maxPollInterval)
                .toInt();
            final newLimit = (int.tryParse(_limitController.text.trim()) ??
                    widget.resultLimit)
                .clamp(1, maxPerPage)
                .toInt();
            widget.onApply(
              newInterval,
              newLimit,
              _onlyToday,
              _keepAwake,
              _themeMode,
            );
            Navigator.pop(context);
          },
          child: const Text('Apply'),
        )
      ],
    );
  }
}
