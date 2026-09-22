/// The event and property vocabulary, in one place.
///
/// Every name the app sends lives here rather than being typed at the call site. Mixpanel has no
/// schema and no rename: a single `"Payment Compelted"` becomes a permanent second event in the
/// UI, silently splitting a funnel in half. A constant makes that a compile error instead.
///
/// Naming follows Mixpanel's own convention — `Object Action`, Title Case, past tense — so the
/// event list reads as a sentence about what the user did.
library;

/// Event names.
abstract final class Ev {
  // --- Session and app lifecycle -------------------------------------------
  static const appLaunched = 'App Launched';
  static const appForegrounded = 'App Foregrounded';
  static const appBackgrounded = 'App Backgrounded';
  static const appTerminated = 'App Terminated';
  static const appCrashed = 'App Crashed';
  static const sessionStarted = 'Session Started';
  static const sessionEnded = 'Session Ended';

  // --- Navigation ----------------------------------------------------------
  static const screenViewed = 'Screen Viewed';
  static const screenExited = 'Screen Exited';
  static const backPressed = 'Back Pressed';

  // --- Generic interaction -------------------------------------------------
  static const elementTapped = 'Element Tapped';
  static const errorShown = 'Error Shown';
  static const deepLinkOpened = 'Deep Link Opened';

  // --- Ad attribution ------------------------------------------------------

  /// The answer to the iOS App Tracking Transparency prompt, whether it was just given or was
  /// already standing from an earlier launch.
  ///
  /// The opt-in rate this measures is the ceiling on how much iOS ad spend Facebook can attribute
  /// at all. A drop in it and a drop in real conversions look identical from inside the ad
  /// account, and this is the only thing that tells them apart.
  static const trackingConsentResolved = 'Tracking Consent Resolved';

  // --- Splash --------------------------------------------------------------
  static const splashResolved = 'Splash Resolved';

  // --- Onboarding ----------------------------------------------------------
  static const phoneEntryStarted = 'Phone Entry Started';
  static const phoneNumberEntered = 'Phone Number Entered';
  static const otpRequested = 'OTP Requested';
  static const otpRequestFailed = 'OTP Request Failed';
  static const otpEntryStarted = 'OTP Entry Started';
  static const otpSubmitted = 'OTP Submitted';
  static const otpVerified = 'OTP Verified';
  static const otpVerificationFailed = 'OTP Verification Failed';
  static const otpResendRequested = 'OTP Resend Requested';
  static const otpResendBlocked = 'OTP Resend Blocked';
  static const otpAttemptsExhausted = 'OTP Attempts Exhausted';
  static const nameEntryStarted = 'Name Entry Started';
  static const nameSubmitted = 'Name Submitted';
  static const nameSaveFailed = 'Name Save Failed';
  static const signupCompleted = 'Signup Completed';

  /// The confirmation dialog opened. Paired with [signedOut] and [signOutCancelled] so the
  /// confirm step has a measurable drop-off rather than being invisible — without it, a user who
  /// opens the dialog and backs out is indistinguishable from one who never tapped at all.
  static const signOutRequested = 'Sign Out Requested';
  static const signOutCancelled = 'Sign Out Cancelled';

  /// Carries `source` (`profile` or `settings`) — the app offers sign-out in two places and it is
  /// worth knowing which one people actually find.
  static const signedOut = 'Signed Out';

  // --- Paywall -------------------------------------------------------------
  static const paywallViewed = 'Paywall Viewed';
  static const paywallOfferLoaded = 'Paywall Offer Loaded';
  static const paywallOfferLoadFailed = 'Paywall Offer Load Failed';

  /// The promo above the sheet could not be played.
  ///
  /// Same argument as [paywallOfferLoadFailed]: the user sees a tasteful gradient and the app
  /// carries on selling, so a dead URL is invisible from every angle except a conversion number
  /// that quietly moved. The URL is operator-editable, which means it will eventually be edited
  /// wrong, and nobody would think to look at a config row for it.
  static const paywallVideoFailed = 'Paywall Video Failed';

  // --- UPI app selection ---------------------------------------------------
  static const upiAppsDiscovered = 'UPI Apps Discovered';
  static const upiDiscoveryFailed = 'UPI Discovery Failed';
  static const upiAppPreselected = 'UPI App Preselected';
  static const upiPickerOpened = 'UPI Picker Opened';
  static const upiPickerDismissed = 'UPI Picker Dismissed';
  static const upiAppChanged = 'UPI App Changed';

