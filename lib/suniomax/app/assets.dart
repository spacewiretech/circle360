/// Every SunioMax asset, in one place — the same job `Img` does for Circle360.
///
/// None of these are in the repo yet; see `assets/suniomax/README.md`. Each is loaded through a
/// widget that falls back when the file is missing, so a reference here is a promise about a path,
/// not a guarantee the export has landed.
abstract final class SxImg {
  static const wordmark = 'assets/suniomax/wordmark.png';
  static const voiceLockHero = 'assets/suniomax/voice_lock_hero.png';
  static const micBlob = 'assets/suniomax/mic_blob.png';

  /// The device mockups behind the three onboarding sheets — phone, name, OTP in that order.
  /// Each already shows a SunioMax screen, which is what the design puts there.
  static const onboardingPhone = 'assets/suniomax/bg_image_1.png';
  static const onboardingName = 'assets/suniomax/bg_image_2.png';
  static const onboardingOtp = 'assets/suniomax/bg_image_3.png';
}
