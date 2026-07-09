import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'matrix_service.dart';
import 'app_config.dart';

class PtcScreen extends StatefulWidget {
  const PtcScreen({Key? key}) : super(key: key);

  @override
  State<PtcScreen> createState() => _PtcScreenState();
}

class _PtcScreenState extends State<PtcScreen> {
  static const String _ptcBaseUrl = AppConfig.ptcBaseUrl;

  bool _loading = true;
  bool _active = false;

  String? _error;

  String? _ptcDate; // YYYY-MM-DD
  String? _bookingCutoffKst; // ISO string from API

  // Parent-dashboard data
  List<Map<String, dynamic>> _children = [];
  Map<String, dynamic> _childBookings = {}; // childId -> booking map
  List<Map<String, dynamic>> _dropdownOptions = [];
  Map<String, dynamic> _slotsJson = {}; // teacherId -> [slots]

  // UI state
  final Map<int, String?> _selectedTeacherValueByChildId = {};

  // childId -> level ("elementary"/"mshs")
  final Map<int, String> _childLevelById = {};

  Map<String, String> get _ptcHeaders => {
    'X-Auth-Token': MatrixService.rocketchatAuthToken,
    'X-User-Id': MatrixService.rocketchatUserId,
    'Content-Type': 'application/json',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  // --- Formatting helpers (UI-friendly) ---

  DateTime? _parseCutoffKst(String? iso) {
    if (iso == null || iso.trim().isEmpty) return null;
    try {
      final dt = DateTime.parse(iso.trim());
      return dt.toUtc().add(const Duration(hours: 9));
    } catch (_) {
      return null;
    }
  }

  bool _isBookingClosed() {
    final dt = _parseCutoffKst(_bookingCutoffKst);
    if (dt == null) return false;
    final nowKst = DateTime.now().toUtc().add(const Duration(hours: 9));
    return nowKst.isAfter(dt);
  }

  String _fmtDateTimeKst(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    final hour24 = dt.hour;
    final hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12);
    final ampm = hour24 < 12 ? 'AM' : 'PM';
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} $hour12:${two(dt.minute)} $ampm';
  }

  String _fmtCutoffLabelArg() {
    final iso = _bookingCutoffKst;
    final dt = _parseCutoffKst(iso);
    if (dt == null) return (iso ?? '').trim();
    return _fmtDateTimeKst(dt);
  }

  String _fmtTimeHm(String t) {
    final s = t.trim();
    if (s.length >= 5) return s.substring(0, 5);
    return s;
  }

  String _fmtRange(String st, String et) {
    final st2 = _fmtTimeHm(st);
    final et2 = _fmtTimeHm(et);
    if (st2.isNotEmpty && et2.isNotEmpty) return '$st2 – $et2';
    return st2.isNotEmpty ? st2 : et2;
  }

  // --- Data loading ---

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _children = [];
      _childBookings = {};
      _dropdownOptions = [];
      _slotsJson = {};
      _selectedTeacherValueByChildId.clear();
      _childLevelById.clear();
    });

    final restored = await MatrixService.restoreSession();
    if (!restored) {
      setState(() {
        _loading = false;
        _error = 'report_auth_error'.tr();
      });
      return;
    }

    try {
      await _fetchActiveDay();
      if (_active) {
        await _fetchDashboard();
      } else {
        _error = 'ptc_unavailable_message'.tr();
      }
    } catch (e) {
      setState(() {
        _error = 'ptc_error_checking'.tr(args: [e.toString()]);
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _fetchActiveDay() async {
    final uri = Uri.parse('$_ptcBaseUrl/api/ptc/active-day');
    final resp = await http.get(uri, headers: _ptcHeaders);
    await MatrixService.handlePotentialRevokedSessionResponse(resp);

    if (resp.statusCode == 401) {
      throw Exception('ptc_unauthorized'.tr());
    }
    if (resp.statusCode == 403) {
      final detail = _tryExtractDetail(resp.body) ?? 'ptc_unauthorized'.tr();
      throw Exception(detail);
    }
    if (resp.statusCode != 200) {
      throw Exception('ptc_failed_status'.tr(args: [resp.statusCode.toString()]));
    }

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final active = decoded['active'] == true;

    final ptcDay = decoded['ptc_day'];
    String? date;
    if (ptcDay is Map && ptcDay['date'] != null) {
      date = ptcDay['date'].toString();
    }

    setState(() {
      _active = active;
      _ptcDate = date;
      _bookingCutoffKst = decoded['booking_cutoff_kst']?.toString();
    });
  }

  Future<void> _fetchDashboard() async {
    final date = (_ptcDate ?? '').trim();
    final uri = Uri.parse('$_ptcBaseUrl/api/ptc/dashboard${date.isNotEmpty ? '?date=$date' : ''}');
    final resp = await http.get(uri, headers: _ptcHeaders);
    await MatrixService.handlePotentialRevokedSessionResponse(resp);

    if (resp.statusCode == 401) {
      throw Exception('ptc_unauthorized'.tr());
    }
    if (resp.statusCode == 403) {
      final detail = _tryExtractDetail(resp.body) ?? 'ptc_unauthorized'.tr();
      throw Exception(detail);
    }
    if (resp.statusCode != 200) {
      throw Exception('ptc_failed_status'.tr(args: [resp.statusCode.toString()]));
    }

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;

    final children = (decoded['children'] as List?) ?? const [];
    final childBookings = decoded['child_bookings'];
    final dropdownOptions = (decoded['dropdown_options'] as List?) ?? const [];
    final slotsJson = decoded['slots_json'];

    final childMapList = children.whereType<Map>().map((e) => Map<String, dynamic>.from(e as Map)).toList();
    _childLevelById.clear();
    for (final child in childMapList) {
      final childId = int.tryParse(child['id']?.toString() ?? '');
      if (childId != null && child['level'] != null && child['level'] is String) {
        _childLevelById[childId] = child['level']!;
      }
    }

    setState(() {
      _children = childMapList;
      _childBookings = (childBookings is Map) ? Map<String, dynamic>.from(childBookings) : <String, dynamic>{};
      _dropdownOptions =
          dropdownOptions.whereType<Map>().map((e) => Map<String, dynamic>.from(e as Map)).toList();
      _slotsJson = (slotsJson is Map) ? Map<String, dynamic>.from(slotsJson) : <String, dynamic>{};
    });
  }

  String? _tryExtractDetail(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
      if (decoded is Map && decoded['error'] != null) {
        return decoded['error'].toString();
      }
    } catch (_) {}
    return null;
  }

  // --- Booking actions ---

  Future<void> _cancelBooking(int childId) async {
    final bookingClosed = _isBookingClosed();
    if (bookingClosed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ptc_booking_closed'.tr(args: [_fmtCutoffLabelArg()]))),
      );
      return;
    }

    final level = _childLevelById[childId];
    if (level == null) {
      setState(() => _error = 'Missing student level info for this child.');
      return;
    }

    final confirmCancel = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('ptc_cancel_title'.tr()),
        content: Text('ptc_cancel_confirm'.tr()),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('cancel'.tr())),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text('confirm'.tr())),
        ],
      ),
    );

    if (confirmCancel != true) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final uri = Uri.parse('$_ptcBaseUrl/api/ptc/cancel');
      final resp = await http.post(
        uri,
        headers: _ptcHeaders,
        body: jsonEncode({'child_id': childId, 'level': level}),
      );
      await MatrixService.handlePotentialRevokedSessionResponse(resp);

      if (resp.statusCode == 401) throw Exception('ptc_unauthorized'.tr());
      if (resp.statusCode != 200) {
        final detail = _tryExtractDetail(resp.body) ??
            'ptc_failed_status'.tr(args: [resp.statusCode.toString()]);
        throw Exception(detail);
      }
      await _load();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _bookSlot({
    required int childId,
    required int teacherId,
    required int slotId,
    required String notes,
    required bool needsTranslator,
  }) async {
    final bookingClosed = _isBookingClosed();
    if (bookingClosed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ptc_booking_closed'.tr(args: [_fmtCutoffLabelArg()]))),
      );
      return;
    }

    final level = _childLevelById[childId];
    if (level == null) {
      setState(() => _error = 'Missing student level info for this child.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final uri = Uri.parse('$_ptcBaseUrl/api/ptc/book');
      final resp = await http.post(
        uri,
        headers: _ptcHeaders,
        body: jsonEncode({
          'slot_id': slotId,
          'teacher_id': teacherId,
          'child_id': childId,
          'level': level,
          'notes': notes,
          'needs_translator': needsTranslator,
        }),
      );
      await MatrixService.handlePotentialRevokedSessionResponse(resp);

      if (resp.statusCode == 401) throw Exception('ptc_unauthorized'.tr());
      if (resp.statusCode != 200) {
        final detail = _tryExtractDetail(resp.body) ??
            'ptc_failed_status'.tr(args: [resp.statusCode.toString()]);
        throw Exception(detail);
      }

      await _load();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic>? _bookingForChild(int childId) {
    final key = childId.toString();
    final b = _childBookings[key];
    if (b is Map) return Map<String, dynamic>.from(b as Map);
    return null;
  }

  String _childName(Map<String, dynamic> child) {
    final display = (child['display_name'] ?? '').toString().trim();
    if (display.isNotEmpty) return display;
    final first = (child['first_name'] ?? '').toString().trim();
    final last = (child['last_name'] ?? '').toString().trim();
    final full = ('$first $last').trim();
    return full.isEmpty ? '—' : full;
  }

  String _teacherLabelById(int teacherId) {
    for (final opt in _dropdownOptions) {
      if (opt['type'] == 'single' && opt['id'] == teacherId) {
        return (opt['label'] ?? opt['name'] ?? '').toString();
      }
    }
    return 'Teacher $teacherId';
  }

  List<Map<String, dynamic>> _slotsForTeacher(int teacherId) {
    final raw = _slotsJson[teacherId.toString()];
    if (raw is List) {
      return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return const [];
  }

  Future<void> _showBookDialog({
    required int childId,
    required int teacherId,
    required Map<String, dynamic> slot,
  }) async {
    final slotId = slot['id'];
    if (slotId == null) return;

    final st = (slot['start_time'] ?? '').toString();
    final et = (slot['end_time'] ?? '').toString();

    final notesController = TextEditingController();
    bool needsTranslator = false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocalState) => AlertDialog(
          title: Text('ptc_book_title'.tr()),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_fmtRange(st, et), style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(_teacherLabelById(teacherId)),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'ptc_special_requests'.tr(),
                    hintText: 'ptc_special_requests_hint'.tr(),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Checkbox(
                      value: needsTranslator,
                      onChanged: (v) => setLocalState(() => needsTranslator = (v == true)),
                    ),
                    Expanded(child: Text('ptc_need_translator_question'.tr())),
                  ],
                ),
                Text(
                  'ptc_translator_disclaimer'.tr(),
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('cancel'.tr())),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text('confirm'.tr())),
          ],
        ),
      ),
    );

    if (ok != true) return;

    await _bookSlot(
      childId: childId,
      teacherId: teacherId,
      slotId: int.parse(slotId.toString()),
      notes: notesController.text.trim(),
      needsTranslator: needsTranslator,
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = 'ptc_title'.tr();

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'refresh'.tr(),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null && _error!.isNotEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _error!,
            style: const TextStyle(color: Colors.red, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Center(
            child: ElevatedButton(
              onPressed: _load,
              child: Text('retry'.tr()),
            ),
          ),
        ],
      );
    }

    if (!_active) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'ptc_unavailable_message'.tr(),
            style: const TextStyle(color: Colors.red, fontSize: 16),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    final bookingClosed = _isBookingClosed();

    final header = Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ptc_parent_header_title'.tr(),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            if ((_ptcDate ?? '').isNotEmpty) Text('ptc_date_label'.tr(args: [_ptcDate!])),
            if ((_bookingCutoffKst ?? '').isNotEmpty)
              Text('ptc_cutoff_label'.tr(args: [_fmtCutoffLabelArg()])),
            if (bookingClosed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'ptc_booking_closed'.tr(args: [_fmtCutoffLabelArg()]),
                  style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    );

    if (_children.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          header,
          const SizedBox(height: 12),
          Text(
            'ptc_no_children'.tr(),
            style: const TextStyle(fontSize: 16),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      itemCount: _children.length + 1,
      itemBuilder: (context, idx) {
        if (idx == 0) return header;

        final child = _children[idx - 1];
        final childId = int.tryParse(child['id'].toString()) ?? 0;
        final childName = _childName(child);
        final childLevel = child['level']?.toString() ?? '';

        final booking = _bookingForChild(childId);

        return Card(
          margin: const EdgeInsets.only(top: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  childName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),

                if (booking != null) ...[
                  Text(
                    'ptc_booking_current'.tr(),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _fmtRange(
                      (booking['start_time'] ?? '').toString(),
                      (booking['end_time'] ?? '').toString(),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(_teacherLabelById(int.tryParse(booking['teacher_id'].toString()) ?? 0)),
                  if ((booking['notes'] ?? '').toString().trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('ptc_notes_label'.tr(args: [(booking['notes'] ?? '').toString().trim()])),
                    ),
                  if (booking['needs_translator'] == true)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'ptc_needs_translator'.tr(),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ElevatedButton(
                      onPressed: bookingClosed ? null : () => _cancelBooking(childId),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      child: Text('ptc_cancel_button'.tr()),
                    ),
                  ),
                ] else ...[
                  // Booking UI for unbooked child
                  Text(
                    'ptc_book_for_child'.tr(),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),

                  // ----> ONLY SHOW TEACHERS OF MATCHING LEVEL
                  DropdownButtonFormField<String>(
                    value: _selectedTeacherValueByChildId[childId],
                    items: _dropdownOptions
                        .where((opt) => (opt['level'] ?? '') == childLevel)
                        .map((opt) {
                      final type = (opt['type'] ?? '').toString();
                      if (type != 'single') return null;
                      final teacherId = opt['id'];
                      if (teacherId == null) return null;
                      final value = 'single-$teacherId';
                      final label = (opt['label'] ?? opt['name'] ?? value).toString();
                      return DropdownMenuItem(value: value, child: Text(label));
                    })
                        .whereType<DropdownMenuItem<String>>()
                        .toList(),
                    onChanged: bookingClosed
                        ? null
                        : (v) => setState(() {
                      _selectedTeacherValueByChildId[childId] = v;
                    }),
                    decoration: InputDecoration(
                      labelText: 'ptc_select_teacher'.tr(),
                    ),
                  ),
                  const SizedBox(height: 10),

                  Builder(
                    builder: (context) {
                      final sel = _selectedTeacherValueByChildId[childId];
                      if (sel == null || sel.isEmpty) {
                        return Text('ptc_select_teacher_hint'.tr());
                      }

                      final parts = sel.split('-');
                      if (parts.length != 2) return const SizedBox.shrink();
                      final teacherId = int.tryParse(parts[1]) ?? 0;
                      if (teacherId == 0) return const SizedBox.shrink();

                      final slots = _slotsForTeacher(teacherId);
                      if (slots.isEmpty) {
                        return Text('ptc_no_slots'.tr());
                      }

                      final available = slots.where((s) => s['id'] != null).toList();

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ptc_available_slots'.tr(),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          ...available.map((slot) {
                            final booked = slot['booked'] == true;
                            final st = (slot['start_time'] ?? '').toString();
                            final et = (slot['end_time'] ?? '').toString();
                            final range = _fmtRange(st, et);

                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(range),
                              subtitle: booked ? Text('ptc_slot_booked'.tr()) : null,
                              trailing: ElevatedButton(
                                onPressed: (bookingClosed || booked)
                                    ? null
                                    : () => _showBookDialog(
                                  childId: childId,
                                  teacherId: teacherId,
                                  slot: slot,
                                ),
                                child: Text('ptc_book_button'.tr()),
                              ),
                            );
                          }),
                        ],
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
