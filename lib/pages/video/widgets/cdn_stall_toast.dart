import 'dart:async';

import 'package:PiliPlus/common/widgets/custom_toast.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

enum CdnStallDecision { switchNow, timedOut, cancel }

Future<CdnStallDecision> showCdnStallToast({
  required CDNService next,
  required bool isFullScreen,
}) {
  final completer = Completer<CdnStallDecision>();
  late final Timer timeoutTimer;
  bool isCompleting = false;

  void complete(CdnStallDecision decision) {
    if (isCompleting || completer.isCompleted) return;
    isCompleting = true;
    timeoutTimer.cancel();
    SmartDialog.dismiss(status: SmartStatus.toast).whenComplete(() {
      if (!completer.isCompleted) {
        completer.complete(decision);
      }
    });
  }

  timeoutTimer = Timer(
    const Duration(seconds: 3),
    () => complete(CdnStallDecision.timedOut),
  );
  SmartDialog.showToast(
    '',
    alignment: isFullScreen ? const Alignment(0, 0.7) : null,
    displayTime: const Duration(seconds: 3),
    displayType: SmartToastType.last,
    usePenetrate: true,
    consumeEvent: true,
    builder: (context) => _CdnStallToast(
      next: next,
      onDecision: complete,
    ),
  );
  return completer.future;
}

class _CdnStallToast extends StatefulWidget {
  const _CdnStallToast({required this.next, required this.onDecision});

  final CDNService next;
  final ValueChanged<CdnStallDecision> onDecision;

  @override
  State<_CdnStallToast> createState() => _CdnStallToastState();
}

class _CdnStallToastState extends State<_CdnStallToast> {
  int _countdown = 3;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _countdown == 1) {
        timer.cancel();
        return;
      }
      setState(() => _countdown--);
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final foreground = colorScheme.onPrimaryContainer;
    final buttonStyle = TextButton.styleFrom(
      foregroundColor: foreground,
      minimumSize: Size.zero,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: 13),
    );

    return Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width - 32,
      ),
      margin: EdgeInsets.only(
        bottom: MediaQuery.viewPaddingOf(context).bottom + 30,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(
          alpha: CustomToast.toastOpacity,
        ),
        borderRadius: const BorderRadius.all(Radius.circular(20)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              '视频卡顿，$_countdown 秒后切换到「${widget.next.desc}」',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: foreground),
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            style: buttonStyle,
            onPressed: () => widget.onDecision(CdnStallDecision.cancel),
            child: const Text('取消'),
          ),
          TextButton(
            style: buttonStyle,
            onPressed: () => widget.onDecision(CdnStallDecision.switchNow),
            child: const Text('立即切换'),
          ),
        ],
      ),
    );
  }
}
