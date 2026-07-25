import 'package:PiliPlus/common/widgets/custom_toast.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

void showCdnSwitchedToast({
  required CDNService next,
  required bool isFullScreen,
  required VoidCallback onRevert,
}) {
  SmartDialog.showToast(
    '',
    alignment: isFullScreen ? const Alignment(0, 0.7) : null,
    displayTime: const Duration(seconds: 6),
    displayType: SmartToastType.last,
    usePenetrate: true,
    consumeEvent: true,
    builder: (context) => _CdnSwitchedToast(next: next, onRevert: onRevert),
  );
}

class _CdnSwitchedToast extends StatelessWidget {
  const _CdnSwitchedToast({required this.next, required this.onRevert});

  final CDNService next;
  final VoidCallback onRevert;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final foreground = colorScheme.onPrimaryContainer;

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
              '视频卡顿，已切换到「${next.desc}」',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: foreground),
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: foreground,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 13),
            ),
            onPressed: () {
              SmartDialog.dismiss(status: SmartStatus.toast);
              onRevert();
            },
            child: const Text('切回'),
          ),
        ],
      ),
    );
  }
}
