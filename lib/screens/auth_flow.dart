import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../services/auth_api.dart';
import '../services/google_auth.dart';
import '../services/session_controller.dart';
import '../services/session_store.dart';
import '../theme/app_theme.dart';
import '../widgets/gauge_loading.dart';
import '../widgets/google_sign_in_button.dart';
import '../widgets/responsive_layout.dart';
import '../widgets/xp_logo.dart';
import 'retailer_registration_screen.dart';
import 'station_auth_screen.dart';

/// Signature for building the signed-in home.
typedef HomeBuilder = Widget Function(VoidCallback onLogout, UserProfile user);

/// Startup router.
///
/// * Stored session present  -> home immediately (no network needed).
/// * No session, first run   -> landing -> logo greeting -> gauge loading -> login.
/// * After logout / expiry   -> straight to login.
///
/// Once signed in, the session is checked with the backend in the background
/// (after the first frame and when the app returns to the foreground).
class AuthBootstrapFlow extends StatefulWidget {
  final SessionController session;
  final HomeBuilder homeBuilder;

  /// Minimum time between foreground re-validations.
  final Duration revalidateEvery;

  /// Auth API used by the login page (injectable for tests).
  final AuthApi? api;
  const AuthBootstrapFlow({
    super.key,
    required this.session,
    required this.homeBuilder,
    this.revalidateEvery = const Duration(minutes: 5),
    this.api,
  });

  @override
  State<AuthBootstrapFlow> createState() => _AuthBootstrapFlowState();
}

enum _BootStep { landing, logo, loading, login }

class _AuthBootstrapFlowState extends State<AuthBootstrapFlow> with WidgetsBindingObserver {
  _BootStep _step = _BootStep.landing;
  bool _wasSignedIn = false;
  DateTime? _lastValidation;

  SessionController get _session => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.addListener(_onSessionChanged);
    _wasSignedIn = _session.isSignedIn;
    if (!_wasSignedIn && _session.signOutReason != SignOutReason.none) _step = _BootStep.login;
    if (_wasSignedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _validate(force: true));
    }
  }

  @override
  void didUpdateWidget(covariant AuthBootstrapFlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _validate();
  }

  void _validate({bool force = false}) {
    if (!_session.isSignedIn) return;
    final now = DateTime.now();
    if (!force && _lastValidation != null && now.difference(_lastValidation!) < widget.revalidateEvery) return;
    _lastValidation = now;
    // Fire-and-forget: never blocks the UI, never logs out on network errors.
    unawaited(_session.validateInBackground());
  }

  void _onSessionChanged() {
    if (!mounted) return;
    final signedIn = _session.isSignedIn;
    setState(() {
      if (_wasSignedIn && !signedIn) _step = _BootStep.login;
      _wasSignedIn = signedIn;
    });
  }

  Future<void> _runLogoThenLoading() async {
    setState(() => _step = _BootStep.logo);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (!mounted) return;
    setState(() => _step = _BootStep.loading);
    await Future<void>.delayed(const Duration(milliseconds: 1700));
    if (!mounted) return;
    setState(() => _step = _BootStep.login);
  }

  Future<void> _onLoggedIn(AuthResult result, String method, String fallbackId) async {
    await _session.signIn(result, method: method, fallbackId: fallbackId);
    _lastValidation = DateTime.now();
  }

  Future<void> _logout() async {
    await _session.logout();
    await GoogleAuth.signOut();
  }

  void _openStationPortal({bool isSignUp = true}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GasStationAuthScreen(
          api: widget.api,
          onSuccess: _onLoggedIn,
          initialIsSignUp: isSignUp,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_session.isSignedIn) {
      return widget.homeBuilder(_logout, _session.user ?? const UserProfile());
    }
    switch (_step) {
      case _BootStep.landing:
        return _LandingPage(
          onContinue: _runLogoThenLoading,
          onOpenStationPortal: () => _openStationPortal(isSignUp: true),
        );
      case _BootStep.logo:
        return const _LogoGreetingPage();
      case _BootStep.loading:
        return const _BootLoadingPage();
      case _BootStep.login:
        return LoginPage(
          api: widget.api,
          onSuccess: _onLoggedIn,
          notice: _session.signOutReason == SignOutReason.expired
              ? 'Your session has ended. Please log in again.'
              : null,
        );
    }
  }
}

