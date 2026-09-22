# `lib/widgets/` — shared UI

15 widgets, all matching the Figma design. Sizes here are usually literal design values, not
arbitrary choices — check the doc comment before changing one.

| File | What it does |
|---|---|
| `person_card.dart` | A tracked person. Tapping the row expands it **in place** to reveal four actions. `_WaitingDot` stands in for the chevron on a card that cannot expand, so rows stay the same width. |
| `request_card.dart` | Someone has added this account and is waiting for it to share back. Styled deliberately *apart* from `PersonCard` — it is the one place the user grants access to their own position, so it must not look like just another row. |
| `tracking_banner.dart` | Says whether this device's location is actually going out. The most important honesty affordance in the app: without it, "sharing is on" and "sharing silently died because an OEM battery manager killed the service" look identical. |
| `otp_field.dart` | The boxed code entry. Deliberately **one** `TextField` holding the whole code with the boxes drawn as decoration — six separate fields cannot handle a pasted or autofilled code, because a per-box `maxLength: 1` truncates it. Shared by both apps in this build: `boxBuilder` restyles the boxes (SunioMax draws circles) while the caret pinning, the autofill group and the completion guard stay in one place. |
| `phone_field.dart` | Country code + 10-digit number in the bordered 50pt box. `TextFieldBox` is the same box as a single-line text field, used by the name step. |
| `sheet_surface.dart` | The white panel every screen sits on — full width, bottom-pinned, 56pt radius on the top corners only. Also the draggable variant Home uses over the map. |
| `map_background.dart` | The map every post-onboarding screen sits on. OpenStreetMap tiles, no API key. Interaction is **off** by default because the map is usually scenery behind a sheet; Home turns it on. |
| `primary_button.dart` | The solid blue 48pt action button at the foot of every sheet. Disabled keeps its shape and fades — the design has no separate disabled style. |
| `action_tile.dart` | One of the four circular actions revealed when a person's card expands. |
| `avatar.dart` | Circular photo with the optional presence dot in its lower-right. The dot is a fixed 12pt regardless of avatar size, so it is not scaled. |
| `floating_pill.dart` | White pill floating over the map ("Emergency Contacts" on Home), plus `CircleBackButton`, the 40pt round back control. |
| `brand_logo.dart` | `LogoPin` (59x66 in sheets, 90x101 on splash) and `LogoWordmark` (92x22 / 121x29). |
| `app_icon.dart` | A Figma-exported SVG at an explicit size. The exports carry their own strokes and fills, so `color` is only for the few glyphs placed on a coloured surface. |
| `add_person_sheet.dart` | Name + number collected in a modal. The Figma flow for inviting is not designed yet, so this reuses the onboarding field styling and returns the pair to the caller. |
| `terms_footer.dart` | "By continuing you agree to…". `compact` renders the paywall variant — just the two links separated by a pipe. |
