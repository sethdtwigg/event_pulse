import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'api_credentials.dart';
import 'checkout.dart';
import 'planning_center_api.dart';

const int minPollInterval = 1;
const int maxPollInterval = 3600;

void main() => runApp(const CheckoutsApp());

class CheckoutsApp extends StatelessWidget {
  const CheckoutsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Checkouts Viewer',
      home: const CheckoutsScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class CheckoutsScreen extends StatefulWidget {
  const CheckoutsScreen({super.key});

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

  /// Keys seen on the previous successful poll, used to highlight arrivals.
  /// Seeded on the first load of an event so the initial fetch does not light
  /// up every row.
  Set<String> _knownKeys = {};
  Set<String> _newKeys = {};
  bool _hasLoadedEvent = false;

  Timer? _countdownTimer;
  int pollInterval = 5;
  int countdown = 5;
  int resultLimit = maxPerPage;
  bool onlyToday = false;
  bool keepAwake = true;

  bool _isFetching = false;
  bool _isRefreshing = false;
  bool _loadingEvents = false;
  String? _errorMessage;
  DateTime? _lastUpdated;

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
        _newKeys = _hasLoadedEvent ? currentKeys.difference(_knownKeys) : {};
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

  void _onEventChanged(String? value) {
    setState(() {
      selectedEventId = value;
      checkedOutPeople = [];
      _knownKeys = {};
      _newKeys = {};
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

  void _openSettings() {
    showDialog(
      context: context,
      builder: (_) => SettingsDialog(
        pollInterval: pollInterval,
        resultLimit: resultLimit,
        onlyToday: onlyToday,
        keepAwake: keepAwake,
        onApply: (newInterval, newLimit, newOnlyToday, newKeepAwake) {
          final awakeChanged = newKeepAwake != keepAwake;
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

  @override
  Widget build(BuildContext context) {
    if (!ApiCredentials.isConfigured) {
      return Scaffold(
        appBar: AppBar(title: const Text('Checked Out Individuals')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Planning Center credentials are not set.\n\n'
              'Copy secrets.example.json to secrets.json, fill in PCO_APP_ID '
              'and PCO_SECRET, then launch with:\n\n'
              'flutter run --dart-define-from-file=secrets.json',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Checked Out Individuals'),
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
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'settings') _openSettings();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_errorMessage != null) _buildErrorBanner(),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: selectedEventId,
                    hint: Text(
                      _loadingEvents ? 'Loading events...' : 'Select an event',
                    ),
                    onChanged: _onEventChanged,
                    items: events
                        .map(
                          (event) => DropdownMenuItem<String>(
                            value: event.id,
                            child: Text(event.name),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
              Expanded(child: Center(child: _buildBody())),
            ],
          ),
          Positioned(
            bottom: 4,
            right: 16,
            child: Opacity(
              opacity: 0.4,
              child: Text(
                _statusLine(),
                style:
                    const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _statusLine() {
    final updated = _lastUpdated;
    final refreshing = 'Refreshing in $countdown...';
    if (updated == null) return refreshing;
    return 'Updated ${DateFormat('h:mm:ss a').format(updated)} - $refreshing';
  }

  Widget _buildErrorBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _errorMessage!,
                style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
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
    if (selectedEventId == null) {
      return Text(
        _loadingEvents ? 'Loading events...' : 'Select an event to begin.',
        style: const TextStyle(color: Colors.black54),
      );
    }

    if (!_hasLoadedEvent && _errorMessage == null) {
      return const CircularProgressIndicator();
    }

    if (checkedOutPeople.isEmpty) {
      return Text(
        onlyToday
            ? 'No check-outs today for this event.'
            : 'No check-outs for this event.',
        style: const TextStyle(color: Colors.black54),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          sortColumnIndex: sortBy == CheckoutSort.name ? 0 : 1,
          sortAscending: sortAsc,
          columns: [
            DataColumn(
              label: const Text('Name'),
              onSort: (_, __) => _onSort(CheckoutSort.name),
            ),
            DataColumn(
              label: const Text('Checked Out At'),
              onSort: (_, __) => _onSort(CheckoutSort.checkedOutAt),
            ),
          ],
          rows: checkedOutPeople.map((person) {
            return DataRow(
              color: _newKeys.contains(person.key)
                  ? WidgetStateProperty.all(Colors.yellow[100])
                  : null,
              cells: [
                DataCell(Text(person.name)),
                DataCell(Text(person.formattedTime)),
              ],
            );
          }).toList(),
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
  final void Function(
    int newInterval,
    int newLimit,
    bool onlyToday,
    bool keepAwake,
  ) onApply;

  const SettingsDialog({
    super.key,
    required this.pollInterval,
    required this.resultLimit,
    required this.onlyToday,
    required this.keepAwake,
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

  @override
  void initState() {
    super.initState();
    _pollController =
        TextEditingController(text: widget.pollInterval.toString());
    _limitController =
        TextEditingController(text: widget.resultLimit.toString());
    _onlyToday = widget.onlyToday;
    _keepAwake = widget.keepAwake;
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
        width: 340,
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
            const SizedBox(height: 12),
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
            final newLimit =
                (int.tryParse(_limitController.text.trim()) ?? widget.resultLimit)
                    .clamp(1, maxPerPage)
                    .toInt();
            widget.onApply(newInterval, newLimit, _onlyToday, _keepAwake);
            Navigator.pop(context);
          },
          child: const Text('Apply'),
        )
      ],
    );
  }
}
