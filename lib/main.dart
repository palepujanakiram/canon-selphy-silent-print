import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Shared MethodChannel — used by both screens.
const _channel = MethodChannel('com.mindoula.canon_selphy_print/usb');

void main() {
  runApp(const SelphyPrintApp());
}

// ── PrintSettings ─────────────────────────────────────────────────────────────

class PrintSettings {
  final int copies;
  final String paperSize;
  final String filter;
  final int brightness;
  final bool bordered;

  static const paperSizes = ['4x6', 'L-size', 'Card'];

  const PrintSettings({
    this.copies = 1,
    this.paperSize = '4x6',
    this.filter = 'Off',
    this.brightness = 0,
    this.bordered = false,
  });

  Map<String, dynamic> toMap() => {
        'copies': copies,
        'paperSize': paperSize,
        'filter': filter,
        'brightness': brightness,
        'bordered': bordered,
      };

  PrintSettings copyWith({
    int? copies,
    String? paperSize,
    String? filter,
    int? brightness,
    bool? bordered,
  }) =>
      PrintSettings(
        copies: copies ?? this.copies,
        paperSize: paperSize ?? this.paperSize,
        filter: filter ?? this.filter,
        brightness: brightness ?? this.brightness,
        bordered: bordered ?? this.bordered,
      );

  static PrintSettings fromPrefs(SharedPreferences prefs) => PrintSettings(
        copies: prefs.getInt('ps_copies') ?? 1,
        paperSize: prefs.getString('ps_paperSize') ?? '4x6',
        filter: prefs.getString('ps_filter') ?? 'Off',
        brightness: prefs.getInt('ps_brightness') ?? 0,
        bordered: prefs.getBool('ps_bordered') ?? false,
      );

  Future<void> saveToPrefs(SharedPreferences prefs) async {
    await prefs.setInt('ps_copies', copies);
    await prefs.setString('ps_paperSize', paperSize);
    await prefs.setString('ps_filter', filter);
    await prefs.setInt('ps_brightness', brightness);
    await prefs.setBool('ps_bordered', bordered);
  }

  // Aspect ratio (width / height) for the chosen paper size.
  double get paperAspectRatio {
    switch (paperSize) {
      case 'L-size': return 1054 / 1409;
      case 'Card':   return 1018 / 640;
      default:       return 1184 / 1752; // 4x6
    }
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
      home: const PhotoPickScreen(),
    );
  }
}

// ── Screen 1: Photo pick ──────────────────────────────────────────────────────

class PhotoPickScreen extends StatefulWidget {
  const PhotoPickScreen({super.key});

  @override
  State<PhotoPickScreen> createState() => _PhotoPickScreenState();
}