  // --- Mandate and checkout ------------------------------------------------
  static const subscribeTapped = 'Subscribe Tapped';
  static const subscribeTapIgnored = 'Subscribe Tap Ignored';
  static const mandateStartRequested = 'Mandate Start Requested';
  static const mandateStartSucceeded = 'Mandate Start Succeeded';
  static const mandateStartRefused = 'Mandate Start Refused';
  static const mandateAlreadyEntitled = 'Mandate Already Entitled';
  static const upiIntentLaunched = 'UPI Intent Launched';
  static const upiAppOpened = 'UPI App Opened';
  static const upiAppReturned = 'UPI App Returned';
  static const checkoutRestarted = 'Checkout Restarted';
  static const checkoutLaunchFailed = 'Checkout Launch Failed';
  static const checkoutVerifiedCallback = 'Checkout Verified Callback';
  static const checkoutFailedCallback = 'Checkout Failed Callback';
  static const checkoutTimedOut = 'Checkout Timed Out';
  static const checkoutOrphanCallback = 'Checkout Orphan Callback';

  // --- Confirmation --------------------------------------------------------
  static const entitlementPollStarted = 'Entitlement Poll Started';
  static const entitlementPollFailed = 'Entitlement Poll Failed';
  static const paymentCompleted = 'Payment Completed';
  static const paymentStatusViewed = 'Payment Status Viewed';
  static const paymentStatusChecked = 'Payment Status Checked';
  static const paymentConfirmedLate = 'Payment Confirmed Late';
  static const paymentStatusExhausted = 'Payment Status Exhausted';
  static const retryPaymentTapped = 'Retry Payment Tapped';
  static const entitlementLapsed = 'Entitlement Lapsed';
  static const billingIssueShown = 'Billing Issue Shown';
  static const manageBillingTapped = 'Manage Billing Tapped';

  // --- Location ------------------------------------------------------------
  static const locationPermissionRequested = 'Location Permission Requested';
  static const locationPermissionResult = 'Location Permission Result';
  static const locationSettingsOpened = 'Location Settings Opened';
  static const locationPermissionSkipped = 'Location Permission Skipped';
  static const locationTrackingStarted = 'Location Tracking Started';
  static const locationTrackingStopped = 'Location Tracking Stopped';
  static const locationTrackingFailed = 'Location Tracking Failed';
  static const diagnosticsRefreshed = 'Diagnostics Refreshed';

  // --- Home and family -----------------------------------------------------
  static const homeViewed = 'Home Viewed';
  static const addPersonSheetOpened = 'Add Person Sheet Opened';
  static const addPersonSheetDismissed = 'Add Person Sheet Dismissed';
  static const addPersonSubmitted = 'Add Person Submitted';
  static const addPersonFailed = 'Add Person Failed';
  static const inviteDialogShown = 'Invite Dialog Shown';
  static const inviteDialogDismissed = 'Invite Dialog Dismissed';
  static const personActionTapped = 'Person Action Tapped';
  static const personRemoveRequested = 'Person Remove Requested';
  static const personRemoved = 'Person Removed';
  static const personRemoveCancelled = 'Person Remove Cancelled';
  static const requestAccepted = 'Request Accepted';
  static const requestDeclined = 'Request Declined';
  static const trackingBannerTapped = 'Tracking Banner Tapped';

  // --- Invite --------------------------------------------------------------
  static const invitePhoneEntered = 'Invite Phone Entered';
  static const inviteSent = 'Invite Sent';
  static const inviteFailed = 'Invite Failed';

  // --- Emergency and account ----------------------------------------------
  static const emergencyContactAdded = 'Emergency Contact Added';
  static const emergencyContactRemoved = 'Emergency Contact Removed';
  static const emergencyContactCalled = 'Emergency Contact Called';
  static const termsTapped = 'Terms Tapped';
  static const privacyTapped = 'Privacy Tapped';

  // --- SunioMax ------------------------------------------------------------
  //
  // The second app in this build. Every event here also carries `app: suniomax`, so these names
  // are only for the surfaces SunioMax has and Circle360 does not — its onboarding and paywall
  // reuse the events above, because they reuse the ViewModels that send them.
  //
  // Nothing here ever carries the voice phrase or the backup passcode. Both are credentials: one
  // unlocks the phone and the other is what a user types when it fails. Shape and length are
  // reportable; the value never is.
  static const languageSelected = 'Language Selected';
  static const voiceLockChanged = 'Voice Lock Changed';
  static const voicePhraseSaved = 'Voice Phrase Saved';
  static const backupPasscodeSet = 'Backup Passcode Set';
  static const appLockChanged = 'App Lock Changed';
  static const findPhoneChanged = 'Find Phone Changed';
  static const clapPatternSaved = 'Clap Pattern Saved';
  static const findPhoneAlertChanged = 'Find Phone Alert Changed';
  static const tapToSpeakTapped = 'Tap To Speak Tapped';

