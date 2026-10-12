import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/auth_api.dart';
import '../services/google_auth.dart';
import '../theme/app_theme.dart';
import '../widgets/gauge_loading.dart';
import '../widgets/google_sign_in_button.dart';

const _tokenKey = 'xp_auth_access_token';
const _emailKey = 'xp_auth_email';

/// Landing → logo greeting → gauge loading → login.
class AuthBootstrapFlow extends StatefulWidget {
  final Widget Function(VoidCallback onLogout) homeBuilder;
  const AuthBootstrapFlow({super.key, required this.homeBuilder});

  @override
  State<AuthBootstrapFlow> createState() => _AuthBootstrapFlowState();
}

enum _BootStep { landing, logo, loading, login, home }

class _AuthBootstrapFlowState extends State<AuthBootstrapFlow> {
  _BootStep _step = _BootStep.landing;
  String? _token;
  String? _email;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    final email = prefs.getString(_emailKey);
    if (!mounted) return;
    if (token != null && token.isNotEmpty) {
      setState(() {
        _token = token;
        _email = email;
        _step = _BootStep.home;
      });
    }
  }

  Future<void> _persistSession(String token, String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    await prefs.setString(_emailKey, email);
  }

  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_emailKey);
  }

  void _goLandingNext() => setState(() => _step = _BootStep.logo);

  Future<void> _runLogoThenLoading() async {
    setState(() => _step = _BootStep.logo);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (!mounted) return;
    setState(() => _step = _BootStep.loading);
    await Future<void>.delayed(const Duration(milliseconds: 1700));
    if (!mounted) return;
    setState(() => _step = _BootStep.login);
  }

  Future<void> _onLoggedIn(String token, String email) async {
    await _persistSession(token, email);
    if (!mounted) return;
    setState(() {
      _token = token;
      _email = email;
      _step = _BootStep.home;
    });
  }

  Future<void> _logout() async {
    await _clearSession();
    await GoogleAuth.signOut();
    if (!mounted) return;
    setState(() {
      _token = null;
      _email = null;
      _step = _BootStep.landing;
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case _BootStep.landing:
        return _LandingPage(onContinue: _runLogoThenLoading);
      case _BootStep.logo:
        return const _LogoGreetingPage();
      case _BootStep.loading:
        return const _BootLoadingPage();
      case _BootStep.login:
        return LoginPage(onSuccess: _onLoggedIn);
      case _BootStep.home:
        return widget.homeBuilder(_logout);
    }
  }
}

class _LandingPage extends StatelessWidget {
  final VoidCallback onContinue;
  const _LandingPage({required this.onContinue});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                      child: const Icon(Icons.local_gas_station_rounded, size: 56, color: AppTheme.corporateBlue),
                    ),
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

class LoginPage extends StatefulWidget {
  final Future<void> Function(String token, String email) onSuccess;
  const LoginPage({super.key, required this.onSuccess});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

enum _AuthTab { login, signup }
enum _SignupMethod { chooser, email, phone }

class _LoginPageState extends State<LoginPage> {
  final _api = AuthApi();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _smsCode = TextEditingController();
  _AuthTab _tab = _AuthTab.login;
  _SignupMethod _signupMethod = _SignupMethod.chooser;
  bool _busy = false;
  bool _codeSent = false;
  String? _error;
  String? _info;

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

  /// Early, non-blocking warning if the API is down so users aren't surprised later.
  Future<void> _checkBackend() async {
    try {
      await _api.health();
    } on AuthApiException catch (e) {
      if (mounted && _error == null) setState(() => _error = e.message);
    }
  }

  @override
  void dispose() {
    _googleSub?.cancel();
    _email.dispose();
    _password.dispose();
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

  Future<void> _submitLogin() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (!_validEmailPassword(email, password)) return;
    await _run(() async {
      final result = await _api.login(email: email, password: password);
      await widget.onSuccess(result.token, result.displayId(email));
    });
  }

  Future<void> _submitEmailSignup() async {
    final email = _email.text.trim();
    final password = _password.text;
    final phone = _phone.text.trim();
    if (!_validEmailPassword(email, password)) return;
    await _run(() async {
      final result = await _api.signup(email: email, password: password, phone: phone);
      await widget.onSuccess(result.token, result.displayId(email));
    });
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
      await widget.onSuccess(result.token, result.displayId(phone));
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
      await widget.onSuccess(result.token, result.displayId(account.email));
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
      await widget.onSuccess(result.token, result.email ?? 'Google user');
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
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline_rounded)),
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
            _error = null;
          }),
        ),
        _googleOption(context),
        _messages(context),
      ];

  List<Widget> _signupEmailForm(BuildContext context) => [
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

  @override
  Widget build(BuildContext context) {
    final title = _tab == _AuthTab.login ? 'Welcome back' : 'Join XP Tech';
    final subtitle = _tab == _AuthTab.login
        ? 'Log in to your Digital Gas Meter'
        : 'Choose how you want to create your account';

    late final List<Widget> body;
    if (_tab == _AuthTab.login) {
      body = _loginFields(context);
    } else if (_signupMethod == _SignupMethod.chooser) {
      body = _signupChooser(context);
    } else if (_signupMethod == _SignupMethod.email) {
      body = _signupEmailForm(context);
    } else {
      body = _signupPhoneForm(context);
    }

    return Scaffold(
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
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppTheme.corporateBlue.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.local_gas_station_rounded, size: 40, color: AppTheme.corporateBlue),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text(subtitle, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 22),
                    _modeToggle(context),
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
    );
  }
}
