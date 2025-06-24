import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final String apiBase = 'https://api.planningcenteronline.com/check-ins/v2';
  final String pat = base64.encode(utf8.encode('client:your_personal_access_token_here'));

  String? selectedEventId;
  List<Map<String, String>> checkedOutPeople = [];
  List<Map<String, String>> previousPeople = [];
  List<Map<String, String>> events = [];
  String sortBy = 'checked_out_at';
  bool sortAsc = false;

  Timer? _pollingTimer;
  Timer? _countdownTimer;
  int pollInterval = 5;
  int countdown = 5;
  int resultLimit = 100;
  bool onlyToday = false;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _fetchEvents();
    _startTimers();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      pollInterval = prefs.getInt('pollInterval') ?? 5;
      resultLimit = prefs.getInt('resultLimit') ?? 100;
      onlyToday = prefs.getBool('onlyToday') ?? false;
    });
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setInt('pollInterval', pollInterval);
    prefs.setInt('resultLimit', resultLimit);
    prefs.setBool('onlyToday', onlyToday);
  }

  void _startTimers() {
    _pollingTimer?.cancel();
    _countdownTimer?.cancel();

    countdown = pollInterval;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        countdown--;
        if (countdown <= 0) {
          _fetchCheckouts();
          countdown = pollInterval;
        }
      });
    });
  }

  Future<void> _fetchEvents() async {
    try {
      final response = await http.get(
        Uri.parse('$apiBase/events'),
        headers: {
          'Authorization': 'Basic $pat',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final body = json.decode(response.body);
        final List<dynamic> data = body['data'];

        setState(() {
          events = data.map<Map<String, String>>((e) {
            return {
              'id': e['id'],
              'title': e['attributes']['name']
            };
          }).toList();
        });
      }
    } catch (e, stack) {
      dev.log('Exception during fetchEvents',
          name: 'CheckInAPI', error: e, stackTrace: stack);
    }
  }

  Future<void> _fetchCheckouts() async {
    if (selectedEventId == null) return;

    try {
      final response = await http.get(
        Uri.parse(
          '$apiBase/check_ins?include=event,person,checked_out_by&order=-checked_out_at&where[event_id]=$selectedEventId&filter=checked_out&per_page=$resultLimit',
        ),
        headers: {
          'Authorization': 'Basic $pat',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final body = json.decode(response.body);
        final List<dynamic> checkIns = body['data'];

        final validCheckouts = checkIns.where((entry) {
          final timeStr = entry['attributes']['checked_out_at'];
          if (timeStr == null) return false;
          if (onlyToday) {
            final time = DateTime.parse(timeStr).toLocal();
            final now = DateTime.now();
            return time.year == now.year && time.month == now.month && time.day == now.day;
          }
          return true;
        }).map<Map<String, String>>((entry) {
          final attrs = entry['attributes'];
          final formattedTime = attrs['checked_out_at'] != null
              ? DateFormat('MMM d y, h:mm a').format(
                  DateTime.parse(attrs['checked_out_at']).toLocal(),
                )
              : '';

          return {
            'name': '${attrs['first_name']} ${attrs['last_name']}',
            'checked_out_at': formattedTime,
            'raw_time': attrs['checked_out_at'] ?? '',
          };
        }).toList();

        setState(() {
          previousPeople = checkedOutPeople;
          checkedOutPeople = validCheckouts;
        });
      } else {
        dev.log('Failed to fetch checkouts',
            name: 'CheckInAPI',
            error: response.statusCode,
            stackTrace: StackTrace.current);
        dev.log('Response body', name: 'CheckInAPI', error: response.body);
      }
    } catch (e, stack) {
      dev.log('Exception during fetchCheckouts',
          name: 'CheckInAPI', error: e, stackTrace: stack);
    }
  }

  void _onSort(String column) {
    setState(() {
      if (sortBy == column) {
        sortAsc = !sortAsc;
      } else {
        sortBy = column;
        sortAsc = true;
      }

      checkedOutPeople.sort((a, b) {
        final aVal = a[column] ?? '';
        final bVal = b[column] ?? '';
        return sortAsc ? aVal.compareTo(bVal) : bVal.compareTo(aVal);
      });
    });
  }

  bool _isNew(Map<String, String> person) {
    return !previousPeople.any((p) => p['name'] == person['name'] && p['raw_time'] == person['raw_time']);
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Checked Out Individuals'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'settings') {
                showDialog(
                  context: context,
                  builder: (_) => SettingsDialog(
                    pollInterval: pollInterval,
                    resultLimit: resultLimit,
                    onlyToday: onlyToday,
                    onApply: (newInterval, newLimit, newOnlyToday) {
                      setState(() {
                        pollInterval = newInterval;
                        resultLimit = newLimit;
                        onlyToday = newOnlyToday;
                        countdown = newInterval;
                        _startTimers();
                        _savePreferences();
                      });
                    },
                  ),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 300),
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: selectedEventId,
                      hint: const Text('Select an event'),
                      onChanged: (value) {
                        setState(() {
                          selectedEventId = value;
                          checkedOutPeople = [];
                          previousPeople = [];
                        });
						            _fetchCheckouts();
                      },
                      items: events.map((event) {
                        return DropdownMenuItem<String>(
                          value: event['id'],
                          child: Text(event['title'] ?? 'Untitled'),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                if (checkedOutPeople.isNotEmpty)
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.vertical,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            sortColumnIndex: sortBy == 'name' ? 0 : 1,
                            sortAscending: sortAsc,
                            columns: [
                              DataColumn(
                                label: const Text('Name'),
                                onSort: (_, __) => _onSort('name'),
                              ),
                              DataColumn(
                                label: const Text('Checked Out At'),
                                onSort: (_, __) => _onSort('checked_out_at'),
                              ),
                            ],
                            rows: checkedOutPeople.map((person) {
                              return DataRow(
                                color: _isNew(person)
                                    ? WidgetStateProperty.all(Colors.yellow[100])
                                    : null,
                                cells: [
                                  DataCell(Text(person['name'] ?? '')),
                                  DataCell(Text(person['checked_out_at'] ?? '')),
                                ],
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            bottom: 4,
            right: 16,
            child: Opacity(
              opacity: 0.4,
              child: Text(
                'Refreshing in $countdown...',
                style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsDialog extends StatefulWidget {
  final int pollInterval;
  final int resultLimit;
  final bool onlyToday;
  final void Function(int newInterval, int newLimit, bool onlyToday) onApply;

  const SettingsDialog({
    super.key,
    required this.pollInterval,
    required this.resultLimit,
    required this.onlyToday,
    required this.onApply,
  });

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late TextEditingController _pollController;
  late TextEditingController _limitController;
  late String _onlyTodaySetting;

  @override
  void initState() {
    super.initState();
    _pollController = TextEditingController(text: widget.pollInterval.toString());
    _limitController = TextEditingController(text: widget.resultLimit.toString());
    _onlyTodaySetting = widget.onlyToday ? 'YES' : 'NO';
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
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text('Poll Interval (sec):'),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  keyboardType: TextInputType.number,
                  controller: _pollController,
                ),
              )
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('Result Limit:'),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  keyboardType: TextInputType.number,
                  controller: _limitController,
                ),
              )
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('Only Today:'),
              const SizedBox(width: 10),
              DropdownButton<String>(
                value: _onlyTodaySetting,
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _onlyTodaySetting = value;
                    });
                  }
                },
                items: ['YES', 'NO'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
              )
            ],
          )
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final newInterval = int.tryParse(_pollController.text) ?? widget.pollInterval;
            final newLimit = int.tryParse(_limitController.text) ?? widget.resultLimit;
            final newOnlyToday = _onlyTodaySetting == 'YES';
            widget.onApply(newInterval, newLimit, newOnlyToday);
            Navigator.pop(context);
          },
          child: const Text('Apply'),
        )
      ],
    );
  }
}
