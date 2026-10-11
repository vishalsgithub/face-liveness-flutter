import 'dart:typed_data';

import 'package:face_liveness/face_liveness.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

void main() => runApp(const LivenessApp());

class LivenessApp extends StatelessWidget {
  const LivenessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Face Liveness',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
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
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          // Only keep the camera running while its tab is visible.
          _tab == 0 ? const CameraPage() : const SizedBox.shrink(),
          const PhotoPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.face_retouching_natural), label: 'Camera'),
          NavigationDestination(icon: Icon(Icons.photo_outlined), label: 'Photo'),
        ],
      ),
    );
  }
}

// --- Live camera -----------------------------------------------------------------

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  LivenessResult? _result;
  Object? _error;
  double _threshold = FaceLiveness.defaultLivenessThreshold;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        FaceLivenessCamera(
          livenessThreshold: _threshold,
          onResult: (r) => setState(() => _result = r),
          onVerified: (r) => ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Verified real face (score ${r.face!.livenessScore.toStringAsFixed(3)})'),
              duration: const Duration(seconds: 2),
            ),
          ),
          onError: (e) => setState(() => _error = e),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: IconButton.filledTonal(
                icon: const Icon(Icons.tune),
                onPressed: _showSettings,
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _StatusCard(result: _result, error: _error, threshold: _threshold),
          ),
        ),
      ],
    );
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Liveness threshold', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('Faces scoring at or above the threshold are treated as real. Higher is stricter.'),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _threshold,
                      min: 0.5,
                      max: 0.99,
                      onChanged: (v) {
                        setSheet(() {});
                        setState(() => _threshold = v);
                      },
                    ),
                  ),
                  Text(_threshold.toStringAsFixed(3)),
                ],
              ),
              TextButton(
                onPressed: () {
                  setSheet(() {});
                  setState(() => _threshold = FaceLiveness.defaultLivenessThreshold);
                },
                child: const Text('Reset to default (0.915)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.result, required this.error, required this.threshold});

  final LivenessResult? result;
  final Object? error;
  final double threshold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final face = result?.face;
    final (String title, IconData icon, Color color) = switch (result) {
      _ when error != null => ('Camera unavailable', Icons.warning_amber, Colors.orange),
      null => ('Starting camera…', Icons.hourglass_empty, theme.colorScheme.onSurface),
      LivenessResult(face: null) => ('Position your face in the frame', Icons.face, theme.colorScheme.onSurface),
      LivenessResult(isVerified: true) => ('Real face', Icons.verified, Colors.green),
      LivenessResult(face: LivenessFace(isLive: true)) => ('Checking…', Icons.hourglass_top, Colors.blue),
      _ => ('Spoof detected', Icons.gpp_bad, Colors.red),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(error?.toString() ?? title,
                      style: theme.textTheme.titleMedium?.copyWith(color: color)),
                ),
                if (face != null)
                  Text(face.livenessScore.toStringAsFixed(3),
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: result == null ? 0 : (result!.consecutiveLiveFrames / 8).clamp(0.0, 1.0),
              color: color,
            ),
            const SizedBox(height: 8),
            Text(
              'Threshold ${threshold.toStringAsFixed(3)} · '
              '${result?.processingTime.inMilliseconds ?? 0} ms / frame',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

// --- Still photo -----------------------------------------------------------------

class PhotoPage extends StatefulWidget {
  const PhotoPage({super.key});

  @override
  State<PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<PhotoPage> {
  FaceLiveness? _engine;
  Uint8List? _bytes;
  Size? _imageSize;
  List<LivenessFace> _faces = const [];
  String? _message;

  @override
  void dispose() {
    _engine?.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() {
      _bytes = bytes;
      _faces = const [];
      _message = 'Analysing…';
    });
    try {
      _engine ??= await FaceLiveness.create();
      final decoded = await decodeImageFromList(bytes);
      final faces = await _engine!.detectInImageBytes(bytes);
      setState(() {
        _imageSize = Size(decoded.width.toDouble(), decoded.height.toDouble());
        _faces = faces;
        _message = faces.isEmpty ? 'No face found.' : null;
      });
      decoded.dispose();
    } catch (e) {
      setState(() => _message = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final face = _faces.isEmpty ? null : _faces.first;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('Photo check', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 16),
            Expanded(
              child: _bytes == null
                  ? const Center(child: Text('Pick a photo to check it for a real face.'))
                  : Center(
                      child: AspectRatio(
                        aspectRatio: _imageSize == null ? 1 : _imageSize!.aspectRatio,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.memory(_bytes!, fit: BoxFit.fill),
                            if (_imageSize != null)
                              CustomPaint(painter: _BoxesPainter(_faces, _imageSize!)),
                          ],
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            if (face != null)
              Text(
                '${face.isLive ? 'Real face' : 'Spoof'} · score ${face.livenessScore.toStringAsFixed(3)}',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: face.isLive ? Colors.green : Colors.red),
              ),
            if (_message != null) Text(_message!),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _pick,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Choose photo'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BoxesPainter extends CustomPainter {
  _BoxesPainter(this.faces, this.imageSize);

  final List<LivenessFace> faces;
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / imageSize.width, sy = size.height / imageSize.height;
    for (final face in faces) {
      final b = face.bounds;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTRB(b.left * sx, b.top * sy, b.right * sx, b.bottom * sy),
            const Radius.circular(8)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = face.isLive ? Colors.green : Colors.red,
      );
    }
  }

  @override
  bool shouldRepaint(_BoxesPainter old) => old.faces != faces || old.imageSize != imageSize;
}
