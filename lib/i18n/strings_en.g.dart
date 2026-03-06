///
/// Generated file. Do not edit.
///
// coverage:ignore-file
// ignore_for_file: type=lint, unused_import
// dart format off

part of 'strings.g.dart';

// Path: <root>
typedef TranslationsEn = Translations; // ignore: unused_element
class Translations with BaseTranslations<AppLocale, Translations> {
	/// Returns the current translations of the given [context].
	///
	/// Usage:
	/// final t = Translations.of(context);
	static Translations of(BuildContext context) => InheritedLocaleData.of<AppLocale, Translations>(context).translations;

	/// You can call this constructor and build your own translation instance of this locale.
	/// Constructing via the enum [AppLocale.build] is preferred.
	Translations({Map<String, Node>? overrides, PluralResolver? cardinalResolver, PluralResolver? ordinalResolver, TranslationMetadata<AppLocale, Translations>? meta})
		: assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
		  $meta = meta ?? TranslationMetadata(
		    locale: AppLocale.en,
		    overrides: overrides ?? {},
		    cardinalResolver: cardinalResolver,
		    ordinalResolver: ordinalResolver,
		  ) {
		$meta.setFlatMapFunction(_flatMapFunction);
	}

	/// Metadata for the translations of <en>.
	@override final TranslationMetadata<AppLocale, Translations> $meta;

	/// Access flat map
	dynamic operator[](String key) => $meta.getTranslation(key);

	late final Translations _root = this; // ignore: unused_field

	Translations $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) => Translations(meta: meta ?? this.$meta);

	// Translations
	late final TranslationsLoginEn login = TranslationsLoginEn._(_root);
	late final TranslationsHomeEn home = TranslationsHomeEn._(_root);
	late final TranslationsCommonEn common = TranslationsCommonEn._(_root);
}

// Path: login
class TranslationsLoginEn {
	TranslationsLoginEn._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Welcome Back'
	String get welcome => 'Welcome Back';

	/// en: 'Sign in to continue'
	String get subtitle => 'Sign in to continue';

	/// en: 'Username'
	String get username => 'Username';

	/// en: 'Password'
	String get password => 'Password';

	/// en: 'Sign In'
	String get signIn => 'Sign In';

	/// en: 'Forgot Password?'
	String get forgotPassword => 'Forgot Password?';

	/// en: 'Login via OTP'
	String get loginOtp => 'Login via OTP';

	/// en: 'Create Account'
	String get createAccount => 'Create Account';

	/// en: 'Don't have an account? '
	String get noAccountLabel => 'Don\'t have an account? ';

	/// en: 'Email or Phone is required'
	String get emailOrPhoneRequired => 'Email or Phone is required';

	/// en: 'Password is required'
	String get passwordRequired => 'Password is required';
}

// Path: home
class TranslationsHomeEn {
	TranslationsHomeEn._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Home'
	String get title => 'Home';

	/// en: 'Settings'
	String get settings => 'Settings';

	/// en: 'Logout'
	String get logout => 'Logout';
}

// Path: common
class TranslationsCommonEn {
	TranslationsCommonEn._(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Error'
	String get error => 'Error';

	/// en: 'Success'
	String get success => 'Success';

	/// en: 'Close'
	String get close => 'Close';

	/// en: 'OK'
	String get ok => 'OK';

	/// en: 'Yes'
	String get yes => 'Yes';

	/// en: 'No'
	String get no => 'No';
}

/// The flat map containing all translations for locale <en>.
/// Only for edge cases! For simple maps, use the map function of this library.
///
/// The Dart AOT compiler has issues with very large switch statements,
/// so the map is split into smaller functions (512 entries each).
extension on Translations {
	dynamic _flatMapFunction(String path) {
		return switch (path) {
			'login.welcome' => 'Welcome Back',
			'login.subtitle' => 'Sign in to continue',
			'login.username' => 'Username',
			'login.password' => 'Password',
			'login.signIn' => 'Sign In',
			'login.forgotPassword' => 'Forgot Password?',
			'login.loginOtp' => 'Login via OTP',
			'login.createAccount' => 'Create Account',
			'login.noAccountLabel' => 'Don\'t have an account? ',
			'login.emailOrPhoneRequired' => 'Email or Phone is required',
			'login.passwordRequired' => 'Password is required',
			'home.title' => 'Home',
			'home.settings' => 'Settings',
			'home.logout' => 'Logout',
			'common.error' => 'Error',
			'common.success' => 'Success',
			'common.close' => 'Close',
			'common.ok' => 'OK',
			'common.yes' => 'Yes',
			'common.no' => 'No',
			_ => null,
		};
	}
}
