import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:highlight_cutter_native/highlight_cutter_native.dart';

import 'src/core/clip_exporter.dart';
import 'src/core/highlight_selector.dart';
import 'src/models/moment.dart';
import 'src/ui/moment_preview_card.dart';

void main() {
  runApp(const HighlightCutterApp());
}

class HighlightCutterApp extends StatelessWidget {
  const HighlightCutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Нарезка фильмов',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6750A4),
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
  final _engine = HighlightCutterNative();
  final _selector = const HighlightSelector();
  late final ClipExporter _exporter = ClipExporter(engine: _engine);

  VideoMeta? _meta;
  FrameAnalysis? _analysis;
  List<Moment> _moments = const [];
  final Set<String> _disabledIds = {};

  bool _analyzing = false;
  bool _exporting = false;
  double _progress = 0;
  String? _error;
  ExportMode _mode = ExportMode.clips;
  HighlightSettings _settings = const HighlightSettings();

  Future<void> _pickVideo() async {
    setState(() => _error = null);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
      );
      final path = result?.files.single.path;
      if (path == null) return;
      final meta = VideoMeta.fromMap(await _engine.readMeta(path));
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _analysis = null;
        _moments = const [];
        _disabledIds.clear();
      });
      await _runAnalysis();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Не удалось открыть файл: $e');
    }
  }

  Future<void> _runAnalysis() async {
    final meta = _meta;
    if (meta == null) return;

    setState(() {
      _analyzing = true;
      _progress = 0;
      _error = null;
    });

    try {
      final sampleFps = _sampleFpsFor(meta.durationUs);
      final analysis = await _engine.analyzeFrames(
        meta.path,
        sampleFps: sampleFps,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      final moments = _selector.select(analysis, _settings);
      if (!mounted) return;
      setState(() {
        _analysis = analysis;
        _moments = moments;
        _analyzing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _analyzing = false;
        _error = 'Анализ не удался: $e';
      });
    }
  }

  double _sampleFpsFor(int durationUs) {
    final seconds = durationUs / 1e6;
    if (seconds <= 0) return 1.0;
    final target = (seconds / 1200).clamp(0.5, 4.0);
    return target;
  }

  List<Moment> get _activeMoments =>
      _moments.where((m) => !_disabledIds.contains(m.id)).toList();

  Future<void> _export() async {
    final meta = _meta;
    final active = _activeMoments;
    if (meta == null || active.isEmpty) return;

    setState(() {
      _exporting = true;
      _progress = 0;
      _error = null;
    });

    try {
      final result = await _exporter.export(
        sourcePath: meta.path,
        moments: active,
        mode: _mode,
        bitrate: meta.isPortrait ? 4000000 : 6000000,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      if (!mounted) return;
      setState(() => _exporting = false);
      await _showExportResult(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _error = 'Экспорт не удался: $e';
      });
    }
  }

  Future<void> _showExportResult(ExportResult result) async {
    final message = result.mode == ExportMode.trailer
        ? 'Трейлер сохранён: ${result.files.first}'
        : 'Готово клипов: ${result.files.length}\n${result.files.join('\n')}';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Готово'),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('ОК'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final meta = _meta;
    final analysis = _analysis;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Нарезка фильмов'),
        actions: [
          if (meta != null && !_analyzing)
            IconButton(
              tooltip: 'Настройки',
              icon: const Icon(Icons.tune),
              onPressed: _openSettings,
            ),
        ],
      ),
      body: SafeArea(
        child: meta == null ? _buildStart() : _buildWorkspace(meta, analysis),
      ),
    );
  }

  Widget _buildStart() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie_filter_outlined, size: 72),
            const SizedBox(height: 16),
            Text(
              'Выберите фильм — приложение само найдёт лучшие моменты и нарежет клипы',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _pickVideo,
              icon: const Icon(Icons.video_file_outlined),
              label: const Text('Выбрать видео'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWorkspace(VideoMeta meta, FrameAnalysis? analysis) {
    if (_analyzing) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              Text('Анализирую кадры… ${(_progress * 100).round()}%'),
              const SizedBox(height: 8),
              const Text(
                'Оцениваю резкость, экспозицию, цвета и наличие людей',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final moments = _moments;
    return Column(
      children: [
        _buildToolbar(meta),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: moments.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Подходящих моментов не найдено. Попробуйте другой файл или уменьшите длину клипа в настройках.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: moments.length,
                  itemBuilder: (context, index) {
                    final moment = moments[index];
                    return MomentPreviewCard(
                      videoPath: meta.path,
                      title: 'Момент ${index + 1}',
                      subtitle:
                          '${_format(moment.start)} – ${_format(moment.end)}  •  качество ${(moment.score * 100).round()}%',
                      reasons: moment.reasons,
                      score: moment.score,
                      enabled: !_disabledIds.contains(moment.id),
                      onTapToggle: () {
                        setState(() {
                          if (!_disabledIds.remove(moment.id)) {
                            _disabledIds.add(moment.id);
                          }
                        });
                      },
                    );
                  },
                ),
        ),
        _buildExportBar(),
      ],
    );
  }

  Widget _buildToolbar(VideoMeta meta) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Icon(Icons.movie_outlined, color: Theme.of(context).hintColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${File(meta.path).uri.pathSegments.last}  •  ${_formatUs(meta.durationUs)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            onPressed: _pickVideo,
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('Другой'),
          ),
        ],
      ),
    );
  }

  Widget _buildExportBar() {
    final active = _activeMoments;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        children: [
          SegmentedButton<ExportMode>(
            segments: const [
              ButtonSegment(
                value: ExportMode.clips,
                label: Text('Клипы'),
                icon: Icon(Icons.content_cut),
              ),
              ButtonSegment(
                value: ExportMode.trailer,
                label: Text('Трейлер'),
                icon: Icon(Icons.movie_filter),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (value) => setState(() => _mode = value.first),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _exporting || active.isEmpty ? null : _export,
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(
                _exporting
                    ? 'Нарезаю… ${(_progress * 100).round()}%'
                    : _mode == ExportMode.trailer
                        ? 'Собрать трейлер'
                        : 'Вырезать клипов: ${active.length}',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings() async {
    final result = await showModalBottomSheet<HighlightSettings>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SettingsSheet(settings: _settings),
    );
    if (result == null || !mounted) return;
    setState(() => _settings = result);
    final analysis = _analysis;
    if (analysis == null) return;
    setState(() {
      _moments = _selector.select(analysis, result);
      _disabledIds.clear();
    });
  }

  String _format(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  String _formatUs(int us) {
    final d = Duration(microseconds: us);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.settings});

  final HighlightSettings settings;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late double _clipDuration = widget.settings.clipDurationSec;
  late int _maxClips = widget.settings.maxClips;
  late double _minGap = widget.settings.minGapSec;
  late Map<String, double> _weights = Map.of(widget.settings.weights);

  static const _labels = <String, String>{
    'sharpness': 'Резкость',
    'exposure': 'Экспозиция',
    'contrast': 'Контраст',
    'colorfulness': 'Цвета',
    'faces': 'Люди в кадре',
    'motion': 'Движение',
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Настройки отбора',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text('Длина клипа: ${_clipDuration.toStringAsFixed(1)} с'),
          Slider(
            value: _clipDuration,
            min: 3,
            max: 30,
            divisions: 27,
            onChanged: (v) => setState(() => _clipDuration = v),
          ),
          Text('Количество клипов: $_maxClips'),
          Slider(
            value: _maxClips.toDouble(),
            min: 1,
            max: 15,
            divisions: 14,
            onChanged: (v) => setState(() => _maxClips = v.round()),
          ),
          Text('Минимальный интервал: ${_minGap.toStringAsFixed(0)} с'),
          Slider(
            value: _minGap,
            min: 5,
            max: 120,
            divisions: 23,
            onChanged: (v) => setState(() => _minGap = v),
          ),
          const Divider(height: 24),
          for (final key in _labels.keys)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '${_labels[key]}: ${(_weights[key] ?? 0).toStringAsFixed(1)}'),
                Slider(
                  value: (_weights[key] ?? 0).clamp(0.0, 2.0),
                  max: 2.0,
                  divisions: 20,
                  onChanged: (v) => setState(() => _weights[key] = v),
                ),
              ],
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              HighlightSettings(
                clipDurationSec: _clipDuration,
                maxClips: _maxClips,
                minGapSec: _minGap,
                minClipDurationSec: widget.settings.minClipDurationSec,
                minSceneSec: widget.settings.minSceneSec,
                weights: _weights,
              ),
            ),
            child: const Text('Применить'),
          ),
        ],
      ),
    );
  }
}