class _LandingPage extends StatelessWidget {
  final VoidCallback onContinue;
  final VoidCallback? onOpenStationPortal;
  const _LandingPage({required this.onContinue, this.onOpenStationPortal});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (XpLayout.isDesktop(context)) {
      return XpDesktopSplitAuthShell(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Container(
            padding: const EdgeInsets.all(36),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF141E33) : Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: XpLogo(width: 130)),
                const SizedBox(height: 22),
                Text(
                  'Welcome to XP GasTech',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sign in or create an account to monitor your gas cylinder or locate verified refill plants.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 28),
                ElevatedButton(
                  onPressed: onContinue,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.corporateBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text('Continue',
                      style:
                          TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                if (onOpenStationPortal != null) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    key: const Key('landing-gas-station-portal-button'),
                    onPressed: onOpenStationPortal,
                    icon: const Icon(Icons.local_gas_station_rounded, size: 20),
                    label: const Text(
                      'Own a Gas Plant / Refill Station? Sign Up Here',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.statusOK,
                      side: BorderSide(
                          color: AppTheme.statusOK.withValues(alpha: 0.45)),
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [Color(0xFF0B1220), Color(0xFF12233F), Color(0xFF0D47A1)]
                : const [AppTheme.corporateBlue, Color(0xFF1565C0), AppTheme.skyBlue],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                child: Column(
                  children: [
                    const Spacer(flex: 2),
                    const XpLogo(width: 160),
                    const SizedBox(height: 28),
                    const Text('XP TECHNOLOGY',
                        style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
                    const SizedBox(height: 8),
                    Text('SMART GAS MONITORING',
                        style: TextStyle(color: AppTheme.lightBlue.withValues(alpha: 0.95), fontSize: 12, letterSpacing: 2.4, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 28),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Live readings · Nearby refill · Usage history',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, height: 1.4)),
                        ],
                      ),
                    ),
                    const Spacer(flex: 3),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: onContinue,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: AppTheme.corporateBlue,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: const Text('Continue', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      ),
                    ),
                    if (onOpenStationPortal != null) ...[
                      const SizedBox(height: 12),
                      TextButton.icon(
                        key: const Key('landing-gas-station-portal-button'),
                        onPressed: onOpenStationPortal,
                        icon: const Icon(Icons.local_gas_station_rounded, color: Colors.white, size: 20),
                        label: const Text(
                          'Own a Gas Plant / Refill Station? Sign Up Here',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LogoGreetingPage extends StatelessWidget {
  const _LogoGreetingPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: AppTheme.corporateBlue,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: AppTheme.corporateBlue.withValues(alpha: 0.35), blurRadius: 28, offset: const Offset(0, 12)),
                ],
              ),
              child: const Icon(Icons.local_gas_station_rounded, size: 64, color: Colors.white),
            ),
            const SizedBox(height: 24),
            Text('Welcome to XP Tech', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('Digital Gas Meter', style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}

class _BootLoadingPage extends StatelessWidget {
  const _BootLoadingPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: GaugeLoadingIndicator(
          size: 180,
          label: 'Calibrating meter…',
          accentColor: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// Called after a successful login: (result, method 'email'|'phone'|'google', fallback identifier).
typedef LoginSuccess = Future<void> Function(AuthResult result, String method, String fallbackId);

class LoginPage extends StatefulWidget {
  final LoginSuccess onSuccess;

  /// Optional banner, e.g. after the session expired.
  final String? notice;
  final AuthApi? api;
  const LoginPage({super.key, required this.onSuccess, this.notice, this.api});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

enum _AuthTab { login, signup }
enum _SignupMethod { chooser, email, phone }

class _LoginPageState extends State<LoginPage> {
  late final AuthApi _api = widget.api ?? AuthApi();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _username = TextEditingController();
  final _phone = TextEditingController();
  final _smsCode = TextEditingController();
  _AuthTab _tab = _AuthTab.login;
  _SignupMethod _signupMethod = _SignupMethod.chooser;
  bool _busy = false;
  bool _codeSent = false;
  String? _error;
  String? _info;

  /// Email that still needs verification (after sign-up or a 403 on login).
  String? _verifyEmail;

  /// True right after sign-up: show the "check your inbox" panel instead of the form.
  bool _signupDone = false;
  DateTime? _lastResend;

  /// Set from the "Register a gas plant" signup card: land on the station
  /// portal right after the account is ready. Survives tab switches so the
  /// email-verify-then-log-in path keeps it too.
  bool _businessIntent = false;

  /// After phone/Google login, offer an optional username if the account has none.
  bool _pickUsername = false;
  AuthResult? _pendingResult;
  String? _pendingMethod;
  String? _pendingFallback;

  static final _usernameRe = RegExp(r'^[a-zA-Z0-9._]{3,20}$');

  late final Future<void> _googleReady;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _googleSub;

  @override
  void initState() {
    super.initState();
    _googleReady = GoogleAuth.ensureInitialized();
    _googleReady.then((_) {
      if (!mounted) return;
      _googleSub = GoogleAuth.events.listen(_onGoogleEvent, onError: (Object e) {
        if (mounted) setState(() => _error = GoogleAuth.describeError(e));
      });
    }).catchError((Object e) {
      if (mounted) setState(() => _error = GoogleAuth.describeError(e));
    });
    _checkBackend();
  }

  /// Early warning if the API is down; retries so a restart of the backend clears the banner.
  Future<void> _checkBackend({bool force = false}) async {
    try {
      final health = await _api.health();
      if (!mounted) return;
      if (health.ok) {
        setState(() {
          if (_error != null && _error!.contains('Backend')) _error = null;
          _info = 'Connected to backend';
        });
        // Clear the success chip after a moment so it does not clutter the form.
        Future<void>.delayed(const Duration(seconds: 2), () {
          if (mounted && _info == 'Connected to backend') {
            setState(() => _info = null);
          }
        });
      }
    } on AuthApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      if (!force) {
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (mounted) _checkBackend(force: true);
        });
      }
    }
  }

  @override
  void dispose() {
    _googleSub?.cancel();
    _email.dispose();
    _password.dispose();
    _username.dispose();
    _phone.dispose();
    _smsCode.dispose();
    super.dispose();
  }

  void _switchTab(_AuthTab tab) {
    setState(() {
      _tab = tab;
      _signupMethod = _SignupMethod.chooser;
      _error = null;
      _info = null;
      _codeSent = false;
      _signupDone = false;
      _verifyEmail = null;
      _pickUsername = false;
      _pendingResult = null;
    });
  }

  /// Runs [action] with the busy overlay and maps any failure to [_error].
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await action();
    } on AuthApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _validEmailPassword(String email, String password) {
    if (!email.contains('@') || password.length < 8) {
      setState(() => _error = 'Enter a valid email and password (8+ characters).');
      return false;
    }
    return true;
  }

  bool _validUsername(String username, {required bool required}) {
    if (username.isEmpty) {
      if (!required) return true;
      setState(() => _error = 'Please choose a username (3–20 letters, numbers, _ or .).');
      return false;
    }
    if (!_usernameRe.hasMatch(username)) {
      setState(() => _error = 'Username must be 3–20 characters: letters, numbers, underscores or periods.');
      return false;
    }
    return true;
  }

  bool _validLogin(String identifier, String password) {
    if (password.length < 8) {
      setState(() => _error = 'Enter a password (8+ characters).');
      return false;
    }
    if (identifier.contains('@')) {
      if (identifier.length < 5 || !identifier.contains('.')) {
        setState(() => _error = 'Enter a valid email or username.');
        return false;
      }
      return true;
    }
    return _validUsername(identifier, required: true);
  }

  /// Completes sign-in, then routes business signups straight to the
  /// station portal so gas plants register without hunting through Settings.
  Future<void> _finishSignIn(AuthResult result, String method, String fallback) async {
    await widget.onSuccess(result, method, fallback);
    if (!_businessIntent || !mounted) return;
    _businessIntent = false;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RetailerRegistrationScreen()),
    );
  }

  Widget _businessIntentBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.statusOK.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.local_gas_station_rounded, color: AppTheme.statusOK),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Signing up as a gas plant / firm — your business registration is next.',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          InkWell(
            onTap: () => setState(() => _businessIntent = false),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close_rounded, size: 18, color: AppTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _completeLogin(AuthResult result, String method, String fallback) async {
    if (result.username != null && result.username!.trim().isNotEmpty) {
      await _finishSignIn(result, method, fallback);
      return;
    }
    if (!mounted) return;
    setState(() {
      _pickUsername = true;
      _pendingResult = result;
      _pendingMethod = method;
      _pendingFallback = fallback;
      _username.clear();
    });
  }

  Future<void> _submitChosenUsername({bool skip = false}) async {
    final pending = _pendingResult;
    final method = _pendingMethod;
    final fallback = _pendingFallback;
    if (pending == null || method == null) return;
    if (skip) {
      await _finishSignIn(pending, method, fallback ?? pending.displayId('XP Tech user'));
      return;
    }
    final username = _username.text.trim();
    if (!_validUsername(username, required: true)) return;
    await _run(() async {
      final profile = await _api.setUsername(accessToken: pending.token, username: username);
      final updated = AuthResult(
        token: pending.token,
        refreshToken: pending.refreshToken,
        userId: pending.userId ?? profile.id,
        email: profile.email ?? pending.email,
        phone: profile.phone ?? pending.phone,
        name: profile.name ?? pending.name,
        username: profile.username,
        raw: pending.raw,
      );
      await _finishSignIn(updated, method, fallback ?? updated.displayId('XP Tech user'));
    });
  }

  /// Opens the dedicated Gas Station & Refill Plant authentication page.
  void _openGasStationPortal({bool isSignUp = false}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GasStationAuthScreen(
          api: _api,
          onSuccess: widget.onSuccess,
          initialIsSignUp: isSignUp,
        ),
      ),
    );
  }