  /// A spoken onboarding prompt could not be played.
  ///
  /// The same argument as [paywallVideoFailed], and it applies harder here. These clips exist
  /// for users who cannot comfortably read the screen, and a clip that never opens is *silent* —
  /// there is no gradient, no spinner and no error, just a screen that looks exactly as it did
  /// before the feature existed. The URLs are operator-editable, which means one will eventually
  /// be edited wrong, and nobody would think to look at a config row for it.
  ///
  /// Carries the clip and the host, never the URL: the row is operator-entered and could hold a
  /// signed link with a token in its query string.
  static const onboardingAudioFailed = 'Onboarding Audio Failed';
}

/// Property keys.
///
/// Same reasoning as [Ev]: Mixpanel treats `app_id` and `appId` as two unrelated columns, and a
/// funnel breakdown on the wrong one silently returns "undefined" for half the users.
abstract final class P {
  // --- Ambient (attached automatically) ------------------------------------
  static const screen = 'screen';
  static const previousScreen = 'previous_screen';
  static const routePath = 'route_path';
  static const sessionId = 'session_id';
  static const navType = 'nav_type';
  static const isModal = 'is_modal';
  static const secondsOnScreen = 'seconds_on_screen';
  static const exitType = 'exit_type';
  static const blocked = 'blocked';

  // --- Super properties ----------------------------------------------------
  //
  // App version, build number, OS, device model and screen size are deliberately absent: the
  // native Mixpanel SDKs attach `$app_version_string`, `$app_build_number`, `$os`, `$os_version`,
  // `$manufacturer` and `$model` to every event themselves. Registering our own would need
  // `package_info_plus` purely to duplicate them under second, non-standard names that none of
  // Mixpanel's built-in reports know how to read.
  static const env = 'env';

  /// Which of the two apps in this build produced the event — `circle360` or `suniomax`.
  ///
  /// Registered at boot, before anything is tracked, so it is on every event including the
  /// buffered launch ones. Without it the two products share one funnel and neither is readable:
  /// they have different screens, different conversion rates and different audiences, and only
  /// this tells them apart. See `lib/suniomax/data/app_variant.dart`.
  static const app = 'app';
  static const appVersion = 'app_version';
  static const buildNumber = 'build_number';
  static const previousVersion = 'previous_version';
  static const buildMode = 'build_mode';
  static const appLanguage = 'app_language';
  static const appLocale = 'app_locale';
  static const utcOffsetMinutes = 'utc_offset_minutes';
  static const installId = 'install_id';
  static const daysSinceInstall = 'days_since_install';
  static const backendMode = 'backend_mode';
  static const isSignedIn = 'is_signed_in';
  static const paymentType = 'payment_type';
  static const entitled = 'entitled';
  static const inTrial = 'in_trial';
  static const hasEverSubscribed = 'has_ever_subscribed';
  static const billingState = 'billing_state';
  static const preferredUpiApp = 'preferred_upi_app';

  // --- Session -------------------------------------------------------------
  static const isFirstLaunch = 'is_first_launch';
  static const coldStart = 'cold_start';
  static const secondsSinceLastOpen = 'seconds_since_last_open';
  static const secondsBackgrounded = 'seconds_backgrounded';
  static const sessionSeconds = 'session_seconds';
  static const durationSeconds = 'duration_seconds';
  static const screensViewed = 'screens_viewed';
  static const queuedLagMs = 'queued_lag_ms';

  // --- Interaction ---------------------------------------------------------
  static const elementId = 'element_id';
  static const label = 'label';
  static const source = 'source';
  static const trigger = 'trigger';
  static const reason = 'reason';
  static const message = 'message';
  static const code = 'code';
  static const error = 'error';
  static const stackHead = 'stack_head';
  static const fatal = 'fatal';
  static const ms = 'ms';

  // --- Onboarding ----------------------------------------------------------
  static const destination = 'destination';
  static const valid = 'valid';
  static const entryMethod = 'entry_method';
  static const attemptsUsed = 'attempts_used';
  static const attemptsLeft = 'attempts_left';
  static const resendsUsed = 'resends_used';
  static const secondsToVerify = 'seconds_to_verify';
  static const isNewUser = 'is_new_user';
  static const hasName = 'has_name';
  static const nameLength = 'name_length';
  static const secondsRemaining = 'seconds_remaining';

