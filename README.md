# Event Pulse

A Flutter app that watches a [Planning Center Check-Ins](https://developer.planning.center/docs/#/overview/)
event and shows who has checked out, refreshing on a timer. It is built to be
left running on a screen — pick an event once, and newly checked-out people are
highlighted as they appear.

Runs on Android, Windows, macOS, Linux, iOS, and the web.

<!-- Screenshot: add docs/screenshot.png and uncomment.
![Event Pulse](docs/screenshot.png)
-->

## Features

- **Live check-out list** for a selected event, polled on a configurable interval.
- **New arrivals stand out** with an accent row, a NEW badge, and a live count,
  fading back to normal after 30 seconds.
- **Relative times** — "7 min ago" next to the clock time, so the board reads
  at a glance.
- **Display mode** shows names only, much larger, for a screen mounted on a
  wall.
- **Light and dark themes** — follow the system setting, or pin one in Settings.
- **Only Today** filter to hide check-outs carried over from previous days.
- **Sortable** by name or check-out time; your sort survives each refresh.
- **Remembers** your event, settings, and display mode between launches.
- **Keep Screen Awake** for unattended displays.
- **Visible failures** — a banner with a Retry button instead of a list that
  quietly stops updating.

## Setup

### Prerequisites

- Flutter SDK (Dart `^3.6.1`) — `flutter doctor` should be clean for the
  platforms you intend to build.
- A Planning Center account with Check-Ins access.

### 1. Get API credentials

In Planning Center, go to **Developer → [Personal Access Tokens](https://api.planningcenteronline.com/oauth/applications)**
and create a token. You will get an **Application ID** and a **Secret**. The
token needs read access to Check-Ins.

### 2. Create your secrets file

Credentials are **not** stored in source. They are supplied at build time and
read via `String.fromEnvironment` in [`lib/api_credentials.dart`](lib/api_credentials.dart).

```bash
cp secrets.example.json secrets.json
```

Then fill in `secrets.json`:

```json
{
  "PCO_APP_ID": "your application id",
  "PCO_SECRET": "your secret or pco_pat_ token"
}
```

`secrets.json` is git-ignored and must stay that way.

### 3. Install dependencies

```bash
flutter pub get
```

### 4. Run

```bash
flutter run --dart-define-from-file=secrets.json
```

In VS Code just press **F5** — [`.vscode/launch.json`](.vscode/launch.json)
already passes the flag for debug, profile, and release.

If you launch without the flag the app starts and tells you the credentials are
missing, rather than silently failing every request.

## Building

The `--dart-define-from-file` flag is required for **every** build, not just
`run`:

```bash
flutter build apk --release --dart-define-from-file=secrets.json
```

```bash
flutter build windows --release --dart-define-from-file=secrets.json
```

```bash
flutter build web --release --dart-define-from-file=secrets.json
```

> **Note on credentials in builds.** `--dart-define` values are compiled into
> the binary. That keeps them out of version control, but anyone who has the
> installed app can still extract them. Use a token scoped to only what this app
> needs, and don't distribute builds more widely than you'd distribute the
> token.

## Settings

Open the **⋮** menu → **Settings**.

| Setting | Default | Notes |
| --- | --- | --- |
| Poll Interval (sec) | 5 | Clamped to 1–3600. Shorter intervals risk HTTP 429 rate limiting. |
| Result Limit | 100 | Clamped to 1–100; 100 is the API's `per_page` maximum. |
| Only Today | Off | Hides check-outs from previous days, using your local timezone. |
| Keep Screen Awake | On | Ignored on platforms without wakelock support. |
| Theme | System | System follows the device; Light and Dark pin it. |

Settings and the selected event persist via `shared_preferences`. Applying
settings refreshes immediately rather than waiting out the countdown.

The **↻** button in the toolbar reloads the event list and check-outs on demand —
useful if the app started without a network connection.

## Display mode

The fullscreen button in the toolbar switches to display mode, meant to be read
from across a room:

- Each card shows **only the name**, at roughly double size, across the full
  width of the card, wrapping to a second line rather than truncating. The
  avatar, both timestamps, and the NEW badge are dropped so nothing competes
  with the name.
- New arrivals still stand out, from the card's accent colour and border.
- The event name becomes the header, and the toolbar and event picker disappear.

A faint button in the top-right corner exits. The choice is remembered between
launches, so a wall-mounted device comes back up in display mode after a
restart.

Pair it with **Keep Screen Awake** so the device does not sleep.

## How it works

The app polls this endpoint, newest check-out first:

```
GET https://api.planningcenteronline.com/check-ins/v2/check_ins
      ?include=event,person,checked_out_by
      &order=-checked_out_at
      &where[event_id]=<event_id>
      &filter=checked_out
      &per_page=<result limit>
```

Because results come back newest-first, the **Only Today** filter is applied
client-side. If an event has more check-outs today than your Result Limit, the
oldest of today's will fall off the bottom — raise the limit if that matters.

### Project layout

| File | Responsibility |
| --- | --- |
| [`lib/main.dart`](lib/main.dart) | UI, polling timer, settings dialog |
| [`lib/theme.dart`](lib/theme.dart) | Light/dark palettes and the highlight duration |
| [`lib/checkout.dart`](lib/checkout.dart) | `Checkout` model plus pure parse/filter/sort logic |
| [`lib/planning_center_api.dart`](lib/planning_center_api.dart) | HTTP, pagination, and error messages |
| [`lib/api_credentials.dart`](lib/api_credentials.dart) | Build-time credentials |
| [`test/checkout_test.dart`](test/checkout_test.dart) | Unit tests for the logic in `checkout.dart` |

Check-out times are kept as `DateTime` and sorted as instants. Sorting the
formatted display string would order by month *name* — "Apr" before "Jan".

To work on the UI without hitting the real API, point the app at a local stub
that serves the same JSON shape:

```bash
flutter run --dart-define-from-file=secrets.json --dart-define=PCO_API_BASE=http://localhost:8788
```


## Tests

```bash
flutter test
```

The suite covers name building, the Only Today filter, and both sort orders. It
needs no credentials, since the logic under test is pure.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| "Planning Center credentials are not set." | You launched without `--dart-define-from-file=secrets.json`. |
| "Not authorized (401)." | Wrong `PCO_APP_ID` / `PCO_SECRET`, or the token was revoked. |
| "Access denied (403)." | The token lacks Check-Ins permission. |
| "Rate limited (429)." | Poll interval is too short. Raise it. |
| Event dropdown is empty | No network at startup, or the account has no Check-Ins events. Press **↻**. |
| Android build fails on Kotlin metadata | Something raised `wakelock_plus` past 1.3.x. See the pin note in [`pubspec.yaml`](pubspec.yaml). |

## Notes for maintainers

- `wakelock_plus` is deliberately pinned to `>=1.2.0 <1.4.0`. Version 1.4.0
  pulls in `package_info_plus` 9, whose Android side requires a Kotlin 2.x
  toolchain that this project's Gradle 8.3 / AGP 8.2.1 / Kotlin 1.8.22 setup
  does not provide. Raising the pin means upgrading `android/settings.gradle`
  and the Gradle wrapper together.
- Android needs `android.permission.INTERNET`, declared in
  [`android/app/src/main/AndroidManifest.xml`](android/app/src/main/AndroidManifest.xml).
