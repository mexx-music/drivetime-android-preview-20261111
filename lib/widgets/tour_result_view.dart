import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../logic/eta_calculator.dart';
import '../logic/speed_profile.dart';
import '../logic/tour_export.dart';
import '../services/tour_image_export.dart';
import '../utils/file_download.dart';
import '../utils/image_clipboard.dart';

class TourResultView extends StatefulWidget {
  final EtaResult result;
  final String origin;
  final String destination;
  final RoadMixAnalysis? roadMix;
  final bool exportOnly;

  const TourResultView({
    super.key,
    required this.result,
    required this.origin,
    required this.destination,
    this.roadMix,
    this.exportOnly = false,
  });

  @override
  State<TourResultView> createState() => _TourResultViewState();
}

class _TourResultViewState extends State<TourResultView> {
  final GlobalKey _imageBoundaryKey = GlobalKey();
  bool _creatingImage = false;

  Future<({Uint8List bytes, String filename})?> _createImage() async {
    if (_creatingImage) return null;
    setState(() => _creatingImage = true);
    try {
      final png = await TourImageExport.captureForSharing(
        context: context,
        graphic: TourResultView(
          result: widget.result,
          origin: widget.origin,
          destination: widget.destination,
          roadMix: widget.roadMix,
          exportOnly: true,
        ),
        estimatedEvents: widget.result.steps.length,
        fallbackBoundaryKey: _imageBoundaryKey,
      );
      final filename =
          'driverroute-${_filePart(widget.origin)}-${_filePart(widget.destination)}.png';
      return (bytes: png, filename: filename);
    } catch (_) {
      if (mounted) _message('Die Tourgrafik konnte nicht erstellt werden.');
      return null;
    } finally {
      if (mounted) setState(() => _creatingImage = false);
    }
  }

  Future<void> _shareImageFile(
    String text,
    String subject,
    Rect? shareOrigin,
  ) async {
    final image = await _createImage();
    if (image == null) return;
    try {
      await Share.shareXFiles(
        [
          XFile.fromData(
            image.bytes,
            mimeType: 'image/png',
            name: image.filename,
          ),
        ],
        subject: subject,
        text: text,
        fileNameOverrides: [image.filename],
        sharePositionOrigin: shareOrigin,
      );
    } catch (_) {
      if (mounted) _message('Die Tourgrafik konnte nicht geteilt werden.');
    }
  }

  Future<void> _shareImageToWhatsApp(
    String text,
    String subject,
    Rect? shareOrigin,
  ) async {
    if (!kIsWeb) {
      await _shareImageFile(text, subject, shareOrigin);
      return;
    }

    final image = await _createImage();
    if (image == null) return;
    final saved = await downloadBytes(
      image.bytes,
      filename: image.filename,
      mimeType: 'image/png',
    );
    if (!saved) {
      if (mounted) _message('Die PNG-Datei konnte nicht gespeichert werden.');
      return;
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => WhatsAppImageReadyDialog(
        filename: image.filename,
        png: image.bytes,
        onContinue: () {
          Navigator.pop(dialogContext);
          _openWhatsAppForImage();
        },
      ),
    );
  }

  Future<void> _openWhatsAppForImage() async {
    try {
      final opened = await launchUrl(
        Uri.https('web.whatsapp.com', '/'),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) {
        _message('WhatsApp konnte nicht geöffnet werden.');
      }
    } catch (_) {
      if (mounted) _message('WhatsApp konnte nicht geöffnet werden.');
    }
  }

  Future<void> _saveImage() async {
    final image = await _createImage();
    if (image == null) return;
    final saved = await downloadBytes(
      image.bytes,
      filename: image.filename,
      mimeType: 'image/png',
    );
    if (mounted) {
      _message(
          saved ? 'Tourgrafik gespeichert.' : 'Speichern nicht verfügbar.');
    }
  }