  // --- Paywall and payment -------------------------------------------------
  static const trialAvailable = 'trial_available';
  static const trialPrice = 'trial_price';
  static const planPrice = 'plan_price';
  static const trialDays = 'trial_days';
  static const offerType = 'offer_type';
  static const amount = 'amount';
  static const paymentAttemptId = 'payment_attempt_id';
  static const attemptNumber = 'attempt_number';
  static const subscriptionId = 'subscription_id';
  static const environment = 'environment';
  static const flow = 'flow';
  static const outcome = 'outcome';
  static const sdkVerified = 'sdk_verified';
  static const pollAttempts = 'poll_attempts';
  static const maxAttempts = 'max_attempts';
  static const attempt = 'attempt';
  static const attempts = 'attempts';
  static const totalSeconds = 'total_seconds';
  static const secondsInUpiApp = 'seconds_in_upi_app';
  static const secondsInCheckout = 'seconds_in_checkout';
  static const secondsSinceCheckout = 'seconds_since_checkout';
  static const cfStatus = 'cf_status';
  static const cfCode = 'cf_code';
  static const cfType = 'cf_type';
  static const previousPaymentType = 'previous_payment_type';

  // --- UPI -----------------------------------------------------------------
  static const appId = 'app_id';
  static const appName = 'app_name';
  static const appIds = 'app_ids';
  static const fromAppId = 'from_app_id';
  static const toAppId = 'to_app_id';
  static const upiAppCount = 'upi_app_count';
  static const availableCount = 'available_count';
  static const positionInList = 'position_in_list';
  static const count = 'count';

  // --- Location ------------------------------------------------------------
  static const permission = 'permission';
  static const previousPermission = 'previous_permission';
  static const result = 'result';
  static const trackingActive = 'tracking_active';

  // --- Home and family -----------------------------------------------------
  static const peopleCount = 'people_count';
  static const requestsCount = 'requests_count';
  static const state = 'state';
  static const action = 'action';
  static const isExistingUser = 'is_existing_user';
  static const inviterName = 'inviter_name';
  static const linkType = 'link_type';

  // --- Ad attribution ------------------------------------------------------

  /// The raw ATT authorisation status — `authorized`, `denied`, `restricted`, `notDetermined`.
  static const status = 'status';
  static const granted = 'granted';

  /// False when the status was already settled on a previous launch, so the opt-in *rate* can be
  /// measured over the users who were actually asked rather than over every launch.
  static const prompted = 'prompted';

  // --- SunioMax ------------------------------------------------------------
  //
  // The language a user picked is reported through [appLanguage] and [appLocale] above, which
  // already exist as super properties — a second pair of keys for the same fact would split
  // every breakdown that uses them.

  /// Which way a switch was moved. On [Ev.voiceLockChanged] this is the whole event.
  static const enabled = 'enabled';

  /// Words in the voice phrase, never the phrase. A one-word phrase is far easier for the
  /// recogniser to miss than a three-word one, and that is the difference worth seeing when a
  /// user reports the lock not triggering.
  static const phraseWordCount = 'phrase_word_count';

  /// Whether a backup passcode exists. A user with a voice phrase and no passcode has no way
  /// back in when the microphone fails, which is the support case this predicts.
  static const hasPasscode = 'has_passcode';

  /// How many apps the per-app lock covers.
  static const lockedAppCount = 'locked_app_count';

  /// Claps in the pattern.
  static const clapCount = 'clap_count';

  /// Which Find Phone alert changed: `sound`, `vibration` or `flashlight`.
  static const alertType = 'alert_type';

  /// Which `app_config` row a failing asset came from — `suniomax_audio_otp_url` and the like.
  ///
  /// The operator-facing identity of the problem, and the only one that is actionable: a screen
  /// name says where it was noticed, this says which row to fix. Sent alongside [source], which
  /// carries the host exactly as it does on [Ev.paywallVideoFailed], so one breakdown covers a
  /// dead bucket across both features.
  static const configKey = 'config_key';
}

/// Values for [P.exitType] — how a screen stopped being the one on top.
abstract final class ExitType {
  static const pop = 'pop';
  static const replaced = 'replaced';
  static const removed = 'removed';
}

/// Values for [P.navType].
abstract final class NavType {
  static const push = 'push';
  static const replace = 'replace';
  static const pop = 'pop';
}

/// Values for [P.backendMode] — which rung of the repository ladder is live. Without this, QA
/// traffic running on the fake repositories is indistinguishable from real users in every funnel.
abstract final class BackendMode {
  static const supabase = 'supabase';
  static const fast2sms = 'fast2sms';
  static const fake = 'fake';
}
