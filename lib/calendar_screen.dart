import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:easy_localization/easy_localization.dart';
import 'matrix_service.dart';
import 'session_manager.dart';

class CalendarEvent {
  final String title;
  final String schoolDate;
  final String description;
  final int schoolId;

  CalendarEvent({
    required this.title,
    required this.schoolDate,
    required this.description,
    required this.schoolId,
  });

  factory CalendarEvent.fromJson(Map<String, dynamic> json) {
    return CalendarEvent(
      title: json['title'] ?? '',
      schoolDate: json['school_date'] ?? '',
      description: json['description'] ?? '',
      schoolId: json['school_id'] is int
          ? json['school_id']
          : int.tryParse(json['school_id'].toString()) ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'school_date': schoolDate,
      'description': description,
      'school_id': schoolId,
    };
  }
}

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({Key? key}) : super(key: key);

  @override
  _CalendarScreenState createState() => _CalendarScreenState();
}

enum SchoolType { elementary, highschool, both, none }

class _CalendarScreenState extends State<CalendarScreen> with TickerProviderStateMixin {
  SchoolType _selectedSchool = SchoolType.none;
  SchoolType _userSchoolType = SchoolType.none;
  List<CalendarEvent> _events = [];
  bool _loading = true;
  String? _error;

  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  @override
  void initState() {
    super.initState();
    _restoreSessionAndLoadData();
    _selectedDay = DateTime.now();
  }

  Future<void> _restoreSessionAndLoadData() async {
    await SessionManager.restoreSession();
    await _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    await _loadCachedEvents();
    await _fetchUserSchoolType();
  }

