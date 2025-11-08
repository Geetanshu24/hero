// main.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path/path.dart' as p;
import 'package:android_intent_plus/android_intent.dart';
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

  final MethodChannel _channel = const MethodChannel('app.channel.shared/files');
  // ---------- permissions & photo ----------
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

  Future<bool> _sendEmailNative({
    required String recipient,
    required String subject,
    required String body,
    required List<String> filePaths,
  }) async {
    try {
      final args = {
        'to': [recipient],
        'subject': subject,
        'body': body,
        'paths': filePaths,
      };
      final res = await _channel.invokeMethod('sendEmailWithAttachments', args);
      return res == true;
    } on PlatformException catch (e) {
      debugPrint('Native email send failed: ${e.code} ${e.message}');
      return false;
    } catch (e) {
      debugPrint('Native email send unexpected: $e');
      return false;
    }
  }

  // ---------- helper: format bytes ----------
  String formatBytes(int bytes, [int decimals = 2]) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    final i = (log(bytes) / log(1024)).floor();
    final value = bytes / pow(1024, i);
    return "${value.toStringAsFixed(decimals)} ${suffixes[i]}";
  }

  // ---------- create single-page PDFs (1 per image), compressed ----------
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

    // Compression settings
    const int quality = 65; // 40-80 recommended
    const int minWidth = 1200;

    for (int i = 0; i < photos.length; i++) {
      final XFile photo = photos[i];

      // read bytes
      Uint8List originalBytes;
      try {
        originalBytes = await photo.readAsBytes();
      } catch (e) {
        debugPrint('Failed to read image bytes for ${photo.path}: $e');
        continue;
      }

      // compress with safe fallback if plugin missing or fails
      Uint8List compressedBytes;
      try {
        if (Platform.isAndroid || Platform.isIOS) {

          final comp = await FlutterImageCompress.compressWithList(
            originalBytes,
            quality: quality,
            minWidth: minWidth,
          );
          compressedBytes = (comp != null && comp.isNotEmpty) ? comp : originalBytes;
        } else {
          compressedBytes = originalBytes;
        }
      } on MissingPluginException catch (mp) {
        debugPrint('Image compress plugin not found: $mp — using original bytes');
        compressedBytes = originalBytes;
      } catch (e) {
        debugPrint('Compression failed for ${photo.path}: $e');
        compressedBytes = originalBytes;
      }

      // make pdf single page
      try {
        final pdf = pw.Document();
        final image = pw.MemoryImage(compressedBytes);

        pdf.addPage(
          pw.Page(
            build: (pw.Context ctx) {
              return pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain));
            },
          ),
        );

        final safeBase = baseName.trim().isEmpty ? 'file' : baseName.trim();
        final fileName = '${safeBase}_${i + 1}.pdf';
        final filePath = p.join(outputDir.path, fileName);
        final outFile = File(filePath);
        final pdfBytes = await pdf.save();
        await outFile.writeAsBytes(pdfBytes, flush: true);
        createdPaths.add(filePath);
        debugPrint('Created PDF: $filePath  size=${formatBytes(pdfBytes.length)}');
      } catch (e) {
        debugPrint('Failed to create PDF for ${photo.path}: $e');
      }
    }

    return createdPaths;
  }

  // ---------- generate pdfs and update state ----------
  Future<void> _generatePdfs() async {
    if (_photos.isEmpty) {
      _showSnack('Take at least one photo first.');
      return;
    }
    setState(() => _isProcessing = true);
    try {
      final baseName =
      _baseNameController.text.isEmpty ? 'logical_reasoning' : _baseNameController.text;
      final paths = await _createPdfsFromPhotos(photos: List<XFile>.from(_photos), baseName: baseName);

      // confirm files exist
      final existPaths = <String>[];
      for (final pth in paths) {
        final f = File(pth);
        if (await f.exists()) existPaths.add(pth);
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
      // Optionally show sizes
      await _showPdfSizesDialog(context, existPaths);
    } catch (e) {
      _showSnack('Error creating PDFs: $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // ---------- preview ----------
  void _openPdfViewer(String path) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PdfPreviewScreen(filePath: path)));
  }

  // ---------- copy file to cache (for FileProvider) ----------
  Future<String> _copyToCacheAndReturn(String srcPath) async {
    final srcFile = File(srcPath);
    if (!await srcFile.exists()) throw Exception('Source file missing');
    final cacheDir = await getTemporaryDirectory();
    final destPath = p.join(cacheDir.path, p.basename(srcPath));
    final destFile = File(destPath);
    await destFile.writeAsBytes(await srcFile.readAsBytes(), flush: true);
    return destFile.path;
  }

  // ---------- show sizes dialog ----------
  Future<List<Map<String, dynamic>>> _getPdfFilesInfo(List<String> paths) async {
    final List<Map<String, dynamic>> info = [];
    for (final pth in paths) {
      final f = File(pth);
      if (!await f.exists()) continue;
      final stat = await f.stat();
      final size = stat.size;
      final modified = stat.modified;
      info.add({
        'path': pth,
        'name': pth.split('/').last,
        'sizeBytes': size,
        'sizeFormatted': formatBytes(size),
        'modified': modified,
      });
    }
    return info;
  }

  Future<void> _showPdfSizesDialog(BuildContext context, List<String> paths) async {
    final info = await _getPdfFilesInfo(paths);
    if (info.isEmpty) {
      _showSnack('No PDF files found.');
      return;
    }

    int totalBytes = 0;
    for (final f in info) totalBytes += (f['sizeBytes'] as int);

    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('PDFs (${info.length}) — Total ${formatBytes(totalBytes)}'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: info.length,
              separatorBuilder: (_, __) => const Divider(height: 8),
              itemBuilder: (context, i) {
                final f = info[i];
                final name = f['name'] as String;
                final size = f['sizeFormatted'] as String;
                final modified = f['modified'] as DateTime;
                final modifiedStr =
                    "${modified.year}-${modified.month.toString().padLeft(2, '0')}-${modified.day.toString().padLeft(2, '0')} ${modified.hour.toString().padLeft(2, '0')}:${modified.minute.toString().padLeft(2, '0')}";
                return ListTile(
                  dense: true,
                  title: Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: Text('$size • $modifiedStr', style: const TextStyle(fontSize: 12)),
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            TextButton(
              onPressed: () {
                final summary = StringBuffer();
                summary.writeln('PDFs (${info.length}) — Total ${formatBytes(totalBytes)}');
                for (final f in info) {
                  summary.writeln('${f['name']} — ${f['sizeFormatted']} — ${f['modified']}');
                }
                Share.share(summary.toString(), subject: 'PDFs summary');
              },
              child: const Text('Share'),
            ),
          ],
        );
      },
    );
  }

  // ---------- send selected PDFs (native composer with To: + attachments) ----------
  Future<void> _sendSelectedPdfs() async {
    final attachments = _pdfPaths.where((p) => _selected[p] == true).toList();
    if (attachments.isEmpty) {
      _showSnack('Select at least one PDF.');
      return;
    }

    // validate & copy to cache (FileProvider-friendly)
    final List<String> sharedPaths = [];
    try {
      for (var pth in attachments) {
        final f = File(pth);
        if (!await f.exists()) {
          _showSnack('Missing file: $pth');
          return;
        }
        // simple PDF header check
        final headerBytes = await f.openRead(0, 4).first;
        final header = String.fromCharCodes(headerBytes);
        if (!header.startsWith('%PDF')) {
          _showSnack('Not a valid PDF: ${p.basename(pth)}');
          return;
        }

        final copied = await _copyToCacheAndReturn(pth);
        sharedPaths.add(copied);
      }
    } catch (e) {
      _showSnack('Failed prepare attachments: $e');
      return;
    }

    final recipient = _emailController.text.trim();
    if (recipient.isEmpty) {
      _showSnack('Please enter recipient email.');
      return;
    }

    final subject = 'Photos PDFs - ${_baseNameController.text}';
    final body = 'Attached are the generated PDF reports.';

    try {
      if (Platform.isAndroid) {
        final success = await _sendEmailNative(
          recipient: recipient,
          subject: subject,
          body: body,
          filePaths: sharedPaths, // paths copied to cache earlier
        );
        if (success) return;

        debugPrint('Native send reported failure — falling back to Share');
        return;
      }

      // if (Platform.isIOS) {
      //   final email = Email(
      //     body: body,
      //     subject: subject,
      //     recipients: [recipient],
      //     attachmentPaths: sharedPaths,
      //     isHTML: false,
      //   );
      //   await FlutterEmailSender.send(email);
      //   return;
      // }

      // fallback for web/desktop: share + mailto
      await Share.shareXFiles(
        sharedPaths.map((p) => XFile(p)).toList(),
        subject: subject,
        text: '$body\n\nTo: $recipient',
      );
    } catch (e) {
      debugPrint('Error sending email: $e');
      _showSnack('Error sending email: $e');
    }
  }

  // ---------- rest UI helpers ----------
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

  // ---------- UI ----------
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
                    child: Image.file(File(_photos[i].path),
                        fit: BoxFit.cover, width: double.infinity, height: double.infinity),
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
                final pth = _pdfPaths[index];
                final name = pth.split('/').last;
                final selected = _selected[pth] ?? false;
                return ListTile(
                  leading: Checkbox(
                    value: selected,
                    onChanged: (v) => setState(() => _selected[pth] = v ?? false),
                  ),
                  title: Text(name),
                  trailing: IconButton(
                    icon: const Icon(Icons.visibility),
                    onPressed: () => _openPdfViewer(pth),
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

// PDF preview page
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
        if (!isReady) const Center(child: CircularProgressIndicator()),
      ]),
    );
  }
}
