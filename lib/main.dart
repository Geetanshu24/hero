import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Photo → PDF Sharer',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();
  final List<XFile> _photos = [];
  final TextEditingController _baseNameController =
  TextEditingController(text: 'logical_reasoning');
  final TextEditingController _emailController =
  TextEditingController(text: ''); // <-- new field for email
  bool _isProcessing = false;

  Future<void> _requestPermissions() async {
    await [Permission.camera, Permission.photos, Permission.storage].request();
  }

  Future<void> _takePhoto() async {
    await _requestPermissions();
    try {
      final XFile? photo =
      await _picker.pickImage(source: ImageSource.camera, imageQuality: 85);
      if (photo != null) setState(() => _photos.add(photo));
    } catch (e) {
      _showSnack('Could not take photo: $e');
    }
  }

  Future<List<String>> _createPdfsFromPhotos(
      {required List<XFile> photos, required String baseName}) async {
    final List<String> createdPaths = [];
    final dir = await getTemporaryDirectory();
    final outputDir = Directory('${dir.path}/pdfs');
    if (!await outputDir.exists()) await outputDir.create(recursive: true);

    for (int i = 0; i < photos.length; i++) {
      final XFile photo = photos[i];
      final Uint8List imageBytes = await photo.readAsBytes();
      final pdf = pw.Document();
      final image = pw.MemoryImage(imageBytes);
      pdf.addPage(pw.Page(
        build: (pw.Context context) => pw.Center(
          child: pw.Image(image, fit: pw.BoxFit.contain),
        ),
      ));
      final fileName =
          '${baseName.trim().isEmpty ? 'file' : baseName}_${i + 1}.pdf';
      final filePath = '${outputDir.path}/$fileName';
      final outFile = File(filePath);
      await outFile.writeAsBytes(await pdf.save());
      createdPaths.add(filePath);
    }
    return createdPaths;
  }


  Future<void> _createAndShare() async {
    if (_photos.isEmpty) {
      _showSnack('Please take at least one photo.');
      return;
    }

    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _showSnack('Please enter an email address.');
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final baseName = _baseNameController.text.isEmpty
          ? 'logical_reasoning'
          : _baseNameController.text;

      // ✅ Step 1: Create PDFs (1 photo = 1 PDF)
      final pdfPaths = await _createPdfsFromPhotos(
        photos: List<XFile>.from(_photos),
        baseName: baseName,
      );

      if (pdfPaths.isEmpty) {
        _showSnack('No PDFs created.');
        return;
      }

      // ✅ Step 2: Ensure PDF files actually exist
      for (var path in pdfPaths) {
        final file = File(path);
        if (!await file.exists()) {
          _showSnack('PDF missing at $path');
          return;
        }
      }

      // ✅ Step 3: Create Gmail compose with only PDFs attached
      final Email mail = Email(
        body:
        'Attached are the generated PDF reports.\n\nRegards,\nLogical Reasoning App',
        subject: 'Valuation PDFs - $baseName',
        recipients: [email],
        attachmentPaths: pdfPaths, // <-- only PDFs go here
        isHTML: false,
      );

      await FlutterEmailSender.send(mail);
      _showSnack('📤 Opening Gmail compose with PDFs attached...');
    } catch (e) {
      _showSnack('Error sending PDFs: $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }



  void _clearAll() => setState(() => _photos.clear());

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Photos → PDFs & Gmail')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _takePhoto,
        icon: const Icon(Icons.camera_alt),
        label: const Text('Take Photo'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: _baseNameController,
              decoration: const InputDecoration(
                labelText: 'Base filename',
                prefixIcon: Icon(Icons.edit),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _emailController,
              decoration: const InputDecoration(
                labelText: 'Recipient Gmail address',
                prefixIcon: Icon(Icons.email_outlined),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: _isProcessing ? null : _createAndShare,
              icon: const Icon(Icons.picture_as_pdf),
              label: Text(
                _isProcessing ? 'Processing...' : 'Create PDFs & Send Email',
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _photos.isEmpty
                  ? const Center(child: Text('No photos yet.'))
                  : GridView.builder(
                itemCount: _photos.length,
                gridDelegate:
                const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemBuilder: (context, i) => Image.file(
                  File(_photos[i].path),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