  Future<void> _showImageShareOptions(
    BuildContext shareContext,
    String text,
    String subject,
  ) async {
    if (_creatingImage) return;
    final box = shareContext.findRenderObject() as RenderBox?;
    final shareOrigin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _ShareOptionsSheet(
        title: 'Grafik teilen',
        description: 'Wähle, wohin die gestaltete PNG-Tour gehen soll.',
        whatsAppSubtitle: kIsWeb
            ? 'Zuerst PNG speichern, danach WhatsApp öffnen'
            : 'PNG über das Teilen-Menü an WhatsApp senden',
        mailSubtitle: 'PNG anhängen – danach im Systemfenster Mail wählen',
        moreSubtitle: 'AirDrop, Nachrichten und weitere installierte Apps',
        saveLabel: kIsWeb ? 'PNG speichern' : null,
        onWhatsApp: () {
          Navigator.pop(sheetContext);
          _shareImageToWhatsApp(text, subject, shareOrigin);
        },
        onMail: () {
          Navigator.pop(sheetContext);
          _shareImageFile(text, subject, shareOrigin);
        },
        onMore: () {
          Navigator.pop(sheetContext);
          _shareImageFile(text, subject, shareOrigin);
        },
        onSave: kIsWeb
            ? () {
                Navigator.pop(sheetContext);
                _saveImage();
              }
            : null,
      ),
    );
  }

  void _message(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final origin = widget.origin;
    final destination = widget.destination;
    final roadMix = widget.roadMix;
    final summary = result.summary;
    if (summary == null || result.arrival == null) {
      return const SizedBox.shrink();
    }
    final visibleSteps = result.steps.where((step) => !step.technical).toList();
    final exportText = TourExport.asText(
      result: result,
      origin: origin,
      destination: destination,
      roadMix: roadMix,
    );
    EtaStep? nextRequiredStop;
    for (final step in visibleSteps) {
      if (step.type == EtaEventType.breakTime ||
          step.type == EtaEventType.dailyRest ||
          step.type == EtaEventType.weeklyRest) {
        nextRequiredStop = step;
        break;
      }
    }

    final subject =
        'DriverRoute ETA: ${_shortPlace(origin)} → ${_shortPlace(destination)}';

    return Semantics(
      label: 'Berechneter Tourablauf von $origin nach $destination',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RepaintBoundary(
            key: _imageBoundaryKey,
            child: ColoredBox(
              color: const Color(0xFFF6F8FB),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TourHeader(
                    origin: origin,
                    destination: destination,
                    summary: summary,
                    arrival: result.arrival!,
                    creatingImage: _creatingImage || widget.exportOnly,
                    onShareImage: () =>
                        _showImageShareOptions(context, exportText, subject),
                  ),
                  const SizedBox(height: 16),
                  _SummaryGrid(
                    summary: summary,
                    arrival: result.arrival!,
                    exportOnly: widget.exportOnly,
                  ),
                  if (roadMix != null && roadMix.hasBreakdown) ...[
                    const SizedBox(height: 10),
                    _RoadMixBanner(analysis: roadMix),
                  ],
                  if (nextRequiredStop != null) ...[
                    const SizedBox(height: 10),
                    _NextStopBanner(step: nextRequiredStop),
                  ],
                  const SizedBox(height: 18),
                  Text(
                    'Tourablauf',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
                      child: Column(
                        children: [
                          for (var index = 0;
                              index < visibleSteps.length;
                              index++)
                            _TimelineRow(
                              step: visibleSteps[index],
                              isLast: index == visibleSteps.length - 1,
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF0A7A4B), Color(0xFF075E3A)],
                      ),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'Voraussichtliche Ankunft',
                          style: TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          DateFormat('EEEE, dd.MM. – HH:mm', 'de')
                              .format(result.arrival!),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!widget.exportOnly) ...[
            const SizedBox(height: 10),
            _ExportActions(
              text: exportText,
              subject: subject,
              creatingImage: _creatingImage,
              onShareImage: (buttonContext) => _showImageShareOptions(
                buttonContext,
                exportText,
                subject,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _filePart(String value) {
  final short = _shortPlace(value).toLowerCase();
  final cleaned = short.replaceAll(RegExp(r'[^a-z0-9äöüß]+'), '-');
  return cleaned.replaceAll(RegExp(r'^-+|-+$'), '').isEmpty
      ? 'ort'
      : cleaned.replaceAll(RegExp(r'^-+|-+$'), '');
}

class _ExportActions extends StatelessWidget {
  final String text;
  final String subject;
  final bool creatingImage;
  final Future<void> Function(BuildContext context) onShareImage;

  const _ExportActions({
    required this.text,
    required this.subject,
    required this.creatingImage,
    required this.onShareImage,
  });

  Future<void> _share(BuildContext context) async {
    try {
      final box = context.findRenderObject() as RenderBox?;
      await Share.share(
        text,
        subject: subject,
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      );
    } catch (_) {
      if (context.mounted) {
        _message(context, 'Teilen konnte nicht geöffnet werden.');
      }
    }
  }

  Future<void> _openWhatsApp(BuildContext context) async {
    final uri = Uri.https('wa.me', '/', {'text': text});
    await _launch(context, uri, 'WhatsApp konnte nicht geöffnet werden.');
  }

  Future<void> _openMail(BuildContext context) async {
    final uri = Uri(
      scheme: 'mailto',
      query:
          'subject=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(text)}',
    );
    await _launch(context, uri, 'E-Mail konnte nicht geöffnet werden.');
  }

  Future<void> _launch(
    BuildContext context,
    Uri uri,
    String errorMessage,
  ) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && context.mounted) _message(context, errorMessage);
    } catch (_) {
      if (context.mounted) _message(context, errorMessage);
    }
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) _message(context, 'Tourergebnis kopiert.');
  }

  void _message(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showTextShareOptions(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _ShareOptionsSheet(
        title: 'Text teilen',
        description: 'Wähle, wohin der strukturierte Tourtext gehen soll.',
        whatsAppSubtitle: 'Tourtext direkt in WhatsApp öffnen',
        mailSubtitle: 'Betreff und Tourtext in einer E-Mail vorfüllen',
        moreSubtitle: 'Nachrichten, Notizen und weitere installierte Apps',
        saveLabel: 'Text kopieren',
        saveIcon: Icons.copy_rounded,
        onWhatsApp: () {
          Navigator.pop(sheetContext);
          _openWhatsApp(context);
        },
        onMail: () {
          Navigator.pop(sheetContext);
          _openMail(context);
        },
        onMore: () {
          Navigator.pop(sheetContext);
          _share(context);
        },
        onSave: () {
          Navigator.pop(sheetContext);
          _copy(context);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tour exportieren',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          Text(
            'Als gestaltete Grafik oder als kopierbaren Text teilen.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Builder(
                builder: (buttonContext) => FilledButton.icon(
                  onPressed:
                      creatingImage ? null : () => onShareImage(buttonContext),
                  icon: creatingImage
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.image_rounded),
                  label: Text(
                    creatingImage ? 'Grafik wird erstellt …' : 'Grafik teilen',
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _showTextShareOptions(context),
                icon: const Icon(Icons.notes_rounded),
                label: const Text('Text teilen'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShareOptionsSheet extends StatelessWidget {
  final String title;
  final String description;
  final String whatsAppSubtitle;
  final String mailSubtitle;
  final String moreSubtitle;
  final String? saveLabel;
  final IconData? saveIcon;
  final VoidCallback onWhatsApp;
  final VoidCallback onMail;
  final VoidCallback onMore;
  final VoidCallback? onSave;

  const _ShareOptionsSheet({
    required this.title,
    required this.description,
    required this.whatsAppSubtitle,
    required this.mailSubtitle,
    required this.moreSubtitle,
    required this.onWhatsApp,
    required this.onMail,
    required this.onMore,
    this.saveLabel,
    this.saveIcon,
    this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 14),
                _ShareDestination(
                  icon: Icons.chat_rounded,
                  color: const Color(0xFF168C4B),
                  label: 'WhatsApp',
                  subtitle: whatsAppSubtitle,
                  onTap: onWhatsApp,
                ),
                _ShareDestination(
                  icon: Icons.mail_outline_rounded,
                  color: const Color(0xFF1565C0),
                  label: 'E-Mail',
                  subtitle: mailSubtitle,
                  onTap: onMail,
                ),
                _ShareDestination(
                  icon: Icons.ios_share_rounded,
                  color: const Color(0xFF6A1B9A),
                  label: 'Weitere Apps',
                  subtitle: moreSubtitle,
                  onTap: onMore,
                ),
                if (saveLabel != null && onSave != null)
                  _ShareDestination(
                    icon: saveIcon ?? Icons.download_rounded,
                    color: const Color(0xFF455A64),
                    label: saveLabel!,
                    onTap: onSave!,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WhatsAppImageReadyDialog extends StatefulWidget {
  final String filename;
  final Uint8List png;
  final VoidCallback onContinue;

  const WhatsAppImageReadyDialog({
    required this.filename,
    required this.png,
    required this.onContinue,
  });

  @override
  State<WhatsAppImageReadyDialog> createState() =>
      _WhatsAppImageReadyDialogState();
}

class _WhatsAppImageReadyDialogState extends State<WhatsAppImageReadyDialog> {
  bool _copied = false;
  bool _copying = false;

  Future<void> _copyImage() async {
    if (_copying) return;
    setState(() => _copying = true);
    final copied = await copyPngToClipboard(widget.png);
    if (!mounted) return;
    setState(() {
      _copying = false;
      _copied = copied;
    });
    if (!copied) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Bildkopie nicht verfügbar – gespeichertes PNG in WhatsApp anhängen.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      icon: const CircleAvatar(
        radius: 25,
        backgroundColor: Color(0xFFE8F5EE),
        foregroundColor: Color(0xFF087F5B),
        child: Icon(Icons.download_done_rounded, size: 28),
      ),
      title: const Text(
        'Tourgrafik ist vorbereitet',
        textAlign: TextAlign.center,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                height: 150,
                constraints: const BoxConstraints(maxWidth: 300),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFD9E2EC)),
                  borderRadius: BorderRadius.circular(10),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.memory(widget.png, fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 16),
            const _ShareStep(
              number: '1',
              title: 'PNG speichern',
              detail: 'Das Bild wurde zum Speichern angeboten.',
              completed: true,
            ),
            const SizedBox(height: 14),
            _ShareStep(
              number: '2',
              title: 'Grafik kopieren',
              detail: _copied
                  ? 'Bild liegt in der Zwischenablage.'
                  : 'Damit du es im WhatsApp-Chat einfügen kannst.',
              completed: _copied,
            ),
            const SizedBox(height: 14),
            const _ShareStep(
              number: '3',
              title: 'WhatsApp öffnen',
              detail:
                  'Chat auswählen, Bild mit ⌘V/Strg+V einfügen und erst dann senden.',
            ),
            const SizedBox(height: 8),
            Text(
              'Falls das Kopieren nicht klappt, kannst du stattdessen '
              'die gespeicherte PNG-Datei im Chat anhängen.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            Text(
              widget.filename,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Später'),
        ),
        OutlinedButton.icon(
          onPressed: _copying ? null : _copyImage,
          icon: const Icon(Icons.copy_rounded),
          label: Text(_copied ? 'Grafik erneut kopieren' : 'Grafik kopieren'),
        ),
        FilledButton.icon(
          onPressed: widget.onContinue,
          icon: const Icon(Icons.chat_rounded),
          label: const Text('Weiter zu WhatsApp'),
        ),
      ],
    );
  }
}

class _ShareStep extends StatelessWidget {
  final String number;
  final String title;
  final String detail;
  final bool completed;

  const _ShareStep({
    required this.number,
    required this.title,
    required this.detail,
    this.completed = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = completed
        ? const Color(0xFF087F5B)
        : Theme.of(context).colorScheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: color.withValues(alpha: 0.12),
          foregroundColor: color,
          child: completed
              ? const Icon(Icons.check_rounded, size: 18)
              : Text(
                  number,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(detail, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _ShareDestination extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  const _ShareDestination({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.13),
            foregroundColor: color,
            child: Icon(icon),
          ),
          title: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          subtitle: subtitle == null ? null : Text(subtitle!),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _RoadMixBanner extends StatelessWidget {
  final RoadMixAnalysis analysis;

  const _RoadMixBanner({required this.analysis});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.add_road_rounded, size: 20),
              SizedBox(width: 8),
              Text(
                'Straßenmix der Route',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '${analysis.fastPercent} % schnell/autobahnähnlich  ·  '
            '${analysis.mainRoadPercent} % Haupt-/Bundesstraße  ·  '
            '${analysis.slowPercent} % langsam/lokal',
          ),
          const SizedBox(height: 4),
          Text(
            'Distanzgewichtete Schätzung aus den Fahrtdauern der einzelnen Routenabschnitte.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _NextStopBanner extends StatelessWidget {
  final EtaStep step;

  const _NextStopBanner({required this.step});

  @override
  Widget build(BuildContext context) {
    final isBreak = step.type == EtaEventType.breakTime;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(isBreak ? Icons.coffee_rounded : Icons.nightlight_round),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isBreak ? 'Nächste Lenkpause' : 'Nächste Ruhezeit',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (step.start != null)
                  Text(DateFormat('EEEE, HH:mm', 'de').format(step.start!)),
              ],
            ),
          ),
          Text(
            _duration(step.duration.inMinutes),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _TourHeader extends StatelessWidget {
  final String origin;
  final String destination;
  final EtaSummary summary;
  final DateTime arrival;
  final bool creatingImage;
  final VoidCallback onShareImage;

  const _TourHeader({
    required this.origin,
    required this.destination,
    required this.summary,
    required this.arrival,
    required this.creatingImage,
    required this.onShareImage,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF102A43),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'DEINE TOUR',
                  style: TextStyle(
                    color: Color(0xFF9FB3C8),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
              if (!creatingImage)
                IconButton(
                  onPressed: onShareImage,
                  tooltip: 'Tourgrafik teilen',
                  style: IconButton.styleFrom(
                    foregroundColor: const Color(0xFF69F0AE),
                    backgroundColor: const Color(0xFF243F5C),
                  ),
                  icon: const Icon(Icons.ios_share_rounded),
                ),
            ],
          ),
          SizedBox(height: creatingImage ? 8 : 2),
          Text(
            '${_shortPlace(origin)}  →  ${_shortPlace(destination)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${summary.distanceKm.toStringAsFixed(0)} km · '
            '${_duration(summary.drivingMinutes)} reine Fahrzeit · '
            'Ø ${_speed(summary.averageKmh)} km/h',
            style: const TextStyle(color: Color(0xFFD9E2EC), fontSize: 15),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.flag_rounded, color: Color(0xFF69F0AE)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Ankunft ${DateFormat('EEEE, HH:mm', 'de').format(arrival)}',
                  style: const TextStyle(
                    color: Color(0xFF69F0AE),
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  final EtaSummary summary;
  final DateTime arrival;
  final bool exportOnly;

  const _SummaryGrid({
    required this.summary,
    required this.arrival,
    required this.exportOnly,
  });

  @override
  Widget build(BuildContext context) {
    final items = <({IconData icon, String label, String value, Color color})>[
      (
        icon: Icons.route_rounded,
        label: 'Noch zu fahren',
        value: '${summary.distanceKm.toStringAsFixed(0)} km',
        color: const Color(0xFF1565C0),
      ),
      (
        icon: Icons.local_shipping_rounded,
        label: 'Reine Fahrzeit',
        value: _duration(summary.drivingMinutes),
        color: const Color(0xFF6A1B9A),
      ),
      (
        icon: Icons.hotel_rounded,
        label: 'Pausen / Ruhe',
        value: _duration(summary.nonDrivingMinutes),
        color: const Color(0xFFEF6C00),
      ),
      (
        icon: Icons.flag_rounded,
        label: 'ETA',
        value: DateFormat('EEE HH:mm', 'de').format(arrival),
        color: const Color(0xFF087F5B),
      ),
    ];

    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth >= 760
          ? 4
          : constraints.maxWidth >= 330
              ? 2
              : 1;
      const gap = 10.0;
      final width = (constraints.maxWidth - (columns - 1) * gap) / columns;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final item in items)
                SizedBox(
                  width: width,
                  child: _SummaryCard(
                    icon: item.icon,
                    label: item.label,
                    value: item.value,
                    color: item.color,
                  ),
                ),
            ],
          ),
          if (summary.tenHourDaysUsed > 0 ||
              summary.reducedDailyRestsUsed > 0) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (summary.tenHourDaysUsed > 0)
                  exportOnly
                      ? _ExportStatusChip(
                          icon: Icons.schedule_rounded,
                          label:
                              '10-h-Fahrt: ${summary.tenHourDaysUsed} von 2 verwendet',
                        )
                      : Chip(
                          avatar: const Icon(Icons.schedule_rounded, size: 18),
                          label: Text(
                              '10-h-Fahrt: ${summary.tenHourDaysUsed} von 2 verwendet'),
                        ),
                if (summary.reducedDailyRestsUsed > 0)
                  exportOnly
                      ? _ExportStatusChip(
                          icon: Icons.nightlight_round,
                          label:
                              '9-h-Ruhe: ${summary.reducedDailyRestsUsed} von 3 verwendet',
                        )
                      : Chip(
                          avatar: const Icon(Icons.nightlight_round, size: 18),
                          label: Text(
                              '9-h-Ruhe: ${summary.reducedDailyRestsUsed} von 3 verwendet'),
                        ),
              ],
            ),
          ],
        ],
      );
    });
  }
}

class _ExportStatusChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ExportStatusChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      );
}

String _speed(double kmh) {
  return kmh == kmh.roundToDouble()
      ? kmh.toStringAsFixed(0)
      : kmh.toStringAsFixed(1);
}

class _SummaryCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _SummaryCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 108),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 23),
          const SizedBox(height: 14),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              color: color,
              fontSize: 19,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final EtaStep step;
  final bool isLast;

  const _TimelineRow({required this.step, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final visual = _visualFor(step.type);
    // Die Zeilenhöhe ergibt sich allein aus dem Text rechts; die Leiste links
    // (Kreis + Verbindungslinie) wird auf genau diese Höhe gelegt. Früher gab
    // IntrinsicHeight die Höhe vor – im Browser lag diese Vorab-Schätzung
    // beim ersten Bild (Ersatzschrift für „✓“ noch nicht geladen) 1 px unter
    // der echten Texthöhe, und die rechte Spalte lief über.
    return SizedBox(
      width: double.infinity,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 42,
            child: Column(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: visual.color.withValues(alpha: 0.13),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(visual.icon, color: visual.color, size: 20),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          // Mindesthöhe wie bisher: Kreis (36) bzw. Kreis + Linienabstand (44).
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: isLast ? 36 : 44),
            child: Padding(
              padding: const EdgeInsets.only(left: 52, top: 3, bottom: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.title ?? step.text,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (step.start != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      _eventTime(step),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if ((step.detail ?? '').isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(step.detail!),
                  ],
                  if (step.restSatisfied != null) ...[
                    const SizedBox(height: 7),
                    _RestBadge(satisfied: step.restSatisfied!),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RestBadge extends StatelessWidget {
  final bool satisfied;

  const _RestBadge({required this.satisfied});

  @override
  Widget build(BuildContext context) {
    final color = satisfied ? const Color(0xFF087F5B) : const Color(0xFFC2410C);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        satisfied ? '✓ Ruhezeit erfüllt' : 'Ruhezeit noch nicht erfüllt',
        style:
            TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}

({IconData icon, Color color}) _visualFor(EtaEventType type) {
  return switch (type) {
    EtaEventType.start => (
        icon: Icons.local_shipping_rounded,
        color: const Color(0xFF1565C0)
      ),
    EtaEventType.drive => (
        icon: Icons.route_rounded,
        color: const Color(0xFF1565C0)
      ),
    EtaEventType.breakTime => (
        icon: Icons.coffee_rounded,
        color: const Color(0xFF8D6E63)
      ),
    EtaEventType.dailyRest => (
        icon: Icons.nightlight_round,
        color: const Color(0xFF6A1B9A)
      ),
    EtaEventType.weeklyRest => (
        icon: Icons.hotel_rounded,
        color: const Color(0xFF4527A0)
      ),
    EtaEventType.tank => (
        icon: Icons.local_gas_station_rounded,
        color: const Color(0xFFEF6C00)
      ),
    EtaEventType.wait => (
        icon: Icons.hourglass_bottom_rounded,
        color: const Color(0xFF455A64)
      ),
    EtaEventType.ferry => (
        icon: Icons.directions_boat_rounded,
        color: const Color(0xFF0277BD)
      ),
    EtaEventType.stop => (
        icon: Icons.anchor_rounded,
        color: const Color(0xFF0277BD)
      ),
    EtaEventType.destination => (
        icon: Icons.flag_rounded,
        color: const Color(0xFF087F5B)
      ),
    EtaEventType.notice => (
        icon: Icons.info_outline_rounded,
        color: const Color(0xFF455A64)
      ),
  };
}

String _eventTime(EtaStep step) {
  final start = step.start!;
  final end = step.end;
  final startText = DateFormat('EEE, dd.MM. HH:mm', 'de').format(start);
  if (end == null || end == start) return startText;
  final sameDay = start.year == end.year &&
      start.month == end.month &&
      start.day == end.day;
  return sameDay
      ? '$startText – ${DateFormat('HH:mm').format(end)}'
      : '$startText – ${DateFormat('EEE, dd.MM. HH:mm', 'de').format(end)}';
}

String _duration(int minutes) {
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours == 0) return '$rest min';
  if (rest == 0) return '$hours h';
  return '$hours h ${rest.toString().padLeft(2, '0')} min';
}

String _shortPlace(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '–';
  return trimmed.split(',').first.trim();
}
