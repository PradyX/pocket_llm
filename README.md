# Flutter Base App

A production-grade Flutter starter template with a scalable, feature-first architecture. Clone this repo and start building immediately — theming, routing, networking, auth flows, logging, i18n, and essential utilities are all pre-configured.

---

## Features

- **Riverpod** state management with code generation (`riverpod_annotation`)
- **GoRouter** for declarative, type-safe navigation
- **Material 3** theming with dynamic Light/Dark mode switching
- **Dio** HTTP client with pretty logging & token refresh interceptor skeleton
- **Firebase** Core + Crashlytics integration
- **Secure Storage** for persisting tokens and preferences
- **Edge-to-Edge** display support for Android 15+
- **Internationalization** via `slang` (strongly-typed, no build_runner needed)
- **Structured Logging** via `talker_flutter` → console in debug, Crashlytics in release
- **Environment Variables** via `flutter_dotenv`
- **Splash Screen & App Icon** automation via `flutter_native_splash` & `flutter_launcher_icons`
- **Utility Extensions** for Snackbars, Dialogs, Pickers, Clipboard, Validation, Masking, Debouncing, etc.

---

## Project Structure

```
lib/
├── main.dart                          # App entry point
├── app.dart                           # MaterialApp.router with theming
├── firebase_initializer.dart          # Firebase setup
├── core/
│   ├── error/
│   │   └── app_exception.dart         # Custom exception classes
│   ├── navigation/
│   │   └── app_router.dart            # GoRouter + route constants
│   ├── network/
│   │   ├── api_client.dart            # API client abstraction
│   │   ├── api_result.dart            # Result wrapper
│   │   └── dio_provider.dart          # Dio setup, logger, auth interceptor
│   ├── state/
│   │   └── base_state.dart            # Sealed AsyncState<T> pattern
│   ├── theme/
│   │   ├── theme.dart                 # Material 3 theme (replaceable via Theme Builder)
│   │   └── theme_provider.dart        # ThemeMode notifier + persistence
│   └── utils/
│       ├── app_utils.dart             # Extensions & utilities
│       └── logger.dart                # AppLogger (Talker + Crashlytics)
├── features/
│   ├── home/
│   │   └── presentation/
│   │       ├── home_page.dart         # Drawer + BottomNav + AppBar
│   │       ├── home_controller.dart
│   │       └── settings_page.dart     # Theme switching UI
│   ├── login/
│   │   ├── data/                      # API + Repository implementation
│   │   ├── domain/                    # Repository interface + models
│   │   └── presentation/
│   │       ├── login_page.dart
│   │       ├── login_controller.dart
│   │       ├── forgot_password_page.dart
│   │       └── otp_login_page.dart
│   └── sign_up/
│       ├── data/
│       ├── domain/
│       └── presentation/
├── i18n/
│   ├── en.i18n.yaml                   # English strings
│   ├── strings.g.dart                 # Generated translations
│   └── strings_en.g.dart
├── shared/
│   └── providers.dart                 # Shared Riverpod providers
└── storage/
    └── secure_storage.dart            # SecureStorage wrapper
```

---

## Getting Started

### Prerequisites

- Flutter SDK `^3.10.8`
- Firebase CLI (`flutterfire configure`)

### Setup

```bash
# 1. Clone the repo
git clone https://github.com/PradyX/flutter_base_app.git
cd flutter_base_app

# 2. Install dependencies
flutter pub get

# 3. Create your .env file (copy from example)
cp .env.example .env

# 4. Configure Firebase
flutterfire configure

# 5. Run code generation (Riverpod + Freezed)
dart run build_runner build --delete-conflicting-outputs

# 6. Run the app
flutter run
```

---

## Guides

### 🎨 Theming (Material Theme Builder)

This app is fully compatible with Google's [Material Theme Builder](https://material-foundation.github.io/material-theme-builder/).

**To update your theme:**
1. Go to the Theme Builder and customize your palette
2. Export as **Flutter (Dart)**
3. Replace the contents of `lib/core/theme/theme.dart` with the exported file
4. Done! The app will pick up the new theme automatically

**Theme switching** (System / Light / Dark) is available in the Navigation Drawer → Settings.

---

### 🌐 Internationalization (i18n)

