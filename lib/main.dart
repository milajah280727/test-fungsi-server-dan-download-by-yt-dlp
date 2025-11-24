import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'dart:convert';

void main() {
  runApp(const MyApp());
  // LANGSUNG CEK & MINTA IZIN PAS APP DIBUKA!
  WidgetsFlutterBinding.ensureInitialized();
  _requestStoragePermission();
}

Future<void> _requestStoragePermission() async {
  if (Platform.isAndroid) {
    // Android 13+ (API 33+) → Pakai Photos/Video atau Manage Storage
    var status = await Permission.photos.status;
    if (!status.isGranted) {
      status = await Permission.photos.request();
    }
    if (!status.isGranted) {
      status = await Permission.videos.request();
    }
    // Kalau masih ditolak → paksa manage external storage (Android 11-12)
    if (!status.isGranted) {
      await Permission.manageExternalStorage.request();
    }
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YouTube Downloader 1080p+',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _controller = TextEditingController();

  // GANTI DENGAN SERVER KAMU YANG SUDAH JALAN!
  final String serverUrl = "https://yt-dlp-server-yplayer.vercel.app";

  Map<String, dynamic>? _videoInfo;
  bool _isFetching = false;
  bool _isDownloading = false;
  double _progress = 0.0;
  String _status = 'Siap download!';

  @override
  void initState() {
    super.initState();
    // Pastikan izin sudah ada sebelum mulai
    _checkPermissionAndShowMessage();
  }

  Future<void> _checkPermissionAndShowMessage() async {
    if (Platform.isAndroid) {
      var status = await Permission.photos.status;
      if (!status.isGranted) status = await Permission.videos.status;
      if (!status.isGranted) status = await Permission.manageExternalStorage.status;

      if (!status.isGranted) {
        setState(() => _status = '⚠️ Izin penyimpanan dibutuhkan! Buka pengaturan → Izinkan akses foto/video');
      }
    }
  }

  Future<void> _fetchVideoInfo() async {
    final url = _controller.text.trim();
    if (url.isEmpty || (!url.contains('youtube.com') && !url.contains('youtu.be'))) {
      setState(() => _status = 'Link YouTube tidak valid!');
      return;
    }

    setState(() {
      _isFetching = true;
      _status = 'Mengambil info video...';
      _videoInfo = null;
    });

    try {
      final response = await http.get(Uri.parse('$serverUrl/info?url=$url')).timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        setState(() {
          _videoInfo = json;
          _status = 'Siap download 1080p + audio!';
        });
      } else {
        setState(() => _status = 'Server error: ${response.statusCode}');
      }
    } catch (e) {
      setState(() => _status = 'Gagal koneksi: $e');
    } finally {
      setState(() => _isFetching = false);
    }
  }

  Future<Directory> _getDownloadDir() async {
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Download');
      if (await dir.exists()) return dir;
    }
    return await getDownloadsDirectory() ?? await getTemporaryDirectory();
  }

  Future<void> _downloadVideo() async {
    final url = _controller.text.trim();
    if (_videoInfo == null) {
      setState(() => _status = 'Ambil info video dulu!');
      return;
    }

    // CEK LAGI IZIN SEBELUM DOWNLOAD
    if (Platform.isAndroid) {
      var status = await Permission.photos.status;
      if (!status.isGranted) status = await Permission.videos.status;
      if (!status.isGranted) status = await Permission.manageExternalStorage.status;

      if (!status.isGranted) {
        setState(() => _status = 'Izin penyimpanan ditolak! Buka pengaturan app → Izinkan akses');
        openAppSettings();
        return;
      }
    }

    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _status = 'Memulai download...';
    });

    try {
      final downloadUrl = Uri.parse('$serverUrl/download?url=$url&q=1080');
      final request = http.Request('GET', downloadUrl);
      final response = await http.Client().send(request).timeout(const Duration(minutes: 5));

      if (response.statusCode != 200) {
        setState(() => _status = 'Server error: ${response.statusCode}');
        return;
      }

      final dir = await _getDownloadDir();
      final title = (_videoInfo!['title'] ?? 'Video')
          .toString()
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
          .trim();
      final filename = '$title - 1080p.mp4';
      final file = File('${dir.path}/$filename');

      final totalBytes = response.contentLength ?? 0;
      int received = 0;
      final bytes = <int>[];

      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (totalBytes > 0) {
          setState(() {
            _progress = received / totalBytes;
            _status = 'Downloading... ${(_progress * 100).toStringAsFixed(0)}%';
          });
        }
      }

      await file.writeAsBytes(bytes);

      setState(() {
        _status = 'SELESAI! Tersimpan di folder Download';
        _progress = 1.0;
      });

      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download selesai: $filename'), duration: const Duration(seconds: 6)),
      );
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      setState(() => _isDownloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('YouTube Downloader 1080p+'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: _controller,
                decoration: InputDecoration(
                  labelText: 'Paste link YouTube',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  suffixIcon: IconButton(icon: const Icon(Icons.clear), onPressed: _controller.clear),
                ),
                onSubmitted: (_) => _fetchVideoInfo(),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _isFetching ? null : _fetchVideoInfo,
                icon: _isFetching ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white)) : const Icon(Icons.search),
                label: Text(_isFetching ? 'Mengambil...' : 'Ambil Info Video'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
              ),
              const SizedBox(height: 24),

              if (_videoInfo != null) ...[
                if (_videoInfo!['thumbnail'] != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(_videoInfo!['thumbnail'], height: 220, width: double.infinity, fit: BoxFit.cover),
                  ),
                const SizedBox(height: 16),
                Text(_videoInfo!['title'] ?? 'No Title', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                Text('Channel: ${_videoInfo!['author'] ?? 'Unknown'}', style: TextStyle(color: Colors.grey[600])),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _isDownloading ? null : _downloadVideo,
                  icon: _isDownloading ? const CircularProgressIndicator(color: Colors.white) : const Icon(Icons.download_rounded, size: 30),
                  label: Text(_isDownloading ? 'Downloading... ${(_progress * 100).toStringAsFixed(0)}%' : 'Download 1080p + Audio'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 60),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
                const SizedBox(height: 20),
                if (_isDownloading)
                  LinearProgressIndicator(value: _progress > 0 ? _progress : null, minHeight: 8),
                const SizedBox(height: 10),
                Text(_status, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _status.contains('SELESAI') ? Colors.green : Colors.red), textAlign: TextAlign.center),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text(_status, style: TextStyle(fontSize: 16, color: _status.contains('⚠️') ? Colors.orange : Colors.blue[700]), textAlign: TextAlign.center),
                ),
            ],
          ),
        ),
      ),
    );
  }
}