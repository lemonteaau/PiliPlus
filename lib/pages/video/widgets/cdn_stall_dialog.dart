import 'dart:async';

import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:flutter/material.dart';

enum CdnStallDecision { switchNow, timedOut, cancel }

Future<CdnStallDecision?> showCdnStallDialog({
  required BuildContext context,
  required CDNService current,
  required CDNService next,
}) {
  return showDialog<CdnStallDecision>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _CdnStallDialog(current: current, next: next),
  );
}

class _CdnStallDialog extends StatefulWidget {
  final CDNService current;
  final CDNService next;

  const _CdnStallDialog({required this.current, required this.next});

  @override
  State<_CdnStallDialog> createState() => _CdnStallDialogState();
}

class _CdnStallDialogState extends State<_CdnStallDialog> {
  static const _initialCountdown = 3;

  int _countdown = _initialCountdown;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_countdown == 1) {
        timer.cancel();
        Navigator.of(context).pop(CdnStallDecision.timedOut);
      } else {
        setState(() => _countdown--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('视频似乎卡住了'),
      content: Text(
        '是否从「${widget.current.desc}」切换到「${widget.next.desc}」？\n'
        '$_countdown 秒后将自动切换。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(CdnStallDecision.cancel),
          child: const Text('暂不切换'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(CdnStallDecision.switchNow),
          child: const Text('立即切换'),
        ),
      ],
    );
  }
}