This app uses [slang](https://pub.dev/packages/slang) for strongly-typed translations.

**Adding a new language (e.g., Hindi):**

1. Create `lib/i18n/hi.i18n.yaml`:
```yaml
login:
  welcome: "वापसी पर स्वागत है"
  subtitle: "जारी रखने के लिए साइन इन करें"
  signIn: "साइन इन"
  # ... add all keys from en.i18n.yaml
```

2. Regenerate:
```bash
dart run slang
```

3. Use in code:
```dart
import 'package:flutter_base_app/i18n/strings.g.dart';

Text(t.login.welcome)  // Strongly typed!
```

---

### 🖼️ App Icon & Splash Screen

Configurations are scaffolded in `pubspec.yaml` — just uncomment and set your images.

**App Icon:**
1. Place your icon at `assets/icon.png` (1024x1024 recommended)
2. Uncomment `image_path` in the `flutter_launcher_icons` section of `pubspec.yaml`
3. Run:
```bash
dart run flutter_launcher_icons
```

**Splash Screen:**
1. Place your splash logo at `assets/splash.png`
2. Uncomment `image` lines in the `flutter_native_splash` section of `pubspec.yaml`
3. Run:
```bash
dart run flutter_native_splash:create
```

---

### 🔐 Environment Variables

Environment variables are managed via `flutter_dotenv`.

- `.env` — Your local environment (git-ignored)
- `.env.example` — Committed template for team members

**Available variables:**
| Variable | Description | Default |
|---|---|---|
| `API_BASE_URL` | Backend API base URL | `https://dummyjson.com/auth` |

**Accessing in code:**
```dart
import 'package:flutter_dotenv/flutter_dotenv.dart';

final baseUrl = dotenv.env['API_BASE_URL'];
```

---

### 🌐 Network Layer (Dio)

The Dio HTTP client (`lib/core/network/dio_provider.dart`) comes pre-configured with:

- **Pretty Dio Logger** — formatted request/response logs in the console
- **Auth Interceptor Skeleton** — `TODO` placeholders for:
  - Injecting Bearer tokens from Secure Storage
  - Handling 401 responses with token refresh logic

---

### 📊 Logging & Crash Reporting

`lib/core/utils/logger.dart` provides `AppLogger`:

```dart
AppLogger.info('User logged in');
AppLogger.debug('Fetching data...');
AppLogger.warning('Rate limit approaching');
AppLogger.error('API failed', exception, stackTrace);
AppLogger.fatal('Critical failure', error, stackTrace);
```

| Mode | Behavior |
|---|---|
| **Debug** | Beautiful console logs via Talker |
| **Release** | Errors routed to Firebase Crashlytics |

Uncaught Flutter and async errors are automatically captured via `AppLogger.initCrashlytics()` in `main.dart`.

---

### 🛠️ Utility Extensions (`app_utils.dart`)

All utilities are in `lib/core/utils/app_utils.dart`:

| Category | Usage |
|---|---|
| **Snackbars** | `context.showShortSnackBar('Saved!')` |
| **Alert Dialogs** | `context.showAlertDialog(message: '...', onPositiveClick: () {})` |
| **API Dialogs** | `context.showApiAlertDialog(isError: true, ...)` |
| **Date Picker** | `DateTime? d = await context.openDateChooser()` |
| **Time Picker** | `TimeOfDay? t = await context.openTimePicker()` |
| **Clipboard** | `await context.copyToClipboard('text')` |
| **Keyboard** | `context.hideKeyboard()` |
| **String Validation** | `if (value.isValid) { ... }` |
| **Mobile Validation** | `if (phone.isValidMobile) { ... }` |
| **String Masking** | `'password'.mask()` → `pass****` |
| **Color Hex** | `'#FF0000'.toColor()` / `Colors.red.toHexString()` |
| **Date Formatting** | `DateUtilsExt.formatDateTime(...)` |
| **Debouncer** | `Debouncer(milliseconds: 500).run(() => ...)` |
| **Screen Size** | `context.screenWidth` / `context.screenHeight` |
| **Theme Check** | `context.isDarkMode` |

**Constants** (e.g., mobile number length) are centralized in `AppConstants` for easy modification across the entire app.

---

### 🏗️ Code Generation

This project uses code generation for Riverpod providers and Freezed models.

**Run after modifying annotated files:**
```bash
dart run build_runner build --delete-conflicting-outputs
```

**Watch mode (auto-regenerate on save):**
```bash
dart run build_runner watch --delete-conflicting-outputs
```

---

### 📱 Auth Flows

Pre-built authentication screens:

| Route | Page | Description |
|---|---|---|
| `/login` | `LoginPage` | Username/Password login |
| `/login-otp` | `OtpLoginPage` | Mobile OTP-based login |
| `/forgot-password` | `ForgotPasswordPage` | Password reset via OTP |
| `/signup` | `SignUpPage` | New account registration |
| `/home` | `HomePage` | Main app with Drawer + BottomNav |
| `/settings` | `SettingsPage` | Theme switching |

---

## Dependencies

### Runtime
| Package | Purpose |
|---|---|
| `flutter_riverpod` | State management |
| `riverpod_annotation` | Provider code generation |
| `dio` | HTTP client |
| `go_router` | Declarative routing |
| `flutter_secure_storage` | Encrypted key-value storage |
| `freezed_annotation` | Immutable data classes |
| `json_annotation` | JSON serialization |
| `firebase_core` | Firebase SDK |
| `firebase_crashlytics` | Crash reporting |
| `intl` | Date/Number formatting |
| `flutter_dotenv` | Environment variables |
| `pretty_dio_logger` | Network request logging |
| `slang` / `slang_flutter` | i18n translations |
| `talker_flutter` | Structured logging |

### Dev
| Package | Purpose |
|---|---|
| `build_runner` | Code generation runner |
| `riverpod_generator` | Riverpod provider generation |
| `freezed` | Immutable class generation |
| `json_serializable` | JSON code generation |
| `flutter_launcher_icons` | App icon automation |
| `flutter_native_splash` | Splash screen automation |

---

## License

This project is open source. Feel free to use it as a template for your own projects.
