# `lib/website/` — the marketing site

**This is the entire web build.** `lib/main.dart` branches on `kIsWeb` and runs
`Circle360SiteApp`; the app proper never runs on web.

Deliberately independent of the app: no `ProviderScope`, no repositories, no network. It borrows
only the brand — `AppColors`, the wordmark, the hero mockup.

| File | What it does |
|---|---|
| `site_app.dart` | The root widget. 28 lines. |
| `site_router.dart` | `SiteRoutes` + `siteRouter`. Separate from `appRouter` on purpose — the site shares the brand but none of the app's state, gates or redirects. |
| `site_shell.dart` | `ContentWidth` (centres and caps at `SiteShape.maxWidth` with the right gutter) and `SiteSection` (full-width band with vertical rhythm). 409 lines. |
| `site_theme.dart` | `Breaks` — below `mobile` everything is one column, between the two the grids halve, above `tablet` the hero splits in two. Plus `SiteShape`. |
| `widgets.dart` | `SiteButton` (null `onPressed` renders the muted "coming soon" state), the download buttons, and a URL opener that swallows failures rather than throwing into a build. |
| `site_copy.dart` | **Everything on the site that is a business fact rather than a design decision.** `SitePlaceholders` is the only place an address, email, phone or store URL is hard-coded — fill these in, and only these, before launch. Its class doc still says "all of it is a placeholder today", which is now out of date: entity, address, email and domain are real. |
| `policy_docs.dart` | `PolicyDoc` / `PolicySection` — the content of all five legal pages. 489 lines. |
| `pages/home_page.dart` | Landing: hero -> features -> how it works -> pricing -> FAQ -> download. |
| `pages/policy_page.dart` | Renders any `PolicyDoc`. All five legal pages go through here. |
| `pages/contact_page.dart` | Required by the payment provider's merchant checklist; every policy page and the FAQ point at it. |
| `pages/invite_page.dart` | Where an SMS invite lands when the recipient has no app. |
| `url_strategy.dart` | Conditional export picking one of the two below. |
| `url_strategy_web.dart` | Drops the `#` from site URLs via `usePathUrlStrategy()`. |
| `url_strategy_stub.dart` | No-op off the web, where there is no URL bar to configure. |

## Gotchas

- **`pages/invite_page.dart` and [../data/deeplink_service.dart](../data/deeplink_service.dart)
  must agree.** The URL shape is `/invite/<code>?from=<name>`; if it changes in one, change it in
  the other.
- **Path URL strategy needs host support.** `url_strategy_web.dart` drops the `#`, which requires
  the host to rewrite unknown paths to `index.html` — otherwise every route except `/` 404s on a
  hard refresh.
- **`SitePlaceholders.supportPhone` is still `+91 XXXXX XXXXX`, and `test/website_test.dart`
  fails on it.** That failing test is the intended alarm, not a broken test — it asserts the
  *shape* of an unfilled placeholder so new ones are caught automatically. Fill the phone in and
  it passes.
- `playStoreUrl` and `appStoreUrl` are `null` **deliberately** — that is the "coming soon" state
  the download buttons read. A test pins them null; flip both when the listings go live.