class _PhotoPickScreenState extends State<PhotoPickScreen> {
  final _picker = ImagePicker();
  File? _image;
  PrintSettings _settings = const PrintSettings();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _settings = PrintSettings.fromPrefs(prefs));
  }

  Future<void> _pick(ImageSource source) async {
    final picked = await _picker.pickImage(source: source, imageQuality: 100);
    if (picked != null) setState(() => _image = File(picked.path));
  }

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

  void _goToPreview() {
    if (_image == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a photo first.')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PreviewScreen(image: _image!, settings: _settings),
      ),
    );
  }

  String get _settingsSummary {
    final s = _settings;
    final brightnessLabel = s.brightness == 0
        ? '0'
        : '${s.brightness > 0 ? '+' : ''}${s.brightness}';
    return [
      '${s.copies == 1 ? '1 copy' : '${s.copies} copies'}',
      s.paperSize,
      s.bordered ? 'Bordered' : 'Borderless',
      'Filter: ${s.filter}',
      'Brightness: $brightnessLabel',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Selphy CP1500 — USB Print'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            // Print Settings button + summary
            OutlinedButton.icon(
              icon: const Icon(Icons.settings),
              label: const Text('Print Settings'),
              onPressed: _openSettings,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _settingsSummary,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.preview),
              label: const Text('Preview'),
              onPressed: _goToPreview,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

// ── Screen 2: Preview + Print ─────────────────────────────────────────────────

class PreviewScreen extends StatefulWidget {
  final File image;
  final PrintSettings settings;

  const PreviewScreen({super.key, required this.image, required this.settings});

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  String _status = '';
  bool _printerReady = false;
  bool _printing = false;
  late final Future<ui.Image> _imageSizeFuture;

  @override
  void initState() {
    super.initState();
    // Decode image dimensions (EXIF-corrected) to detect landscape vs portrait.
    _imageSizeFuture = widget.image
        .readAsBytes()
        .then((bytes) => decodeImageFromList(bytes));
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkPrinter());
  }

  Future<void> _checkPrinter() async {
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

  Future<void> _print() async {
    setState(() {
      _printing = true;
      _status = 'Sending to printer…';
    });
    try {
      final result = await _channel.invokeMethod<String>(
        'print',
        {
          'filePath': widget.image.path,
          ...widget.settings.toMap(),
        },
      );
      setState(() => _status = result ?? 'Done');
    } on PlatformException catch (e) {
      setState(() => _status = 'Error: ${e.message}');
    } finally {
      setState(() => _printing = false);
    }
  }

  // Build the ColorFilter that represents the active filter + brightness.
  ColorFilter? _buildColorFilter() {
    // Brightness offset: -3..+3 → -60..+60 (out of 255).
    final b = widget.settings.brightness * 20.0;

    // Per-filter base matrix (row-major, 4×5).
    List<double> m;
    switch (widget.settings.filter) {
      case 'B&W':
        m = [
          0.2126, 0.7152, 0.0722, 0, b,
          0.2126, 0.7152, 0.0722, 0, b,
          0.2126, 0.7152, 0.0722, 0, b,
          0,      0,      0,      1, 0,
        ];
      case 'Sepia':
        m = [
          0.393, 0.769, 0.189, 0, b,
          0.349, 0.686, 0.168, 0, b,
          0.272, 0.534, 0.131, 0, b,
          0,     0,     0,     1, 0,
        ];
      case 'Vivid':
        // Increase saturation (~1.6×).
        const s = 1.6;
        const sr = (1 - s) * 0.2126;
        const sg = (1 - s) * 0.7152;
        const sb = (1 - s) * 0.0722;
        m = [
          sr + s, sg,     sb,     0, b,
          sr,     sg + s, sb,     0, b,
          sr,     sg,     sb + s, 0, b,
          0,      0,      0,      1, 0,
        ];
      default: // 'Off'
        if (b == 0) return null; // no-op
        m = [1, 0, 0, 0, b,  0, 1, 0, 0, b,  0, 0, 1, 0, b,  0, 0, 0, 1, 0];
    }
    return ColorFilter.matrix(m);
  }

  Widget _buildPreview() {
    final s = widget.settings;
    final colorFilter = _buildColorFilter();
    final paperIsLandscape = s.paperAspectRatio > 1;

    return FutureBuilder<ui.Image>(
      future: _imageSizeFuture,
      builder: (context, snapshot) {
        // Show a placeholder until dimensions are known.
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final info = snapshot.data!;
        final srcIsLandscape = info.width > info.height;
        // Rotate 90° when source and paper orientations differ.
        final needsRotation = srcIsLandscape != paperIsLandscape;

        // Base image — BoxFit.cover fills whatever space it's given.
        Widget photo = Image.file(widget.image, fit: BoxFit.cover);

        if (needsRotation) {
          // RotatedBox swaps layout dimensions so BoxFit.cover fills correctly.
          photo = RotatedBox(quarterTurns: 1, child: photo);
        }

        if (colorFilter != null) {
          photo = ColorFiltered(colorFilter: colorFilter, child: photo);
        }

        // Bordered: inset the image and show white margins.
        if (s.bordered) {
          photo = Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: photo,
          );
        }

        // Constrain to the paper's aspect ratio with a paper-like shadow.
        return Center(
          child: AspectRatio(
            aspectRatio: s.paperAspectRatio,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: photo,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final subtitle =
        '${s.copies == 1 ? '1 copy' : '${s.copies} copies'} · ${s.paperSize}'
        '${s.bordered ? ' · Bordered' : ''}'
        '${s.filter != 'Off' ? ' · ${s.filter}' : ''}'
        '${s.brightness != 0 ? ' · ${s.brightness > 0 ? '+' : ''}${s.brightness}' : ''}';

    return Scaffold(
      backgroundColor: Colors.grey.shade200,
      appBar: AppBar(
        title: const Text('Preview'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-check printer',
            onPressed: _checkPrinter,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Printer status banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _printerReady ? Colors.green.shade50 : Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _printerReady ? Colors.green.shade300 : Colors.orange.shade300,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _printerReady ? Icons.print : Icons.print_disabled,
                    size: 18,
                    color: _printerReady ? Colors.green.shade700 : Colors.orange.shade700,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _status,
                      style: TextStyle(
                        color: _printerReady ? Colors.green.shade700 : Colors.orange.shade700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Photo preview
            Expanded(child: _buildPreview()),

            const SizedBox(height: 16),

            // Settings summary
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),

            // Print button
            FilledButton.icon(
              icon: _printing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.print),
              label: Text(_printing ? 'Printing…' : 'Print'),
              onPressed: (_printing || !_printerReady) ? null : _print,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
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
        bottom: MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).padding.bottom +
            24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Print Settings',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center),
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
                  Text('${_draft.copies}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
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

          // Paper Size
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Paper Size', style: TextStyle(fontSize: 16)),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '4x6',    label: Text('4×6')),
              ButtonSegment(value: 'L-size', label: Text('L-size')),
              ButtonSegment(value: 'Card',   label: Text('Card')),
            ],
            selected: {_draft.paperSize},
            onSelectionChanged: (v) =>
                setState(() => _draft = _draft.copyWith(paperSize: v.first)),
          ),
          const SizedBox(height: 16),

          // Borders
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Borders', style: TextStyle(fontSize: 16)),
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Borderless')),
              ButtonSegment(value: true,  label: Text('Bordered')),
            ],
            selected: {_draft.bordered},
            onSelectionChanged: (v) =>
                setState(() => _draft = _draft.copyWith(bordered: v.first)),
          ),
          const SizedBox(height: 16),

          // Filter
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Filter', style: TextStyle(fontSize: 16)),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'Off',   label: Text('Off')),
              ButtonSegment(value: 'Vivid', label: Text('Vivid')),
              ButtonSegment(value: 'B&W',   label: Text('B&W')),
              ButtonSegment(value: 'Sepia', label: Text('Sepia')),
            ],
            selected: {_draft.filter},
            onSelectionChanged: (v) =>
                setState(() => _draft = _draft.copyWith(filter: v.first)),
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
            onChanged: (v) =>
                setState(() => _draft = _draft.copyWith(brightness: v.round())),
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
