import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  runApp(const SelphyPrintApp());
}

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestUsbPermission());
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
        {'filePath': _image!.path},
      );
      _setStatus(result ?? 'Done');
    } on PlatformException catch (e) {
      _setStatus('Error: ${e.message}');
    } finally {
      setState(() => _printing = false);
    }
  }

  void _setStatus(String msg) => setState(() => _status = msg);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Selphy CP1500 — USB Print'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
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
          ],
        ),
      ),
    );
  }
}
