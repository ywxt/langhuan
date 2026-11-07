import 'package:flutter/material.dart';

/// Summary row for configured sources and transforms. Editing belongs in the
/// detail sheet; the leading widget may supply a list's reorder handle.
class ConfigurationListCard extends StatelessWidget {
  const ConfigurationListCard({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.status,
    this.onTap,
    this.margin = const EdgeInsets.only(bottom: 12),
    this.borderRadius,
  });

  final Widget leading, status;
  final String title, subtitle;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) => Card(
    margin: margin,
    shape: borderRadius == null
        ? null
        : RoundedRectangleBorder(borderRadius: borderRadius!),
    clipBehavior: Clip.antiAlias,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: leading,
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 100),
            child: status,
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    ),
  );
}
