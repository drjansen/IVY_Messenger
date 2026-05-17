import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:easy_localization/easy_localization.dart';
import 'matrix_service.dart';
import 'session_manager.dart';

// --- Models ---

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
}

class Announcement {
  final String title;
  final String body;
  final DateTime date;
  Announcement({required this.title, required this.body, required this.date});
  factory Announcement.fromJson(Map<String, dynamic> json) {
    return Announcement(
      title: json['title'] ?? '',
      body: json['body'] ?? '',
      date: DateTime.tryParse(json['date'] ?? '') ?? DateTime.now(),
    );
  }
}

class Child {
  final String name;
  final int studentId;
  final int absences;
  final int tardies;

  Child({
    required this.name,
    required this.studentId,
    required this.absences,
    required this.tardies,
  });

  factory Child.fromJson(Map<String, dynamic> json) {
    return Child(
      name: json['name'] ?? '',
      studentId: json['student_id'] is int
          ? json['student_id']
          : int.tryParse(json['student_id'].toString()) ?? 0,
      absences: json['absences'] is int
          ? json['absences']
          : int.tryParse(json['absences'].toString()) ?? 0,
      tardies: json['tardies'] is int
          ? json['tardies']
          : int.tryParse(json['tardies'].toString()) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'student_id': studentId,
    'absences': absences,
    'tardies': tardies,
  };
}

class LunchMenu {
  final String menuDetails;
  final String? imageUrl;
  LunchMenu({required this.menuDetails, this.imageUrl});
  factory LunchMenu.fromJson(Map<String, dynamic> json) {
    return LunchMenu(
      menuDetails: json['menu_details'] ?? '',
      imageUrl: json['image_url'],
    );
  }
}

// --- Dashboard Screen ---

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({Key? key}) : super(key: key);

  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

enum SchoolType { elementary, highschool, both, none }

class DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  // ---- FIX: initialize with dummy values to avoid LateInitializationError ----
  late Future<List<Announcement>> _announcementsFuture = Future.value([]);
  late Future<List<Child>> _childrenFuture = Future.value([]);
  late Future<LunchMenu> _lunchMenuFuture = Future.value(LunchMenu(menuDetails: 'No menu available', imageUrl: null));
  late Future<List<CalendarEvent>> _upcomingEventsFuture = Future.value([]);
  // ---------------------------------------------------------------------------

