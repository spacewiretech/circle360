import 'package:flutter/material.dart';

import '../app/assets.dart';
import '../app/theme/app_typography.dart';

/// The pin mark. 59x66 inside the sheets, 90x101 on the splash.
class LogoPin extends StatelessWidget {
  const LogoPin({super.key, this.height = 66});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      Img.logoPin,
      height: height,
      width: height * 90 / 101,
      fit: BoxFit.contain,
    );
  }
}

/// The "Loc360" wordmark. 92x22 inside the sheets, 121x29 on the splash.
class LogoWordmark extends StatelessWidget {
  const LogoWordmark({super.key, this.height = 22});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      Img.logoWordmark,
      height: height,
      width: height * 121 / 29,
      fit: BoxFit.contain,
    );
  }
}

/// "Welcome to  Loc360" — the wordmark sits on the heading baseline.
class WelcomeHeading extends StatelessWidget {
  const WelcomeHeading({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('Welcome to', style: AppText.welcome),
        const SizedBox(width: 10),
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: LogoWordmark(),
        ),
      ],
    );
  }
}

/// Pin above wordmark, used at the top of the paywall and home sheets.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.pinHeight = 66, this.gap = 8});

  final double pinHeight;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LogoPin(height: pinHeight),
        SizedBox(height: gap),
        const LogoWordmark(),
      ],
    );
  }
}
