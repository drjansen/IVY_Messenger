import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../main_screen.dart';
import 'package:ics_messenger_app/session_manager.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:intl/intl.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({Key? key}) : super(key: key);

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final _formKey = GlobalKey<FormState>();

  String? school;
  String? reportType;
  DateTime? incidentDate;
  List<String> witnesses = [];
  List<PlatformFile> evidenceFiles = [];
  bool disclaimerAccepted = false;
  bool submitting = false;

  late TextEditingController firstNameController;
  late TextEditingController lastNameController;
  late TextEditingController emailController;
  late TextEditingController confirmEmailController;
  late TextEditingController subjectController;
  late TextEditingController descriptionController;
  late TextEditingController witnessesController;

  String? username;

  String? _authToken;
  String? _userId;
  String? _accessToken;

  @override
  void initState() {
    super.initState();
    firstNameController = TextEditingController();
    lastNameController = TextEditingController();
    emailController = TextEditingController();
    confirmEmailController = TextEditingController();
    subjectController = TextEditingController();
    descriptionController = TextEditingController();
    witnessesController = TextEditingController();

    _loadUsername();
    _loadAuthHeaders();
    _loadAccessToken();
  }

  @override
  void dispose() {
    firstNameController.dispose();
    lastNameController.dispose();
    emailController.dispose();
    confirmEmailController.dispose();
    subjectController.dispose();
    descriptionController.dispose();
    witnessesController.dispose();
    super.dispose();
  }

  Future<void> _loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      username = SessionManager.username ?? prefs.getString('saved_username') ?? '';
    });
  }

  Future<void> _loadAuthHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _authToken = prefs.getString('rocketchat_auth_token') ?? '';
      _userId = prefs.getString('rocketchat_user_id') ?? '';
    });
  }

  Future<void> _loadAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _accessToken = prefs.getString('access_token') ?? '';
    });
  }

  Future<void> _pickEvidence() async {
    FilePickerResult? result =
    await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null) {
      setState(() {
        evidenceFiles = result.files;
      });
    }
  }

  Future<void> _pickDate() async {
    DateTime now = DateTime.now();
    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: now,
    );
    if (picked != null) {
      setState(() => incidentDate = picked);
    }
  }

  Future<bool> _showTermsDialog() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text('report_terms_title'.tr()),
        content: SingleChildScrollView(
          child: Text(
            'report_terms_content'.tr(),
            style: const TextStyle(fontSize: 14),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('cancel'.tr()),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('accept'.tr()),
          ),
        ],
      ),
    );
    if (accepted == true) {
      setState(() {
        disclaimerAccepted = true;
      });
    }
    return accepted == true;
  }

  Future<void> _submitReport() async {
    if (!_formKey.currentState!.validate() ||
        evidenceFiles.isEmpty ||
        !disclaimerAccepted ||
        incidentDate == null ||
        school == null) {
      if (!disclaimerAccepted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'report_terms_required'.tr())),
        );
      }
      return;
    }

    if (_authToken == null ||
        _authToken!.isEmpty ||
        _userId == null ||
        _userId!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'report_auth_error'.tr())),
      );
      return;
    }

    setState(() => submitting = true);

    try {
      var uri = Uri.parse('https://reports.icsportals.org/submit-report/');
      var request = http.MultipartRequest('POST', uri);

      request.headers['X-Auth-Token'] = _authToken!;
      request.headers['X-User-Id'] = _userId!;

      request.fields['school'] = school ?? '';
      request.fields['username'] = username ?? '';
      request.fields['first_name'] = firstNameController.text.trim();
      request.fields['last_name'] = lastNameController.text.trim();
      request.fields['email'] = emailController.text.trim();
      request.fields['report_type'] = reportType ?? '';
      request.fields['subject'] = subjectController.text.trim();
      request.fields['description'] = descriptionController.text.trim();
      request.fields['incident_date'] = incidentDate!.toIso8601String();
      request.fields['witnesses'] = witnessesController.text.trim();

      for (var file in evidenceFiles) {
        if (file.path != null) {
          request.files.add(
            await http.MultipartFile.fromPath(
              'files',
              file.path!,
              filename: file.name,
            ),
          );
        }
      }

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('report_submitted_title'.tr()),
            content: Text('report_submitted_message'.tr()),
            actions: [
              ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(
                      builder: (context) => MainScreen(
                        accessToken: _accessToken ?? '',
                        username: SessionManager.username ?? username ?? '',
                        initialTab: 0,
                      ),
                    ),
                        (route) => false,
                  );
                },
                child: Text('ok'.tr()),
              ),
            ],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('report_submission_failed'
                  .tr(namedArgs: {'error': response.body}))
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('report_submission_error'
                .tr(namedArgs: {'error': e.toString()}))
        ),
      );
    } finally {
      setState(() => submitting = false);
    }
  }

  String? _validateEmail(String? value) {
    if (value == null || value.isEmpty) return 'report_email_required'.tr();
    final emailRegExp = RegExp(r"^[\w\.-]+@[\w\.-]+\.\w+$");
    if (!emailRegExp.hasMatch(value)) return 'report_email_invalid'.tr();
    return null;
  }

  String? _validateEmailMatch(String? value) {
    if (value == null || value.isEmpty) return 'report_email_confirm'.tr();
    if (value != emailController.text.trim()) return 'report_email_mismatch'.tr();
    return _validateEmail(value);
  }

  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) return 'required'.tr();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('report_submit_title'.tr())),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              DropdownButtonFormField<String>(
                value: school,
                items: [
                  DropdownMenuItem(value: 'Elementary', child: Text('report_school_elementary'.tr())),
                  DropdownMenuItem(value: 'MSHS', child: Text('report_school_mshs'.tr())),
                ],
                decoration: InputDecoration(labelText: 'report_school_label'.tr()),
                onChanged: (v) => setState(() => school = v),
                validator: (v) => v == null ? 'required'.tr() : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: firstNameController,
                decoration: InputDecoration(labelText: 'report_first_name'.tr()),
                validator: _validateName,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: lastNameController,
                decoration: InputDecoration(labelText: 'report_last_name'.tr()),
                validator: _validateName,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: emailController,
                decoration: InputDecoration(labelText: 'report_email'.tr()),
                keyboardType: TextInputType.emailAddress,
                validator: _validateEmail,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: confirmEmailController,
                decoration: InputDecoration(labelText: 'report_email_confirm_label'.tr()),
                keyboardType: TextInputType.emailAddress,
                validator: _validateEmailMatch,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: reportType,
                items: [
                  DropdownMenuItem(value: 'Student Behavior', child: Text('report_type_student'.tr())),
                  DropdownMenuItem(value: 'Staff Misconduct', child: Text('report_type_staff'.tr())),
                  DropdownMenuItem(value: 'Parent Conflict', child: Text('report_type_parent'.tr())),
                ],
                decoration: InputDecoration(labelText: 'report_type_label'.tr()),
                onChanged: (v) => setState(() => reportType = v),
                validator: (v) => v == null ? 'required'.tr() : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: subjectController,
                decoration: InputDecoration(labelText: 'report_subject'.tr()),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'required'.tr() : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: descriptionController,
                decoration: InputDecoration(labelText: 'report_description'.tr()),
                maxLines: 5,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'required'.tr() : null,
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  incidentDate == null
                      ? 'report_incident_date_label'.tr()
                      : 'report_incident_date_selected'.tr(
                      namedArgs: {'date': DateFormat('yyyy-MM-dd').format(incidentDate!)}
                  ),
                ),
                trailing: const Icon(Icons.calendar_today),
                onTap: _pickDate,
              ),
              if (incidentDate == null)
                Padding(
                  padding: const EdgeInsets.only(left: 12.0, top: 4.0),
                  child: Text('required'.tr(), style: TextStyle(color: Colors.red)),
                ),
              const SizedBox(height: 16),
              TextFormField(
                controller: witnessesController,
                decoration: InputDecoration(
                  labelText: 'report_witnesses'.tr(),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.attach_file),
                label: Text(
                  evidenceFiles.isEmpty
                      ? 'report_upload_evidence'.tr()
                      : 'report_files_selected'.tr(
                      namedArgs: {'count': evidenceFiles.length.toString()}
                  ),
                ),
                onPressed: _pickEvidence,
              ),
              if (evidenceFiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 12.0, top: 4.0),
                  child: Text('report_evidence_required'.tr(), style: TextStyle(color: Colors.red)),
                ),
              const SizedBox(height: 24),
              Card(
                color: Colors.yellow[100],
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'report_warning'.tr(),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    TextButton(
                      onPressed: () async {
                        await _showTermsDialog();
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'report_terms_link'.tr(),
                            style: const TextStyle(
                              color: Colors.blue,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                          const Text(' *', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                    if (!disclaimerAccepted)
                      Text(
                        'report_terms_required_short'.tr(),
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    if (disclaimerAccepted)
                      const Icon(Icons.check, color: Colors.green, size: 18),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: (submitting ||
                    evidenceFiles.isEmpty ||
                    !disclaimerAccepted ||
                    incidentDate == null ||
                    school == null ||
                    !_formKey.currentState!.validate())
                    ? null
                    : _submitReport,
                child: submitting
                    ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : Text('report_submit_button'.tr()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}