  SchoolType _userSchoolType = SchoolType.none;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetchAllDashboardData(); // ensures futures are assigned immediately
    _restoreSessionAndFetchAllDashboardData(); // will update data after possible async session restore
  }

  Future<void> _restoreSessionAndFetchAllDashboardData() async {
    await SessionManager.restoreSession();
    setState(() {
      _fetchAllDashboardData();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // This function is called when the dashboard tab is entered.
  // Call this from your tab navigation code when dashboard is selected.
  void refreshDashboardData() {
    setState(() {
      _fetchAllDashboardData();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // DO NOT refresh here, only refresh when dashboard tab is navigated to.
    // You may remove this method or leave it empty.
  }

  void _fetchAllDashboardData() {
    _announcementsFuture = fetchAnnouncements();
    _childrenFuture = fetchChildren(forceRefresh: true);
    _lunchMenuFuture = fetchLunchMenu();
    _upcomingEventsFuture = fetchUpcomingEvents();
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

  Future<SchoolType> _fetchUserSchoolType() async {
    final username = SessionManager.username;
    if (username == null) return SchoolType.none;
    try {
      final uri = Uri.parse('https://reports.icsportals.org/calendar/roles/$username');
      final response = await http.get(uri, headers: _buildAuthHeaders());
      await MatrixService.handlePotentialRevokedSessionResponse(response);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final elementary = data['elementary'] == true;
        final highschool = data['highschool'] == true;

        if (elementary && highschool) {
          return SchoolType.both;
        } else if (elementary) {
          return SchoolType.elementary;
        } else if (highschool) {
          return SchoolType.highschool;
        } else {
          return SchoolType.none;
        }
      }
    } catch (e) {
      // ignore
    }
    return SchoolType.none;
  }

  // --- Updated Announcements with caching ---
  Future<List<Announcement>> fetchAnnouncements() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedJsonString = prefs.getString('cached_announcements');
    List<Announcement>? cachedAnnouncements;

    if (cachedJsonString != null) {
      final cachedList = json.decode(cachedJsonString) as List;
      cachedAnnouncements = cachedList.map((json) => Announcement.fromJson(json)).toList();
    }

    final uri = Uri.parse('https://reports.icsportals.org/announcements');
    try {
      final response = await http.get(uri, headers: _buildAuthHeaders());
      await MatrixService.handlePotentialRevokedSessionResponse(response);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final announcementsJson = data['announcements'] as List;
        final announcements = announcementsJson.map((json) => Announcement.fromJson(json)).toList();
        prefs.setString('cached_announcements', json.encode(announcementsJson));
        return announcements;
      }
    } catch (e) {
      // Network error, ignore
    }

    // Fallback to cache if network/API fails
    return cachedAnnouncements ?? [];
  }

  Future<List<Child>> fetchChildren({bool forceRefresh = false}) async {
    final username = SessionManager.username;

    // If not forceRefresh, try loading from cache first.
    if (!forceRefresh) {
      final prefs = await SharedPreferences.getInstance();
      final cachedJsonString = prefs.getString('cached_children');
      if (cachedJsonString != null) {
        final cachedList = json.decode(cachedJsonString) as List;
        final children = cachedList.map((childJson) => Child.fromJson(childJson)).toList();
        return children;
      }
    }

    if (username == null) {
      return [];
    }

    final uri = Uri.parse('https://reports.icsportals.org/children_attendance/$username');
    final response = await http.get(uri, headers: _buildAuthHeaders());
    await MatrixService.handlePotentialRevokedSessionResponse(response);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final childrenJson = data['children'] as List;
      final children = childrenJson.map((child) => Child.fromJson(child)).toList();
      final prefs = await SharedPreferences.getInstance();
      final jsonString = json.encode(children.map((c) => c.toJson()).toList());
      prefs.setString('cached_children', jsonString);
      return children;
    } else {
      // If API fails, try cache
      final prefs = await SharedPreferences.getInstance();
      final cachedJsonString = prefs.getString('cached_children');
      if (cachedJsonString != null) {
        final cachedList = json.decode(cachedJsonString) as List;
        return cachedList.map((childJson) => Child.fromJson(childJson)).toList();
      }
      return [];
    }
  }

  // --- Updated LunchMenu with proper caching and refresh ---
  Future<LunchMenu> fetchLunchMenu() async {
    final prefs = await SharedPreferences.getInstance();

    final uri = Uri.parse('https://reports.icsportals.org/lunch_menu/today');
    try {
      final response = await http.get(uri, headers: _buildAuthHeaders());
      await MatrixService.handlePotentialRevokedSessionResponse(response);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        prefs.setString('cached_lunch_menu', json.encode(data));
        return LunchMenu.fromJson(data);
      } else {
        // Even error response might contain a message
        final data = json.decode(response.body);
        prefs.setString('cached_lunch_menu', json.encode(data));
        return LunchMenu(menuDetails: data['message'] ?? 'No menu available', imageUrl: null);
      }
    } catch (e) {
      // Network error, fallback to cache
      final cachedMenuString = prefs.getString('cached_lunch_menu');
      if (cachedMenuString != null) {
        final cachedJson = json.decode(cachedMenuString);
        return LunchMenu.fromJson(cachedJson);
      }
      // Fallback if everything fails
      return LunchMenu(menuDetails: 'No menu available', imageUrl: null);
    }
  }

  Future<List<CalendarEvent>> fetchUpcomingEvents() async {
    final username = SessionManager.username;
    if (username == null) {
      return [];
    }
    try {
      final schoolType = await _fetchUserSchoolType();
      _userSchoolType = schoolType;

      final eventsUri = Uri.parse('https://reports.icsportals.org/calendar/events/$username');
      final eventsResp = await http.get(eventsUri, headers: _buildAuthHeaders());
      await MatrixService.handlePotentialRevokedSessionResponse(eventsResp);
      if (eventsResp.statusCode != 200) {
        return [];
      }

      final data = json.decode(eventsResp.body);
      final eventsJson = data is List ? data : (data['events'] as List);
      final allEvents = eventsJson.map<CalendarEvent>((e) => CalendarEvent.fromJson(e)).toList();

      List<CalendarEvent> filtered;
      if (schoolType == SchoolType.elementary) {
        filtered = allEvents.where((e) => e.schoolId == 2).toList();
      } else if (schoolType == SchoolType.highschool) {
        filtered = allEvents.where((e) => e.schoolId == 1).toList();
      } else if (schoolType == SchoolType.both) {
        filtered = allEvents.where((e) => e.schoolId == 1 || e.schoolId == 2).toList();
      } else {
        filtered = [];
      }

      final now = DateTime.now();
      final startDate = DateTime(now.year, now.month, now.day);
      final endDate = startDate.add(const Duration(days: 7));
      filtered = filtered.where((e) {
        final eventDate = DateTime.tryParse(e.schoolDate);
        if (eventDate == null) {
          return false;
        }
        final eventDay = DateTime(eventDate.year, eventDate.month, eventDate.day);
        return !eventDay.isBefore(startDate) && !eventDay.isAfter(endDate);
      }).toList()
        ..sort((a, b) => a.schoolDate.compareTo(b.schoolDate));
      return filtered;
    } catch (e) {
      return [];
    }
  }

  // --- UI ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("dashboard_title".tr()),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- Announcements Card ---
            FutureBuilder<List<Announcement>>(
              future: _announcementsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return _dashboardCardLoading();
                }
                if (snapshot.hasError) {
                  return _dashboardCardError("dashboard_announcements_failed".tr());
                }
                final announcements = snapshot.data ?? [];
                return Card(
                  color: Colors.blue[50],
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.announcement, color: Colors.blue),
                            const SizedBox(width: 8),
                            Text(
                              "dashboard_announcements".tr(),
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (announcements.isEmpty)
                          Text("dashboard_announcements_none".tr()),
                        ...announcements.map((a) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 2),
                              Text(a.body, style: const TextStyle(fontSize: 15)),
                              const SizedBox(height: 2),
                              Text(
                                "${a.date.month}/${a.date.day}/${a.date.year}",
                                style: const TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic),
                              ),
                            ],
                          ),
                        )),
                      ],
                    ),
                  ),
                );
              },
            ),
            // --- Upcoming Events Card ---
            FutureBuilder<List<CalendarEvent>>(
              future: _upcomingEventsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return _dashboardCardLoading();
                }
                if (snapshot.hasError) {
                  return _dashboardCardError("dashboard_events_failed".tr());
                }
                final events = snapshot.data ?? [];
                if (events.isEmpty) {
                  return Card(
                    color: Colors.orange[50],
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      leading: const Icon(Icons.event, color: Colors.orange),
                      title: Text("dashboard_events_none".tr()),
                    ),
                  );
                }
                return Card(
                  color: Colors.orange[50],
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.event, color: Colors.orange),
                            const SizedBox(width: 8),
                            Text("dashboard_upcoming_events".tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ...events.map((event) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(event.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 2),
                              Text(event.schoolDate),
                              if (event.description.isNotEmpty)
                                Text(event.description, style: const TextStyle(fontSize: 13, color: Colors.black54)),
                            ],
                          ),
                        )),
                      ],
                    ),
                  ),
                );
              },
            ),
            // --- Children List Card (Attendance: names + absences + tardies) ---
            FutureBuilder<List<Child>>(
              future: _childrenFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return _dashboardCardLoading();
                }
                if (snapshot.hasError) {
                  return _dashboardCardError("dashboard_attendance_failed".tr());
                }
                final children = snapshot.data ?? [];
                return Card(
                  color: Colors.deepPurple[50],
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.assignment_turned_in, color: Colors.deepPurple),
                            const SizedBox(width: 8),
                            Text("dashboard_attendance_title".tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (children.isEmpty)
                          Text("dashboard_attendance_none".tr()),
                        ...children.map((child) => Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(child.name, style: const TextStyle(fontSize: 16)),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: (child.absences > 0 || child.tardies > 0) ? Colors.red[100] : Colors.grey[200],
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    Text(
                                      "A: ${child.absences}",
                                      style: TextStyle(
                                        color: child.absences > 0 ? Colors.red : Colors.black,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      "T: ${child.tardies}",
                                      style: TextStyle(
                                        color: child.tardies > 0 ? Colors.orange : Colors.black,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )),
                      ],
                    ),
                  ),
                );
              },
            ),
            // --- Lunch Menu Card ---
            FutureBuilder<LunchMenu>(
              future: _lunchMenuFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return _dashboardCardLoading();
                }
                if (snapshot.hasError) {
                  return _dashboardCardError("dashboard_lunch_failed".tr());
                }
                final menu = snapshot.data;

                String? fullImageUrl;
                if (menu?.imageUrl != null && menu!.imageUrl!.isNotEmpty) {
                  if (menu.imageUrl!.startsWith('/')) {
                    fullImageUrl = 'https://reports.icsportals.org${menu.imageUrl!}';
                  } else if (!menu.imageUrl!.startsWith('http')) {
                    fullImageUrl = 'https://reports.icsportals.org/lunch_menu_images/${menu.imageUrl!}';
                  } else {
                    fullImageUrl = menu.imageUrl!;
                  }
                }

                bool noMenu = menu == null ||
                    (menu.menuDetails.trim().isEmpty || menu.menuDetails == "No menu available");

                return Card(
                  color: Colors.green[50],
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.lunch_dining, color: Colors.green),
                            const SizedBox(width: 8),
                            Text("dashboard_lunch_title".tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (noMenu) ...[
                          Text(
                            "dashboard_lunch_none".tr(),
                            style: TextStyle(fontSize: 16),
                          ),
                        ] else ...[
                          Text(menu!.menuDetails),
                          if (fullImageUrl != null && fullImageUrl.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Center(
                              child: GestureDetector(
                                onTap: () {
                                  showDialog(
                                    context: context,
                                    builder: (_) => Dialog(
                                      backgroundColor: Colors.transparent,
                                      child: Stack(
                                        children: [
                                          GestureDetector(
                                            onTap: () => Navigator.pop(context),
                                            child: Container(
                                              color: Colors.black54,
                                              child: Center(
                                                child: ClipRRect(
                                                  borderRadius: BorderRadius.circular(8),
                                                  child: Image.network(
                                                    fullImageUrl!,
                                                    fit: BoxFit.contain,
                                                    loadingBuilder: (context, child, progress) =>
                                                    progress == null
                                                        ? child
                                                        : const SizedBox(
                                                        height: 200,
                                                        child: Center(child: CircularProgressIndicator())),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            right: 0,
                                            top: 0,
                                            child: IconButton(
                                              icon: Icon(Icons.close, color: Colors.white, size: 32),
                                              onPressed: () => Navigator.of(context).pop(),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                                child: AbsorbPointer(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      fullImageUrl!,
                                      height: 120,
                                      fit: BoxFit.cover,
                                      frameBuilder: (context, child, frame, wasSyncLoaded) {
                                        return GestureDetector(
                                          onSecondaryTap: () {}, // disables right click on web
                                          child: child,
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ]
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _dashboardCardLoading() => const Card(
    child: Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: CircularProgressIndicator()),
    ),
  );

  Widget _dashboardCardError(String message) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        message,
        style: const TextStyle(color: Colors.red),
      ),
    ),
  );
}

// Helper for deep equality of lists
bool listEquals(List a, List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (json.encode(a[i]) != json.encode(b[i])) return false;
  }
  return true;
}
