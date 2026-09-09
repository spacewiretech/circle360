-- ---------------------------------------------------------------- Facebook Ads conversions
--
-- The app is bought through Facebook Ads, and until now nothing told Facebook which of those
-- installs went on to pay — so its optimiser was training on installs, not on payers. These rows
-- are what the client needs to report that.

-- The prices as public numbers, beside the labels they mirror.
--
-- Facebook's Purchase event bids against a value and an ISO currency code. The paywall only ever
-- held display copy — '₹3', '₹499' — and deriving a number from that means parsing a currency
-- symbol off marketing text, which breaks the first time a label reads '₹3 only'.
--
-- The authoritative amounts already exist as `cashfree_trial_amount` and
-- `cashfree_recurring_amount`, but both are private: the anon key the app holds cannot read
-- them, and making them public would put billing inputs on the device. These are public copies
-- for reporting only. Keep all three in step when the price changes — a wrong value here
-- misreports return on ad spend to Facebook, and cannot charge anybody anything.
insert into public.app_config (key, value, is_public, description) values
  ('trial_price_amount', '3', true,
   'Trial charge as a bare number, for ad-network conversion values. Must track '
   'trial_price_label and cashfree_trial_amount. Not authoritative for billing.'),
  ('plan_price_amount', '499', true,
   'Monthly charge as a bare number, for ad-network conversion values. Must track '
   'plan_price_label and cashfree_recurring_amount. Not authoritative for billing.'),
  ('currency_code', 'INR', true,
   'ISO 4217 code sent with every ad-network conversion event.')
on conflict (key) do nothing;

-- The Facebook app, and the off switch.
--
-- Note what this row is *not*. Both native SDKs read the App ID and the Client Token out of
-- AndroidManifest.xml and Info.plist at process start, before Dart runs and long before this
-- table is fetched — so this is not what the SDK initialises from. It exists so that reporting
-- can be silenced, or pointed at a different Facebook app mid-campaign, without shipping a
-- release: blank app id, or facebook_events_enabled = false, and the client's Facebook sink
-- never starts. Same reasoning as mixpanel_token in 20260907010000.
--
-- Seeded with the live value rather than left empty, which is a deliberate departure from
-- `mixpanel_token` and the Cashfree rows. Those are credentials, and are pasted into the
-- dashboard so they stay out of git history. An App ID is not: it is public by construction, it
-- is already compiled into every shipped binary via the manifest and plist, and it appears in
-- the ads themselves. Seeding it is what makes applying this migration turn reporting on, rather
-- than leaving a silent no-op that looks identical to a working integration.
--
-- The Facebook **app secret** must never be added to this table. It is a server-side Conversions
-- API credential, this app has no Conversions API, and the client SDK has no use for it.
-- app_config_secrets_stay_private would refuse it as public in any case, which is correct.
--
-- The Client Token is likewise absent, and would fail that same constraint on `_token$`. Unlike
-- mixpanel_token it needs no named exception, because it does not belong here at all — the SDK
-- can only read it from the manifest and plist.
insert into public.app_config (key, value, is_public, description) values
  ('facebook_app_id', '2559504461180471', true,
   'Facebook App ID. Public by design — it ships inside every installed app. Blank disables '
   'conversion reporting entirely. The SDK initialises from the manifest/plist, not from here; '
   'this row is the off switch. Never store the app secret in this table.'),
  ('facebook_events_enabled', 'true', true,
   'Master switch for Facebook conversion events. False stops the client reporting without '
   'requiring a release or clearing the app id.')
on conflict (key) do nothing;
