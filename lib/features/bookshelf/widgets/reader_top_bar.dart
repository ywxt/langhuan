import 'package:flutter/material.dart';

class ReaderTopBar extends StatelessWidget {
  const ReaderTopBar({
    super.key,
    required this.topPadding,
    required this.chapterTitle,
    required this.backgroundColor,
    required this.titleTextStyle,
    required this.bookmarksTooltip,
    required this.refreshTooltip,
    required this.isRefreshing,
    required this.onBack,
    required this.onOpenBookmarks,
    required this.onRefresh,
  });

  final double topPadding;
  final String chapterTitle;
  final Color backgroundColor;
  final TextStyle? titleTextStyle;
  final String bookmarksTooltip;
  final String refreshTooltip;
  final bool isRefreshing;
  final VoidCallback onBack;
  final VoidCallback onOpenBookmarks;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: backgroundColor,
      padding: EdgeInsets.only(top: topPadding),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack),
          Expanded(
            child: Text(
              chapterTitle,
              style: titleTextStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.bookmarks_outlined),
            tooltip: bookmarksTooltip,
            onPressed: onOpenBookmarks,
          ),
          IconButton(
            icon: isRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: refreshTooltip,
            onPressed: isRefreshing ? null : onRefresh,
          ),
        ],
      ),
    );
  }
}
