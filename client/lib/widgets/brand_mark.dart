import 'package:flutter/material.dart';

import '../app/theme.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 44,
    this.showText = true,
    this.foreground = MetaServerColors.ink,
  });

  final double size;
  final bool showText;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.2),
          child: Image.asset(
            'assets/brand/metaserver-icon.png',
            width: size,
            height: size,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
          ),
        ),
        if (showText) ...[
          const SizedBox(width: 12),
          Text(
            'MetaServer',
            style: TextStyle(
              fontSize: size * 0.48,
              height: 1,
              color: foreground,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ],
    );
  }
}
