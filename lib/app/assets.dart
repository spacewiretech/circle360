/// Every asset in the app, exported from the Figma file.
abstract final class Img {
  static const logoPin = 'assets/images/logo_pin.png';
  static const logoWordmark = 'assets/images/logo_wordmark.png';
  static const avatarMe = 'assets/images/avatar_me.png';
  static const avatarMeLarge = 'assets/images/avatar_me_large.png';
  static const avatarMom = 'assets/images/avatar_mom.png';
  static const avatarSister = 'assets/images/avatar_sister.png';
  /// The Figma frames crop one source illustration to two different windows: a 24x26 badge
  /// in the Home pill, and a 75x72 illustration on the empty Emergency Contacts screen.
  static const emergencyPill = 'assets/icons/emergency_pill.png';
  static const emergencyArt = 'assets/images/emergency_art.png';

  /// Device mockup shown above the sheet on the invite screen.
  static const inviteHero = 'assets/images/invite_hero.png';

  /// Hero mockup for the marketing site. The same frame as [inviteHero] but carrying the
  /// current wordmark — the in-app one still shows the pre-rebrand "Loc360".
  static const inviteHeroWeb = 'assets/images/invite_hero_web.png';

  /// The faces a tracked person can be given.
  ///
  /// There is no avatar upload backend, so a person's face is picked deterministically from
  /// their id — see [avatarFor]. A random pick would give the same person a different face on
  /// every poll.
  static const avatarPool = [avatarMom, avatarSister, avatarMe];

  /// A stable face for [id]. Same id, same face, on every device and every launch.
  static String avatarFor(String id) {
    if (id.isEmpty) return avatarMe;
    final hash = id.codeUnits.fold<int>(0, (sum, unit) => (sum * 31 + unit) & 0x7fffffff);
    return avatarPool[hash % avatarPool.length];
  }
}

abstract final class Svg {
  static const chevron = 'assets/icons/chevron.svg';
  static const chevronDown = 'assets/icons/chevron_down.svg';
  static const placePin = 'assets/icons/place_pin.svg';
  static const presenceDot = 'assets/icons/presence_dot.svg';
  static const addPlus = 'assets/icons/add_plus.svg';

  static const actionBeep = 'assets/icons/action_beep.svg';
  static const actionCall = 'assets/icons/action_call.svg';
  static const actionShareLive = 'assets/icons/action_share_live.svg';
  static const actionShareCurrent = 'assets/icons/action_share_current.svg';

  static const iconBack = 'assets/icons/icon_back.svg';
  static const iconCamera = 'assets/icons/icon_camera.svg';
  static const iconEdit = 'assets/icons/icon_edit.svg';
  static const iconFamily = 'assets/icons/icon_family.svg';
  static const iconSettings = 'assets/icons/icon_settings.svg';
}
