// main.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Photos → PDFs → Email',
      theme: ThemeData(primarySwatch: Colors.blue),
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
  final List<String> _pdfPaths = [];
  final TextEditingController _baseNameController =
  TextEditingController(text: 'logical_reasoning');
  final TextEditingController _emailController = TextEditingController();
  bool _isProcessing = false;
  final Map<String, bool> _selected = {}; // path -> selected

  Future<void> _requestPermissions() async {
    await [
      Permission.camera,
      if (!Platform.isIOS) Permission.storage,
      if (Platform.isIOS) Permission.photos,
    ].request();
  }

  Future<void> _takePhoto() async {
    await _requestPermissions();
    try {
      final XFile? photo =
      await _picker.pickImage(source: ImageSource.camera, imageQuality: 85);
      if (photo != null) {
        setState(() => _photos.add(photo));
      }
    } catch (e) {
      _showSnack('Could not take photo: $e');
    }
  }

  // Convert each photo to a PDF and return list of PDF file paths
  Future<List<String>> _createPdfsFromPhotos({
    required List<XFile> photos,
    required String baseName,
  }) async {
    final List<String> createdPaths = [];
    final dir = await getTemporaryDirectory();
    final outputDir = Directory('${dir.path}/pdfs');

    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    for (int i = 0; i < photos.length; i++) {
      final XFile photo = photos[i];
      final Uint8List imageBytes = await photo.readAsBytes();

      final pdf = pw.Document();
      final image = pw.MemoryImage(imageBytes);

      pdf.addPage(
        pw.Page(
          build: (pw.Context context) {
            return pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain));
          },
        ),
      );

      final fileName =
          '${baseName.trim().isEmpty ? 'file' : baseName}_${i + 1}.pdf';
      final filePath = '${outputDir.path}/$fileName';
      final outFile = File(filePath);
      await outFile.writeAsBytes(await pdf.save());
      createdPaths.add(filePath);
    }
    return createdPaths;
  }

  Future<void> _generatePdfs() async {
    if (_photos.isEmpty) {
      _showSnack('Take at least one photo first.');
      return;
    }
    setState(() => _isProcessing = true);
    try {
      final baseName = _baseNameController.text.isEmpty
          ? 'logical_reasoning'
          : _baseNameController.text;
      final paths = await _createPdfsFromPhotos(
        photos: List<XFile>.from(_photos),
        baseName: baseName,
      );

      // confirm files exist
      final existPaths = <String>[];
      for (final p in paths) {
        final f = File(p);
        if (await f.exists()) existPaths.add(p);
      }

      setState(() {
        _pdfPaths.clear();
        _pdfPaths.addAll(existPaths);
        _selected.clear();
        for (var p in existPaths) {
          _selected[p] = true; // default selected
        }
      });

      _showSnack('Created ${existPaths.length} PDFs.');
    } catch (e) {
      _showSnack('Error creating PDFs: $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // Preview screen for a PDF file path
  void _openPdfViewer(String path) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PdfPreviewScreen(filePath: path),
    ));
  }

  // Send selected PDFs through email (flutter_email_sender)
  Future<void> _sendSelectedPdfs() async {
    final attachments = _pdfPaths.where((p) => _selected[p] == true).toList();
    if (attachments.isEmpty) {
      _showSnack('Select at least one PDF.');
      return;
    }

    // ✅ Ensure files exist and are PDFs
    for (var p in attachments) {
      final f = File(p);
      if (!await f.exists()) {
        _showSnack('Missing file: $p');
        return;
      }
      final header = String.fromCharCodes(await f.openRead(0, 4).first);
      if (!header.startsWith('%PDF')) {
        _showSnack('Not a valid PDF: $p');
        return;
      }
    }

    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _showSnack('Please enter recipient email.');
      return;
    }

    // ✅ Step 1: Share PDFs via Gmail
    await Share.shareXFiles(
      attachments.map((path) => XFile(path)).toList(), // ✅ convert string → XFile
      subject: 'Valuation PDFs - ${_baseNameController.text}',
      text: 'Attached are the PDF reports.\nTo: $email',
    );


    // ✅ Step 2: (Optional) Open Gmail compose pre-filled
    final Uri emailUri = Uri(
      scheme: 'mailto',
      path: email,
      queryParameters: {
        'subject': 'Valuation PDFs - ${_baseNameController.text}',
        'body': 'Attached are the generated PDF reports.',
      },
    );
    try {
      await launchUrl(emailUri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Could not open Gmail compose: $e');
    }
  }


  void _clearAll() {
    setState(() {
      _photos.clear();
      _pdfPaths.clear();
      _selected.clear();
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _baseNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final columns = 3;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photos → PDFs → Email'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_forever),
            onPressed: _photos.isEmpty && _pdfPaths.isEmpty ? null : _clearAll,
            tooltip: 'Clear all',
          )
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _takePhoto,
        icon: const Icon(Icons.camera_alt),
        label: const Text('Take Photo'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          TextField(
            controller: _baseNameController,
            decoration: const InputDecoration(
              labelText: 'Base filename (each PDF: base_1.pdf)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isProcessing ? null : _generatePdfs,
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('Generate PDFs from Photos'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _pdfPaths.isEmpty || _isProcessing ? null : _sendSelectedPdfs,
                icon: const Icon(Icons.send),
                label: const Text('Send Selected PDFs by Email'),
              ),
            )
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _emailController,
            decoration: const InputDecoration(
              labelText: 'Recipient email (To:)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 10),

          // Photos grid
          Expanded(
            flex: 1,
            child: _photos.isEmpty
                ? const Center(child: Text('No photos yet. Tap camera.'))
                : GridView.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns, mainAxisSpacing: 8, crossAxisSpacing: 8),
              itemCount: _photos.length,
              itemBuilder: (context, i) {
                return Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(File(_photos[i].path), fit: BoxFit.cover, width: double.infinity, height: double.infinity),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: InkWell(
                      onTap: () => setState(() => _photos.removeAt(i)),
                      child: const CircleAvatar(radius: 14, backgroundColor: Colors.black54, child: Icon(Icons.close, size: 16, color: Colors.white)),
                    ),
                  )
                ]);
              },
            ),
          ),

          const SizedBox(height: 10),
          // PDF list and selection
          Expanded(
            flex: 1,
            child: _pdfPaths.isEmpty
                ? const Center(child: Text('No PDFs generated yet.'))
                : ListView.builder(
              itemCount: _pdfPaths.length,
              itemBuilder: (context, index) {
                final p = _pdfPaths[index];
                final name = p.split('/').last;
                final selected = _selected[p] ?? false;
                return ListTile(
                  leading: Checkbox(
                    value: selected,
                    onChanged: (v) => setState(() => _selected[p] = v ?? false),
                  ),
                  title: Text(name),
                  trailing: IconButton(
                    icon: const Icon(Icons.visibility),
                    onPressed: () => _openPdfViewer(p),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

// Simple PDF preview page using flutter_pdfview
class PdfPreviewScreen extends StatefulWidget {
  final String filePath;
  const PdfPreviewScreen({super.key, required this.filePath});

  @override
  State<PdfPreviewScreen> createState() => _PdfPreviewScreenState();
}

class _PdfPreviewScreenState extends State<PdfPreviewScreen> {
  bool isReady = false;
  int pages = 0;
  late PDFViewController pdfController;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.filePath.split('/').last),
      ),
      body: Stack(children: [
        PDFView(
          filePath: widget.filePath,
          enableSwipe: true,
          swipeHorizontal: false,
          autoSpacing: true,
          pageFling: true,
          onRender: (n) {
            setState(() {
              pages = n ?? 0;
              isReady = true;
            });
          },
          onViewCreated: (controller) {
            pdfController = controller;
          },
          onError: (error) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF error: $error')));
          },
        ),
        if (!isReady)
          const Center(child: CircularProgressIndicator()),
      ]),
    );
  }
}