  Future<void> _loadCachedEvents() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedEventsJson = prefs.getString('calendar_events');
    if (cachedEventsJson != null) {
      try {
        final List decoded = jsonDecode(cachedEventsJson);
        setState(() {
          _events = decoded.map((e) => CalendarEvent.fromJson(e)).toList();
        });
      } catch (e) {
        // If cached data is corrupt, ignore and continue
      }
    }
  }

  Future<void> _saveEventsToCache(List<CalendarEvent> events) async {
    final prefs = await SharedPreferences.getInstance();
    final List<Map<String, dynamic>> eventsJson = events.map((e) => e.toJson()).toList();
    await prefs.setString('calendar_events', jsonEncode(eventsJson));
  }

  Map<String, String> _buildAuthHeaders() {
    final headers = <String, String>{};
    if (SessionManager.rocketchatAuthToken != null && SessionManager.rocketchatAuthToken!.isNotEmpty) {
      headers['X-Auth-Token'] = SessionManager.rocketchatAuthToken!;
    }
    if (SessionManager.rocketchatUserId != null && SessionManager.rocketchatUserId!.isNotEmpty) {
      headers['X-User-Id'] = SessionManager.rocketchatUserId!;
    }
    return headers;
  }

  Future<void> _fetchUserSchoolType() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final username = SessionManager.username;
      if (username == null) {
        setState(() {
          _error = 'no_username_in_session'.tr();
          _loading = false;
        });
        return;
      }
      final uri = Uri.parse('https://reports.icsportals.org/calendar/roles/$username');
      final response = await http.get(uri, headers: _buildAuthHeaders());
      await MatrixService.handlePotentialRevokedSessionResponse(response);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final elementary = data['elementary'] == true;
        final highschool = data['highschool'] == true;

        SchoolType schoolType;
        if (elementary && highschool) {
          schoolType = SchoolType.both;
        } else if (elementary) {
          schoolType = SchoolType.elementary;
        } else if (highschool) {
          schoolType = SchoolType.highschool;
        } else {
          schoolType = SchoolType.none;
        }

        setState(() {
          _userSchoolType = schoolType;
          _selectedSchool = (schoolType == SchoolType.both)
              ? SchoolType.elementary
              : schoolType;
        });

        if (schoolType != SchoolType.none) {
          await _fetchEvents();
        }
      } else if (response.statusCode == 401) {
        setState(() {
          _error = 'unauthorized_token'.tr();
        });
      } else {
        setState(() {
          _error = 'failed_fetch_user_roles'.tr(args: [response.statusCode.toString()]);
        });
      }
    } catch (e) {
      setState(() {
        _error = 'error_fetch_user_roles'.tr(args: [e.toString()]);
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  // --- Caching and fallback for calendar events ---
  Future<void> _fetchEvents() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final username = SessionManager.username;
      if (username == null) {
        setState(() {
          _error = 'no_username_in_session'.tr();
          _loading = false;
        });
        return;
      }

      final uri = Uri.parse('https://reports.icsportals.org/calendar/events/$username');
      final response = await http.get(uri, headers: _buildAuthHeaders());
      await MatrixService.handlePotentialRevokedSessionResponse(response);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final eventsJson = data is List ? data : (data['events'] as List);
        final events = eventsJson.map((e) => CalendarEvent.fromJson(e)).toList();
        setState(() {
          _events = List<CalendarEvent>.from(events);
        });
        await _saveEventsToCache(_events); // Persist events after fetching
      } else {
        // API error: fallback to cache
        await _loadCachedEvents();
        setState(() {
          _error = 'failed_fetch_events'.tr(args: [response.statusCode.toString()]);
        });
      }
    } catch (e) {
      // Network error: fallback to cache
      await _loadCachedEvents();
      setState(() {
        _error = 'error_fetch_events'.tr(args: [e.toString()]);
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Map<DateTime, List<CalendarEvent>> _groupEventsByDate() {
    List<CalendarEvent> filtered;
    if (_selectedSchool == SchoolType.elementary) {
      filtered = _events.where((e) => e.schoolId == 2).toList();
    } else if (_selectedSchool == SchoolType.highschool) {
      filtered = _events.where((e) => e.schoolId == 1).toList();
    } else {
      filtered = [];
    }
    final map = <DateTime, List<CalendarEvent>>{};
    for (final event in filtered) {
      final date = DateTime.tryParse(event.schoolDate);
      if (date != null) {
        final normalized = DateTime(date.year, date.month, date.day);
        map.putIfAbsent(normalized, () => []).add(event);
      }
    }
    return map;
  }

  void _showEventDetails(CalendarEvent event) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(event.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${'date'.tr()}: ${event.schoolDate}'),
            if (event.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(event.description),
            ],
          ],
        ),
        actions: [
          TextButton(
            child: Text('close'.tr()),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildAnimatedSchoolSwitcher() {
    // Always use English for calendar names, regardless of locale
    const elementaryCalendarName = "Elementary Calendar";
    const mshsCalendarName = "MSHS Calendar";

    if (_userSchoolType == SchoolType.both) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        transitionBuilder: (child, animation) {
          final isElementary = _selectedSchool == SchoolType.elementary;
          final offset =
          isElementary ? const Offset(1, 0) : const Offset(-1, 0);
          return SlideTransition(
            position: animation.drive(
              Tween<Offset>(
                begin: offset,
                end: Offset.zero,
              ).chain(CurveTween(curve: Curves.easeInOut)),
            ),
            child: child,
          );
        },
        child: _selectedSchool == SchoolType.elementary
            ? Row(
          key: const ValueKey('elementary'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.check),
              label: const Text(
                elementaryCalendarName,
                style: TextStyle(
                  color: Colors.black87,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple.shade50,
                foregroundColor: Colors.deepPurple,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16.0),
                ),
                padding: const EdgeInsets.symmetric(
                    vertical: 10, horizontal: 20),
              ),
              onPressed: null,
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () {
                setState(() {
                  _selectedSchool = SchoolType.highschool;
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeInOut,
                padding: const EdgeInsets.symmetric(
                    vertical: 10, horizontal: 6),
                child: const Icon(Icons.arrow_forward_ios, color: Colors.deepPurple, size: 24),
              ),
            )
          ],
        )
            : Row(
          key: const ValueKey('mshs'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: () {
                setState(() {
                  _selectedSchool = SchoolType.elementary;
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeInOut,
                padding: const EdgeInsets.symmetric(
                    vertical: 10, horizontal: 6),
                child: const Icon(Icons.arrow_back_ios, color: Colors.deepPurple, size: 24),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.check),
              label: const Text(
                mshsCalendarName,
                style: TextStyle(
                  color: Colors.black87,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple.shade50,
                foregroundColor: Colors.deepPurple,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16.0),
                ),
                padding: const EdgeInsets.symmetric(
                    vertical: 10, horizontal: 20),
              ),
              onPressed: null,
            ),
          ],
        ),
      );
    } else if (_userSchoolType == SchoolType.elementary) {
      return const Text(
        elementaryCalendarName,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 24,
        ),
        textAlign: TextAlign.center,
      );
    } else if (_userSchoolType == SchoolType.highschool) {
      return const Text(
        mshsCalendarName,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 24,
        ),
        textAlign: TextAlign.center,
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final eventsByDate = _groupEventsByDate();

    return Scaffold(
      appBar: AppBar(
        title: null,
        elevation: 0,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        iconTheme: Theme.of(context).iconTheme,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
            : Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Center(child: _buildAnimatedSchoolSwitcher()),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                transitionBuilder: (child, animation) {
                  final isElementary = _selectedSchool == SchoolType.elementary;
                  final offset =
                  isElementary ? const Offset(1, 0) : const Offset(-1, 0);
                  return SlideTransition(
                    position: animation.drive(
                      Tween<Offset>(
                        begin: offset,
                        end: Offset.zero,
                      ).chain(CurveTween(curve: Curves.easeInOut)),
                    ),
                    child: child,
                  );
                },
                child: TableCalendar<CalendarEvent>(
                  key: ValueKey(_selectedSchool),
                  firstDay: DateTime.utc(2000, 1, 1),
                  lastDay: DateTime.utc(2100, 12, 31),
                  focusedDay: _focusedDay,
                  selectedDayPredicate: (day) =>
                  _selectedDay != null &&
                      day.year == _selectedDay!.year &&
                      day.month == _selectedDay!.month &&
                      day.day == _selectedDay!.day,
                  eventLoader: (day) {
                    final d = DateTime(day.year, day.month, day.day);
                    return eventsByDate[d] ?? [];
                  },
                  calendarFormat: CalendarFormat.month,
                  startingDayOfWeek: StartingDayOfWeek.monday,
                  onDaySelected: (selectedDay, focusedDay) {
                    setState(() {
                      _selectedDay = selectedDay;
                      _focusedDay = focusedDay;
                    });
                  },
                  onPageChanged: (focusedDay) {
                    setState(() {
                      _focusedDay = focusedDay;
                    });
                  },
                  headerStyle: HeaderStyle(
                    formatButtonVisible: false,
                    titleCentered: true,
                    leftChevronVisible: true,
                    rightChevronVisible: true,
                    titleTextFormatter: (date, locale) {
                      return '';
                    },
                    headerPadding: const EdgeInsets.symmetric(vertical: 8.0),
                  ),
                  calendarBuilders: CalendarBuilders<CalendarEvent>(
                    markerBuilder: (context, date, events) {
                      if (events.isNotEmpty) {
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ...events.map((event) => GestureDetector(
                              onTap: () => _showEventDetails(event),
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: Colors.purple,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Icon(
                                  Icons.event,
                                  color: Colors.white,
                                  size: 12,
                                ),
                              ),
                            )),
                          ],
                        );
                      }
                      return null;
                    },
                  ),
                  calendarStyle: const CalendarStyle(
                    todayDecoration: BoxDecoration(
                      color: Colors.blueAccent,
                      shape: BoxShape.circle,
                    ),
                    selectedDecoration: BoxDecoration(
                      color: Colors.deepPurple,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    DropdownButton<int>(
                      value: _focusedDay.month,
                      onChanged: (month) {
                        if (month != null) {
                          setState(() {
                            _focusedDay = DateTime(_focusedDay.year, month, 1);
                          });
                        }
                      },
                      items: List.generate(
                        12,
                            (i) => DropdownMenuItem(
                          value: i + 1,
                          child: Text(
                            '${(i + 1).toString().padLeft(2, '0')} - ${_monthName(i + 1)}',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    DropdownButton<int>(
                      value: _focusedDay.year,
                      onChanged: (year) {
                        if (year != null) {
                          setState(() {
                            _focusedDay = DateTime(year, _focusedDay.month, 1);
                          });
                        }
                      },
                      items: List.generate(
                        20,
                            (i) => DropdownMenuItem(
                          value: 2015 + i,
                          child: Text((2015 + i).toString()),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (_selectedDay != null &&
                  (eventsByDate[DateTime(_selectedDay!.year, _selectedDay!.month, _selectedDay!.day)]?.isNotEmpty ?? false))
                ...eventsByDate[DateTime(_selectedDay!.year, _selectedDay!.month, _selectedDay!.day)]!
                    .map(
                      (event) => Card(
                    child: ListTile(
                      leading: Icon(
                        event.schoolId == 1
                            ? Icons.school
                            : event.schoolId == 2
                            ? Icons.child_care
                            : Icons.event,
                      ),
                      title: Text(event.title),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(event.schoolDate),
                          if (event.description.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Text(
                                event.description,
                                style: const TextStyle(fontSize: 12, color: Colors.black54),
                              ),
                            ),
                        ],
                      ),
                      onTap: () => _showEventDetails(event),
                    ),
                  ),
                )
                    .toList(),
            ],
          ),
        ),
      ),
    );
  }

  String _monthName(int month) {
    final monthKeys = [
      '',
      'month_january',
      'month_february',
      'month_march',
      'month_april',
      'month_may',
      'month_june',
      'month_july',
      'month_august',
      'month_september',
      'month_october',
      'month_november',
      'month_december'
    ];
    return monthKeys[month].tr();
  }
}