  /// Shortcut for gas station owners: opens the dedicated station portal page.
  void _startBusinessSignup({bool isSignUp = true}) {
    _openGasStationPortal(isSignUp: isSignUp);
  }

  Widget _stationPortalBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF132238) : const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF1B4332) : const Color(0xFF86EFAC),
          width: 1.2,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: const Key('gas-station-portal-banner'),
          borderRadius: BorderRadius.circular(16),
          onTap: _busy ? null : () => _openGasStationPortal(isSignUp: _tab == _AuthTab.signup),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppTheme.statusOK.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.local_gas_station_rounded, color: AppTheme.statusOK, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Gas Station & Plant Portal',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Sign in or register on our dedicated station page',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppTheme.statusOK),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submitLogin() async {
    final identifier = _email.text.trim();
    final password = _password.text;
    if (!_validLogin(identifier, password)) return;
    setState(() => _verifyEmail = identifier.contains('@') ? identifier : null);
    await _run(() async {
      try {
        final result = await _api.login(identifier: identifier, password: password);
        await _completeLogin(result, 'email', identifier);
      } on AuthApiException catch (e) {
        if (!e.isEmailNotVerified) rethrow;
        if (mounted) {
          setState(() {
            _verifyEmail = identifier.contains('@') ? identifier : null;
            _error = 'Please verify your email first. Check your inbox for the link, or resend it below.';
          });
        }
      }
    });
  }

  Future<void> _submitEmailSignup() async {
    final email = _email.text.trim();
    final password = _password.text;
    final phone = _phone.text.trim();
    final username = _username.text.trim();
    if (!_validEmailPassword(email, password)) return;
    if (!_validUsername(username, required: true)) return;
    await _run(() async {
      final result = await _api.signup(email: email, password: password, phone: phone, username: username);
      final session = result.session;
      if (session != null) {
        // Older backend without email verification: signed in directly.
        await _finishSignIn(session, 'email', email);
        return;
      }
      if (mounted) {
        setState(() {
          _verifyEmail = email;
          _signupDone = true;
          _password.clear();
          _info = result.message;
          _lastResend = result.emailSent ? DateTime.now() : null;
        });
      }
    });
  }

  static const _resendCooldown = Duration(seconds: 60);

  Future<void> _resendVerification() async {
    final email = _verifyEmail;
    if (email == null) return;
    final last = _lastResend;
    if (last != null && DateTime.now().difference(last) < _resendCooldown) {
      final wait = _resendCooldown - DateTime.now().difference(last);
      setState(() => _error = 'Please wait ${wait.inSeconds + 1}s before resending.');
      return;
    }
    await _run(() async {
      final message = await _api.resendVerification(email: email);
      if (mounted) {
        setState(() {
          _lastResend = DateTime.now();
          _info = message;
        });
      }
    });
  }

  void _backToLoginWithEmail() {
    final email = _verifyEmail;
    _switchTab(_AuthTab.login);
    if (email != null) _email.text = email;
    setState(() => _verifyEmail = email);
  }

  Future<void> _sendSmsCode() async {
    final phone = _phone.text.trim();
    if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(phone)) {
      setState(() => _error = 'Enter phone in E.164 format, e.g. +2348012345678');
      return;
    }
    await _run(() async {
      await _api.sendSmsCode(phone: phone);
      if (mounted) {
        setState(() {
          _codeSent = true;
          _info = 'Code sent to $phone. It expires in 10 minutes.';
        });
      }
    });
  }

  Future<void> _verifySmsCode() async {
    final phone = _phone.text.trim();
    final code = _smsCode.text.trim();
    if (code.length < 4) {
      setState(() => _error = 'Enter the code from the SMS.');
      return;
    }
    await _run(() async {
      final result = await _api.verifySmsCode(phone: phone, code: code);
      await _completeLogin(result, 'phone', phone);
    });
  }

  /// Web: fired after the user completes the Google-rendered button flow.
  void _onGoogleEvent(GoogleSignInAuthenticationEvent event) {
    if (event is GoogleSignInAuthenticationEventSignIn) {
      _exchangeGoogleAccount(event.user);
    }
  }

  Future<void> _exchangeGoogleAccount(GoogleSignInAccount account) async {
    await _run(() async {
      final String idToken;
      try {
        idToken = GoogleAuth.idTokenFrom(account);
      } catch (e) {
        throw AuthApiException(GoogleAuth.describeError(e));
      }
      final result = await _api.google(idToken: idToken);
      await _completeLogin(result, 'google', account.email);
    });
  }

  /// Non-web: our own "Sign up with Google" card opens the native flow.
  Future<void> _googleSignIn() async {
    await _run(() async {
      final String idToken;
      try {
        idToken = await GoogleAuth.signInForIdToken();
      } catch (e) {
        throw AuthApiException(GoogleAuth.describeError(e));
      }
      final result = await _api.google(idToken: idToken);
      await _completeLogin(result, 'google', result.email ?? 'Google user');
    });
  }

  Widget _messages(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_info != null) ...[
          const SizedBox(height: 12),
          Text(_info!, style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
        ],
      ],
    );
  }

  Widget _googleOption(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fallback = _signupOption(
      icon: Icons.g_mobiledata_rounded,
      title: 'Sign up with Google',
      subtitle: 'One tap with your Google account',
      accent: const Color(0xFF4285F4),
      onTap: _googleSignIn,
    );
    if (GoogleAuth.supportsCustomButton) return fallback;
    // Web: Google Identity Services renders the actual button inside our themed card.
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF182338) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isDark ? const Color(0xFF2A3A55) : const Color(0xFFDADCE0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Sign up with Google', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 2),
            Text('One tap with your Google account', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, c) => FutureBuilder<void>(
                future: _googleReady,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Text('Google sign-in unavailable', style: TextStyle(color: Theme.of(context).colorScheme.error));
                  }
                  if (snap.connectionState != ConnectionState.done) {
                    return const SizedBox(height: 44, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
                  }
                  return SizedBox(
                    height: 44,
                    child: buildGoogleSignUpButton(isDark: isDark, width: c.maxWidth, fallback: fallback),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeToggle(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F1726) : const Color(0xFFE8EEF8),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(child: _toggleChip(context, 'Login', _tab == _AuthTab.login, () => _switchTab(_AuthTab.login))),
          Expanded(child: _toggleChip(context, 'Sign up', _tab == _AuthTab.signup, () => _switchTab(_AuthTab.signup))),
        ],
      ),
    );
  }

  Widget _toggleChip(BuildContext context, String label, bool selected, VoidCallback onTap) {
    return Material(
      color: selected ? AppTheme.corporateBlue : Colors.transparent,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: selected ? Colors.white : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _signupOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? accent,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: isDark ? const Color(0xFF182338) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: _busy ? null : onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? const Color(0xFF2A3A55) : const Color(0xFFDADCE0)),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: (accent ?? AppTheme.corporateBlue).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: accent ?? AppTheme.corporateBlue),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _loginFields(BuildContext context) => [
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.username, AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email or username', prefixIcon: Icon(Icons.person_outline_rounded)),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _password,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline_rounded)),
          onSubmitted: (_) => _submitLogin(),
        ),
        _messages(context),
        if (_verifyEmail != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('resend-verification'),
              onPressed: _busy ? null : _resendVerification,
              icon: const Icon(Icons.mark_email_unread_outlined),
              label: const Text('Resend verification email'),
            ),
          ),
        ],
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busy ? null : _submitLogin,
            child: const Text('Log in'),
          ),
        ),
      ];

  List<Widget> _signupChooser(BuildContext context) => [
        Text('Create your XP Tech account', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 18),
        _signupOption(
          icon: Icons.phone_iphone_rounded,
          title: 'Sign up with phone number',
          subtitle: 'Verify with an SMS code',
          onTap: () => setState(() {
            _signupMethod = _SignupMethod.phone;
            _error = null;
          }),
        ),
        _signupOption(
          icon: Icons.mail_outline_rounded,
          title: 'Sign up with email',
          subtitle: 'Use email and a secure password',
          onTap: () => setState(() {
            _signupMethod = _SignupMethod.email;
            _signupDone = false;
            _error = null;
          }),
        ),
        _googleOption(context),
        _signupOption(
          icon: Icons.local_gas_station_rounded,
          title: 'Register a gas plant or firm',
          subtitle: 'Sign in or register on our dedicated gas station page',
          accent: AppTheme.statusOK,
          onTap: () => _openGasStationPortal(isSignUp: true),
        ),
        _messages(context),
      ];

  List<Widget> _verifyEmailPanel(BuildContext context) => [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppTheme.corporateBlue.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              const Icon(Icons.mark_email_read_outlined, size: 44, color: AppTheme.corporateBlue),
              const SizedBox(height: 10),
              Text('Verify your email', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(
                'We sent a verification link to ${_verifyEmail ?? 'your email'}. Open it, then come back and log in.',
                textAlign: TextAlign.center,
              ),
              if (_businessIntent)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'After logging in, you will go straight to gas plant registration.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ),
        _messages(context),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const Key('resend-verification'),
            onPressed: _busy ? null : _resendVerification,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Resend verification email'),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busy ? null : _backToLoginWithEmail,
            child: const Text('I verified it — log in'),
          ),
        ),
      ];

  List<Widget> _signupEmailForm(BuildContext context) => [
        if (_businessIntent) _businessIntentBanner(),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() {
              _signupMethod = _SignupMethod.chooser;
              _error = null;
            }),
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('All sign-up options'),
          ),
        ),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline_rounded)),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _username,
          keyboardType: TextInputType.text,
          autofillHints: const [AutofillHints.username],
          decoration: const InputDecoration(
            labelText: 'Username',
            helperText: '3–20 characters: letters, numbers, _ or .',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline_rounded)),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Phone (optional)', hintText: '+234...', prefixIcon: Icon(Icons.phone_outlined)),
        ),
        _messages(context),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busy ? null : _submitEmailSignup,
            child: const Text('Create account'),
          ),
        ),
      ];

  List<Widget> _signupPhoneForm(BuildContext context) => [
        if (_businessIntent) _businessIntentBanner(),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() {
              _signupMethod = _SignupMethod.chooser;
              _error = null;
              _codeSent = false;
            }),
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('All sign-up options'),
          ),
        ),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Phone number', hintText: '+2348012345678', prefixIcon: Icon(Icons.phone_outlined)),
        ),
        if (_codeSent) ...[
          const SizedBox(height: 14),
          TextField(
            controller: _smsCode,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'SMS code', prefixIcon: Icon(Icons.sms_outlined)),
          ),
        ],
        _messages(context),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busy ? null : (_codeSent ? _verifySmsCode : _sendSmsCode),
            child: Text(_codeSent ? 'Verify & continue' : 'Send SMS code'),
          ),
        ),
      ];


  List<Widget> _pickUsernamePanel(BuildContext context) => [
        const Icon(Icons.alternate_email_rounded, size: 44, color: AppTheme.corporateBlue),
        const SizedBox(height: 12),
        Text('Choose a username', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          'You can use this to log in, and it will show on your dashboard. You can skip and set one later.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _username,
          keyboardType: TextInputType.text,
          autofillHints: const [AutofillHints.username],
          decoration: const InputDecoration(
            labelText: 'Username',
            helperText: '3–20 characters: letters, numbers, _ or .',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
        ),
        _messages(context),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busy ? null : () => _submitChosenUsername(),
            child: const Text('Save username'),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _busy ? null : () => _submitChosenUsername(skip: true),
            child: const Text('Skip for now'),
          ),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final title = _pickUsername
        ? 'Almost done'
        : (_tab == _AuthTab.login ? 'Welcome back' : 'Join XP Tech');
    final subtitle = _pickUsername
        ? 'Pick a username for your account'
        : (_tab == _AuthTab.login
            ? 'Log in with your email or username'
            : 'Choose how you want to create your account');

    late final List<Widget> body;
    if (_pickUsername) {
      body = _pickUsernamePanel(context);
    } else if (_tab == _AuthTab.login) {
      body = _loginFields(context);
    } else if (_signupMethod == _SignupMethod.chooser) {
      body = _signupChooser(context);
    } else if (_signupMethod == _SignupMethod.email) {
      body = _signupDone ? _verifyEmailPanel(context) : _signupEmailForm(context);
    } else {
      body = _signupPhoneForm(context);
    }

    return XpDesktopSplitAuthShell(
      child: Scaffold(
        body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                  children: [
                    Align(
                      alignment: Alignment.center,
                      child: XpLogo(
                        width: 120,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        shadow: Theme.of(context).brightness == Brightness.dark,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text(subtitle, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                    if (widget.notice != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          widget.notice!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                    if (!_pickUsername) ...[
                      const SizedBox(height: 18),
                      _stationPortalBanner(context),
                      _modeToggle(context),
                      const SizedBox(height: 10),
                      Center(
                        child: TextButton.icon(
                          onPressed: _busy ? null : () => _startBusinessSignup(isSignUp: false),
                          icon: const Icon(Icons.local_gas_station_rounded,
                              size: 18, color: AppTheme.statusOK),
                          label: const Text(
                            'Own a gas plant? List your business',
                            style: TextStyle(
                                color: AppTheme.statusOK, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    ...body,
                  ],
                ),
              ),
            ),
          ),
          if (_busy)
            ColoredBox(
              color: Colors.black.withValues(alpha: 0.35),
              child: Center(
                child: GaugeLoadingIndicator(
                  size: 150,
                  label: _tab == _AuthTab.login ? 'Signing you in…' : 'Setting up your account…',
                ),
              ),
            ),
        ],
      ),
    ),
    );
  }
}
