import 'dart:async';

import 'package:flutter/material.dart';

import '../services/auth_api.dart';
import '../services/google_auth.dart';
import '../theme/app_theme.dart';
import '../widgets/gauge_loading.dart';
import '../widgets/xp_logo.dart';
import 'auth_flow.dart';
import 'retailer_registration_screen.dart';

/// Dedicated authentication screen for Gas Stations, Refill Plants, and Retailers.
///
/// Provides both Sign In and Sign Up for business owners with station-tailored
/// messaging, direct routing to the station management portal, and full
/// email-verification support.
class GasStationAuthScreen extends StatefulWidget {
  final LoginSuccess onSuccess;
  final AuthApi? api;
  final bool initialIsSignUp;

  const GasStationAuthScreen({
    super.key,
    required this.onSuccess,
    this.api,
    this.initialIsSignUp = false,
  });

  @override
  State<GasStationAuthScreen> createState() => _GasStationAuthScreenState();
}

enum _StationTab { login, signup }

class _GasStationAuthScreenState extends State<GasStationAuthScreen> {
  late final AuthApi _api = widget.api ?? AuthApi();

  late _StationTab _tab;

  // Login controllers
  final _loginIdentifier = TextEditingController();
  final _loginPassword = TextEditingController();

  // Signup controllers
  final _stationName = TextEditingController();
  final _signupEmail = TextEditingController();
  final _signupUsername = TextEditingController();
  final _signupPassword = TextEditingController();
  final _signupPhone = TextEditingController();

  bool _busy = false;
  String? _error;
  String? _info;

  // Verification state
  bool _signupDone = false;
  String? _verifyEmail;
  DateTime? _lastResend;

