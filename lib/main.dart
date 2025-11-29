import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'dart:convert';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    _requestPermission();
    return MaterialApp(
      title: 'YT Downloader Pro - Video & MP3',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

Future<void> _requestPermission() async {
  if (Platform.isAndroid) {
    await [Permission.photos, Permission.videos, Permission.audio].request();
    if (await Permission.manageExternalStorage.isDenied) {
      await Permission.manageExternalStorage.request();
    }
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final TextEditingController _controller = TextEditingController();
  final String serverUrl = "https://yt-dlp-server-yplayer.vercel.app";

  Map<String, dynamic>? _videoInfo;
  bool _isFetching = false;
  bool _isDownloading = false;
  double _progress = 0.0;
  String _status = 'Paste link YouTube';

  String _downloadType = 'Video';
  String _videoQuality = '1080';
  String _audioQuality = 'best';

  final List<String> _videoQualities = ['144', '360', '480', '720', '1080', '2160'];
  final List<String> _audioQualities = ['64', '128', '160', 'best'];

  late Dio _dio;
  CancelToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _dio = Dio();
  }

  @override
  void dispose() {
    _controller.dispose();
    _cancelToken?.cancel();
    super.dispose();
  }

  Future<void> _fetchVideoInfo() async {
    final url = _controller.text.trim();
    if (!url.contains('youtube.com') && !url.contains('youtu.be')) {
      setState(() => _status = 'Link YouTube tidak valid!');
      return;
    }

    setState(() {
      _isFetching = true;
      _status = 'Mengambil info video...';
      _videoInfo = null;
    });

    try {
      final res = await http
          .get(Uri.parse('$serverUrl/info?url=$url'))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        setState(() {
          _videoInfo = jsonDecode(res.body);
          _status = 'Pilih format & download!';
        });
      } else {
        setState(() => _status = 'Server error: ${res.statusCode}');
      }
    } catch (e) {
      setState(() => _status = 'Gagal koneksi: $e');
    } finally {
      setState(() => _isFetching = false);
    }
  }

  Future<Directory> _getSaveDirectory() async {
    if (Platform.isAndroid) {
      if (_downloadType == 'Audio Only') {
        final musicDir = Directory('/storage/emulated/0/Music');
        if (!await musicDir.exists()) await musicDir.create(recursive: true);
        return musicDir;
      }
      final downloadDir = Directory('/storage/emulated/0/Download');
      if (!await downloadDir.exists()) await downloadDir.create(recursive: true);
      return downloadDir;
    }
    return await getDownloadsDirectory() ?? await getTemporaryDirectory();
  }

  Future<void> _downloadNow() async {
    if (_videoInfo == null) {
      setState(() => _status = 'Ambil info video dulu!');
      return;
    }

    _cancelToken = CancelToken(); // untuk cancel download MP3

    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _status = 'Memulai download...';
    });

    try {
      final dir = await _getSaveDirectory();
      final safeTitle = (_videoInfo!['title'] ?? 'Media')
          .toString()
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
          .trim();

      if (_downloadType == 'Audio Only') {
        await _downloadAudioWithDio(safeTitle, dir);
      } else {
        await _downloadVideoWithStream(safeTitle, dir);
      }
    } catch (e) {
      if (!CancelToken.isCancel(e as DioException)) {
        setState(() => _status = 'Error: $e');
      }
    } finally {
      setState(() => _isDownloading = false);
    }
  }

  // ========= DOWNLOAD MP3 MENGGUNAKAN DIO (RECOMMENDED) =========
  Future<void> _downloadAudioWithDio(String safeTitle, Directory dir) async {
    final params = {
      'url': _controller.text.trim(),
      'quality': _audioQuality,
    };

    final downloadUrl = Uri.parse('$serverUrl/download-audio').replace(queryParameters: params);

    final qualityLabel = _audioQuality == 'best' ? 'Best' : '${_audioQuality}kbps';
    final filename = '$safeTitle - $qualityLabel.mp3';
    final savePath = '${dir.path}/$filename';

    await _dio.download(
      downloadUrl.toString(),
      savePath,
      cancelToken: _cancelToken,
      onReceiveProgress: (received, total) {
        if (total > 0) {
          setState(() {
            _progress = received / total;
            _status = 'Downloading MP3... ${(_progress * 100).toInt()}%';
          });
        }
      },
      options: Options(
        receiveTimeout: const Duration(minutes: 30),
        sendTimeout: const Duration(minutes: 30),
      ),
    );

    _showSuccess('MP3', filename);
  }

  // ========= DOWNLOAD VIDEO TETAP PAKAI STREAM MANUAL (PALING STABIL) =========
  Future<void> _downloadVideoWithStream(String safeTitle, Directory dir) async {
    final params = {
      'url': _controller.text.trim(),
      'quality': _videoQuality,
    };

    final downloadUrl = Uri.parse('$serverUrl/download').replace(queryParameters: params);
    final response = await http.Client()
        .send(http.Request('GET', downloadUrl))
        .timeout(const Duration(minutes: 30));

    final filename = '$safeTitle - ${_videoQuality}p.mp4';
    final file = File('${dir.path}/$filename');

    final sink = file.openWrite();
    int received = 0;
    final total = response.contentLength ?? 0;

    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) {
        setState(() {
          _progress = received / total;
          _status = 'Downloading Video... ${(received / total * 100).toInt()}%';
        });
      }
    }
    await sink.close();

    _showSuccess('Video', filename);
  }

  void _showSuccess(String type, String filename) {
    setState(() {
      _progress = 1.0;
      _status = 'SELESAI! $type tersimpan';
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$type selesai: $filename'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel();
    setState(() {
      _isDownloading = false;
      _progress = 0.0;
      _status = 'Download dibatalkan';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('YT Downloader Pro'),
        backgroundColor: Colors.red[600],
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
                icon: _isFetching
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white))
                    : const Icon(Icons.search),
                label: Text(_isFetching ? 'Mengambil...' : 'Ambil Info Video'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
              ),
              const SizedBox(height: 24),

              if (_videoInfo != null) ...[
                if (_videoInfo!['thumbnail'] != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(
                      _videoInfo!['thumbnail'],
                      height: 200,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  _videoInfo!['title'] ?? 'No Title',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                Text(
                  'Channel: ${_videoInfo!['author'] ?? 'Unknown'}',
                  style: TextStyle(color: Colors.grey[600]),
                ),
                const SizedBox(height: 20),

                DropdownButtonFormField<String>(
                  value: _downloadType,
                  decoration: const InputDecoration(labelText: 'Download sebagai', border: OutlineInputBorder()),
                  items: ['Video', 'Audio Only (MP3)']
                      .map((e) => DropdownMenuItem(value: e.contains('Video') ? 'Video' : 'Audio Only', child: Text(e)))
                      .toList(),
                  onChanged: (v) => setState(() => _downloadType = v!),
                ),
                const SizedBox(height: 16),

                if (_downloadType == 'Video')
                  DropdownButtonFormField<String>(
                    value: _videoQuality,
                    decoration: const InputDecoration(labelText: 'Kualitas Video', border: OutlineInputBorder()),
                    items: _videoQualities.map((q) => DropdownMenuItem(value: q, child: Text('$q p'))).toList(),
                    onChanged: (v) => setState(() => _videoQuality = v!),
                  )
                else
                  DropdownButtonFormField<String>(
                    value: _audioQuality,
                    decoration: const InputDecoration(labelText: 'Kualitas Audio', border: OutlineInputBorder()),
                    items: _audioQualities
                        .map((q) => DropdownMenuItem(
                            value: q, child: Text(q == 'best' ? 'Terbaik (320kbps)' : '$q kbps')))
                        .toList(),
                    onChanged: (v) => setState(() => _audioQuality = v!),
                  ),

                const SizedBox(height: 30),

                ElevatedButton.icon(
                  onPressed: _isDownloading ? null : _downloadNow,
                  icon: _isDownloading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Icon(Icons.download_rounded, size: 36),
                  label: Text(
                    _isDownloading
                        ? 'Downloading... ${(_progress * 100).toInt()}%'
                        : _downloadType == 'Audio Only'
                            ? 'Download MP3 ($_audioQuality)'
                            : 'Download Video ${_videoQuality}p',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red[600],
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 65),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),

                if (_isDownloading) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: _progress, minHeight: 8),
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: _cancelDownload,
                    icon: const Icon(Icons.cancel, color: Colors.red),
                    label: const Text('Batalkan Download', style: TextStyle(color: Colors.red)),
                  ),
                ],

                const SizedBox(height: 20),
                Text(
                  _status,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: _status.contains('SELESAI') || _status.contains('selesai')
                        ? Colors.green
                        : _status.contains('dibatalkan')
                            ? Colors.orange
                            : Colors.orange[700],
                  ),
                  textAlign: TextAlign.center,
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Text(_status, style: const TextStyle(fontSize: 18)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}