import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const SelphyPrintApp());
}

// ── PrintSettings ─────────────────────────────────────────────────────────────

class PrintSettings {
  final int copies;
  final String filter;
  final int brightness;
  final bool bordered;

  static const _filterOptions = ['Off', 'Vivid', 'B&W', 'Sepia'];

  const PrintSettings({
    this.copies = 1,
    this.filter = 'Off',
    this.brightness = 0,
    this.bordered = false,
  });

  Map<String, dynamic> toMap() => {
        'copies': copies,
        'filter': filter,
        'brightness': brightness,
        'bordered': bordered,
      };

  PrintSettings copyWith({
    int? copies,
    String? filter,
    int? brightness,
    bool? bordered,
  }) =>
      PrintSettings(
        copies: copies ?? this.copies,
        filter: filter ?? this.filter,
        brightness: brightness ?? this.brightness,
        bordered: bordered ?? this.bordered,
      );

  static PrintSettings fromPrefs(SharedPreferences prefs) => PrintSettings(
        copies: prefs.getInt('ps_copies') ?? 1,
        filter: prefs.getString('ps_filter') ?? 'Off',
        brightness: prefs.getInt('ps_brightness') ?? 0,
        bordered: prefs.getBool('ps_bordered') ?? false,
      );

  Future<void> saveToPrefs(SharedPreferences prefs) async {
    await prefs.setInt('ps_copies', copies);
    await prefs.setString('ps_filter', filter);
    await prefs.setInt('ps_brightness', brightness);
    await prefs.setBool('ps_bordered', bordered);
  }
}

// ── App ───────────────────────────────────────────────────────────────────────

class SelphyPrintApp extends StatelessWidget {
  const SelphyPrintApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Selphy Print',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
        useMaterial3: true,
      ),
      home: const PrintScreen(),
    );
  }
}

// ── PrintScreen ───────────────────────────────────────────────────────────────

class PrintScreen extends StatefulWidget {
  const PrintScreen({super.key});

  @override
  State<PrintScreen> createState() => _PrintScreenState();
}

class _PrintScreenState extends State<PrintScreen> {
  static const _channel = MethodChannel('com.mindoula.canon_selphy_print/usb');

  final _picker = ImagePicker();
  File? _image;
  String _status = '';
  bool _printing = false;
  bool _printerReady = false;
  PrintSettings _settings = const PrintSettings();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestUsbPermission());
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _settings = PrintSettings.fromPrefs(prefs));
  }

  Future<void> _requestUsbPermission() async {
    setState(() => _status = 'Looking for printer…');
    try {
      final msg = await _channel.invokeMethod<String>('requestPermission');
      setState(() {
        _printerReady = true;
        _status = msg ?? 'Printer ready';
      });
    } on PlatformException catch (e) {
      setState(() {
        _printerReady = false;
        _status = e.message ?? 'Printer not found';
      });
    }
  }

  Future<void> _pick(ImageSource source) async {
    final picked = await _picker.pickImage(source: source, imageQuality: 100);
    if (picked != null) {
      setState(() {
        _image = File(picked.path);
        _status = _printerReady ? 'Printer ready' : _status;
      });
    }
  }

  Future<void> _print() async {
    if (_image == null) {
      _setStatus('Please select a photo first.');
      return;
    }
    setState(() {
      _printing = true;
      _status = 'Sending to printer…';
    });
    try {
      final result = await _channel.invokeMethod<String>(
        'print',
        {
          'filePath': _image!.path,
          ..._settings.toMap(),
        },
      );
      _setStatus(result ?? 'Done');
    } on PlatformException catch (e) {
      _setStatus('Error: ${e.message}');
    } finally {
      setState(() => _printing = false);
    }
  }

  void _setStatus(String msg) => setState(() => _status = msg);

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _SettingsSheet(
        initial: _settings,
        onSave: (updated) async {
          final prefs = await SharedPreferences.getInstance();
          await updated.saveToPrefs(prefs);
          setState(() => _settings = updated);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final copiesLabel = _settings.copies == 1 ? '1 copy' : '${_settings.copies} copies';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Selphy CP1500 — USB Print'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Print settings',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-check printer',
            onPressed: _requestUsbPermission,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Printer status banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _printerReady
                    ? Colors.green.shade50
                    : Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _printerReady
                      ? Colors.green.shade300
                      : Colors.orange.shade300,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _printerReady ? Icons.print : Icons.print_disabled,
                    size: 18,
                    color: _printerReady
                        ? Colors.green.shade700
                        : Colors.orange.shade700,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _status,
                      style: TextStyle(
                        color: _printerReady
                            ? Colors.green.shade700
                            : Colors.orange.shade700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.photo_library),
                    label: const Text('Photo Library'),
                    onPressed: () => _pick(ImageSource.gallery),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Camera'),
                    onPressed: () => _pick(ImageSource.camera),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _image != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(_image!, fit: BoxFit.contain),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(
                        child: Text(
                          'No photo selected',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  icon: _printing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.print),
                  label: Text(_printing ? 'Printing…' : 'Print'),
                  onPressed: (_printing || !_printerReady) ? null : _print,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  copiesLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Settings bottom sheet ─────────────────────────────────────────────────────

class _SettingsSheet extends StatefulWidget {
  final PrintSettings initial;
  final Future<void> Function(PrintSettings) onSave;

  const _SettingsSheet({required this.initial, required this.onSave});

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late PrintSettings _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Print Settings',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Copies
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Copies', style: TextStyle(fontSize: 16)),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove),
                    onPressed: _draft.copies > 1
                        ? () => setState(() => _draft = _draft.copyWith(copies: _draft.copies - 1))
                        : null,
                  ),
                  Text(
                    '${_draft.copies}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: _draft.copies < 5
                        ? () => setState(() => _draft = _draft.copyWith(copies: _draft.copies + 1))
                        : null,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Borders
          Align(
            alignment: Alignment.centerLeft,
            child: const Text('Borders', style: TextStyle(fontSize: 16)),
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Borderless')),
              ButtonSegment(value: true, label: Text('Bordered')),
            ],
            selected: {_draft.bordered},
            onSelectionChanged: (v) => setState(() => _draft = _draft.copyWith(bordered: v.first)),
          ),
          const SizedBox(height: 16),

          // Filter
          Align(
            alignment: Alignment.centerLeft,
            child: const Text('Filter', style: TextStyle(fontSize: 16)),
          ),
          const SizedBox(height: 8),
          Wrap(
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'Off', label: Text('Off')),
                  ButtonSegment(value: 'Vivid', label: Text('Vivid')),
                  ButtonSegment(value: 'B&W', label: Text('B&W')),
                  ButtonSegment(value: 'Sepia', label: Text('Sepia')),
                ],
                selected: {_draft.filter},
                onSelectionChanged: (v) => setState(() => _draft = _draft.copyWith(filter: v.first)),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Brightness
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Brightness', style: TextStyle(fontSize: 16)),
              Text(
                _draft.brightness == 0
                    ? '0'
                    : (_draft.brightness > 0 ? '+${_draft.brightness}' : '${_draft.brightness}'),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          Slider(
            min: -3,
            max: 3,
            divisions: 6,
            value: _draft.brightness.toDouble(),
            label: _draft.brightness.toString(),
            onChanged: (v) => setState(() => _draft = _draft.copyWith(brightness: v.round())),
          ),
          const SizedBox(height: 24),

          // Save
          FilledButton(
            onPressed: () async {
              await widget.onSave(_draft);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