  static final _usernameRe = RegExp(r'^[a-zA-Z0-9._]{3,20}$');
  static const _resendCooldown = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    _tab = widget.initialIsSignUp ? _StationTab.signup : _StationTab.login;
  }

  @override
  void dispose() {
    _loginIdentifier.dispose();
    _loginPassword.dispose();
    _stationName.dispose();
    _signupEmail.dispose();
    _signupUsername.dispose();
    _signupPassword.dispose();
    _signupPhone.dispose();
    super.dispose();
  }

  void _switchTab(_StationTab tab) {
    setState(() {
      _tab = tab;
      _error = null;
      _info = null;
      _signupDone = false;
    });
  }

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

  bool _validUsername(String username) {
    if (username.isEmpty || !_usernameRe.hasMatch(username)) {
      setState(() => _error = 'Username must be 3–20 characters: letters, numbers, underscores or periods.');
      return false;
    }
    return true;
  }

  Future<void> _submitLogin() async {
    final identifier = _loginIdentifier.text.trim();
    final password = _loginPassword.text;
    if (identifier.isEmpty) {
      setState(() => _error = 'Please enter your station email or username.');
      return;
    }
    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters.');
      return;
    }

    setState(() => _verifyEmail = identifier.contains('@') ? identifier : null);

    await _run(() async {
      try {
        final result = await _api.login(identifier: identifier, password: password);
        await widget.onSuccess(result, 'email', identifier);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const RetailerRegistrationScreen()),
        );
      } on AuthApiException catch (e) {
        if (!e.isEmailNotVerified) rethrow;
        if (mounted) {
          setState(() {
            _verifyEmail = identifier.contains('@') ? identifier : null;
            _error = 'Please verify your station email first. Check your inbox or resend the link below.';
          });
        }
      }
    });
  }

  Future<void> _submitSignup() async {
    final stationName = _stationName.text.trim();
    final email = _signupEmail.text.trim();
    final username = _signupUsername.text.trim();
    final password = _signupPassword.text;
    final phone = _signupPhone.text.trim();

    if (stationName.isNotEmpty && stationName.length < 2) {
      setState(() => _error = 'Please enter a valid station name.');
      return;
    }
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Please enter a valid station email.');
      return;
    }
    if (!_validUsername(username)) return;
    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters.');
      return;
    }

    await _run(() async {
      final result = await _api.signup(
        email: email,
        password: password,
        phone: phone,
        username: username,
      );
      final session = result.session;
      if (session != null) {
        await widget.onSuccess(session, 'email', email);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => RetailerRegistrationScreen(
              initialName: stationName.isNotEmpty ? stationName : null,
              initialPhone: phone.isNotEmpty ? phone : null,
            ),
          ),
        );
        return;
      }

      if (mounted) {
        setState(() {
          _verifyEmail = email;
          _signupDone = true;
          _signupPassword.clear();
          _info = result.message;
          _lastResend = result.emailSent ? DateTime.now() : null;
        });
      }
    });
  }

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

  Future<void> _googleSignIn() async {
    await _run(() async {
      final String idToken;
      try {
        idToken = await GoogleAuth.signInForIdToken();
      } catch (e) {
        throw AuthApiException(GoogleAuth.describeError(e));
      }
      final result = await _api.google(idToken: idToken);
      await widget.onSuccess(result, 'google', result.email ?? 'Station owner');
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const RetailerRegistrationScreen()),
      );
    });
  }

  void _backToLoginWithEmail() {
    final email = _verifyEmail;
    _switchTab(_StationTab.login);
    if (email != null) _loginIdentifier.text = email;
    setState(() => _verifyEmail = email);
  }

  Widget _buildMessages(ColorScheme scheme) {
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

  Widget _buildStationHero(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF0F231D), Color(0xFF132F27), Color(0xFF1A3F35)]
              : const [Color(0xFFE8F5E9), Color(0xFFF1F8E9), Color(0xFFE0F2F1)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF2A5E4F) : const Color(0xFFA5D6A7),
          width: 1.2,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppTheme.statusOK.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.statusOK, width: 1.5),
                ),
                child: const Icon(Icons.local_gas_station_rounded, color: AppTheme.statusOK, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppTheme.statusOK,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'PARTNER NETWORK',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Gas Station & Refill Portal',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Sign in to manage your refill plant or register a new gas station to appear on the live refill map.',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white70 : Colors.black87,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabToggle(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F1726) : const Color(0xFFE8EEF8),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: _tabChip('Station Sign In', _tab == _StationTab.login, () => _switchTab(_StationTab.login)),
          ),
          Expanded(
            child: _tabChip('Register Station', _tab == _StationTab.signup, () => _switchTab(_StationTab.signup)),
          ),
        ],
      ),
    );
  }

  Widget _tabChip(String label, bool selected, VoidCallback onTap) {
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
              fontSize: 14,
              color: selected ? Colors.white : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoginForm(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('station-login-identifier'),
          controller: _loginIdentifier,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Station email or username',
            prefixIcon: Icon(Icons.storefront_rounded),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const Key('station-login-password'),
          controller: _loginPassword,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Password',
            prefixIcon: Icon(Icons.lock_outline_rounded),
          ),
          onSubmitted: (_) => _submitLogin(),
        ),
        _buildMessages(scheme),
        if (_verifyEmail != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('station-resend-verification'),
              onPressed: _busy ? null : _resendVerification,
              icon: const Icon(Icons.mark_email_unread_outlined),
              label: const Text('Resend verification email'),
            ),
          ),
        ],
        const SizedBox(height: 22),
        ElevatedButton(
          key: const Key('station-login-button'),
          onPressed: _busy ? null : _submitLogin,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: const Text('Sign In to Station Portal', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          key: const Key('station-google-login'),
          onPressed: _busy ? null : _googleSignIn,
          icon: const Icon(Icons.g_mobiledata_rounded, size: 24, color: Color(0xFF4285F4)),
          label: const Text('Sign in with Google (Business)'),
        ),
        const SizedBox(height: 18),
        Center(
          child: TextButton(
            onPressed: () => _switchTab(_StationTab.signup),
            child: const Text('Need to register your gas station? Sign up'),
          ),
        ),
      ],
    );
  }

  Widget _buildVerifyPanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppTheme.statusOK.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.statusOK.withValues(alpha: 0.3)),
          ),
          child: Column(
            children: [
              const Icon(Icons.mark_email_read_outlined, size: 48, color: AppTheme.statusOK),
              const SizedBox(height: 12),
              Text(
                'Verify Station Email',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                'We sent a verification link to ${_verifyEmail ?? 'your email'}. Once verified, log in to complete your station listing and location setup.',
                textAlign: TextAlign.center,
                style: const TextStyle(height: 1.4),
              ),
            ],
          ),
        ),
        _buildMessages(scheme),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          key: const Key('station-resend-verification-button'),
          onPressed: _busy ? null : _resendVerification,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Resend verification email'),
        ),
        const SizedBox(height: 10),
        ElevatedButton(
          onPressed: _busy ? null : _backToLoginWithEmail,
          child: const Text('I verified it — log in'),
        ),
      ],
    );
  }

  Widget _buildSignupForm(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('station-name-field'),
          controller: _stationName,
          decoration: const InputDecoration(
            labelText: 'Station / Business Name',
            hintText: 'e.g. Total Gas Plant, Apex LPG Skid',
            prefixIcon: Icon(Icons.local_gas_station_outlined),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const Key('station-email-field'),
          controller: _signupEmail,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Station Email',
            prefixIcon: Icon(Icons.mail_outline_rounded),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const Key('station-username-field'),
          controller: _signupUsername,
          decoration: const InputDecoration(
            labelText: 'Station Username',
            helperText: '3–20 characters (letters, numbers, _ or .)',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const Key('station-password-field'),
          controller: _signupPassword,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Password',
            helperText: 'At least 8 characters',
            prefixIcon: Icon(Icons.lock_outline_rounded),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const Key('station-phone-field'),
          controller: _signupPhone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Contact Phone Number',
            hintText: '+234...',
            prefixIcon: Icon(Icons.phone_outlined),
          ),
        ),
        _buildMessages(scheme),
        const SizedBox(height: 22),
        ElevatedButton(
          key: const Key('station-signup-button'),
          onPressed: _busy ? null : _submitSignup,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.statusOK,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: const Text('Create Station Account', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          key: const Key('station-google-signup'),
          onPressed: _busy ? null : _googleSignIn,
          icon: const Icon(Icons.g_mobiledata_rounded, size: 24, color: Color(0xFF4285F4)),
          label: const Text('Register with Google (Business)'),
        ),
        const SizedBox(height: 18),
        Center(
          child: TextButton(
            onPressed: () => _switchTab(_StationTab.login),
            child: const Text('Already have a station account? Sign in'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.local_gas_station_rounded, color: AppTheme.statusOK, size: 22),
            SizedBox(width: 8),
            Text('Gas Station Portal', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          ],
        ),
        leading: IconButton(
          tooltip: 'Back to Customer Login',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Personal Account'),
          ),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
                  children: [
                    Align(
                      alignment: Alignment.center,
                      child: XpLogo(
                        width: 100,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        shadow: isDark,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _buildStationHero(isDark),
                    const SizedBox(height: 20),
                    _buildTabToggle(isDark),
                    const SizedBox(height: 20),
                    if (_tab == _StationTab.login)
                      _buildLoginForm(context)
                    else if (_signupDone)
                      _buildVerifyPanel(context)
                    else
                      _buildSignupForm(context),
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.person_outline_rounded, size: 18),
                        label: const Text('Switch back to Personal / Consumer App'),
                      ),
                    ),
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
                  label: _tab == _StationTab.login ? 'Signing into station…' : 'Setting up station…',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
