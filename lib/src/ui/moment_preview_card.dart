import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class MomentPreviewCard extends StatefulWidget {
  const MomentPreviewCard({
    super.key,
    required this.videoPath,
    required this.title,
    required this.subtitle,
    required this.reasons,
    required this.score,
    this.enabled = true,
    this.onTapToggle,
  });

  final String videoPath;
  final String title;
  final String subtitle;
  final List<String> reasons;
  final double score;
  final bool enabled;
  final VoidCallback? onTapToggle;

  @override
  State<MomentPreviewCard> createState() => _MomentPreviewCardState();
}

class _MomentPreviewCardState extends State<MomentPreviewCard> {
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final controller = VideoPlayerController.file(
      File(widget.videoPath),
    );
    try {
      await controller.initialize();
      await controller.setLooping(true);
      controller.addListener(_onTick);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });
      await controller.play();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось открыть клип';
      });
    }
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: widget.enabled ? 1 : 0.4,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: InkWell(
          onTap: widget.onTapToggle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_loading)
                      const ColoredBox(
                        color: Colors.black12,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    if (_error != null)
                      ColoredBox(
                        color: Colors.black12,
                        child: Center(
                          child: Text(
                            _error!,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ),
                    if (_controller != null && !_loading && _error == null)
                      FittedBox(
                        fit: BoxFit.cover,
                        clipBehavior: Clip.hardEdge,
                        child: SizedBox(
                          width: _controller!.value.size.width,
                          height: _controller!.value.size.height,
                          child: VideoPlayer(_controller!),
                        ),
                      ),
                    Positioned(
                      right: 8,
                      top: 8,
                      child: CircleAvatar(
                        radius: 14,
                        backgroundColor: widget.enabled
                            ? Colors.green.shade600
                            : Colors.grey.shade500,
                        child: Icon(
                          widget.enabled ? Icons.check : Icons.close,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final reason in widget.reasons)
                          Chip(
                            label: Text(reason),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
