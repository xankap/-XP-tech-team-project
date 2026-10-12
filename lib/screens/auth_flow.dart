import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import '../widgets/gauge_loading.dart';

const _tokenKey = 'xp_auth_access_token';
const _emailKey = 'xp_auth_email';

String apiBaseUrl() {
  const fromEnv = String.fromEnvironment('XP_API_BASE_URL');
  if (fromEnv.isNotEmpty) return fromEnv;
  // Local backend default for desktop/web testing
  return 'http://127.0.0.1:3000';
}

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

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.length < 8) {
      setState(() => _error = 'Enter a valid email and password (8+ characters).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final uri = Uri.parse('${apiBaseUrl()}/auth/login');
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email, 'password': password}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final token = body['token']?.toString();
        if (token == null || token.isEmpty) {
          throw Exception('Login succeeded but no token returned');
        }
        await widget.onSuccess(token, email);
      } else {
        String msg = 'Login failed';
        try {
          msg = (jsonDecode(res.body) as Map)['error']?.toString() ?? msg;
        } catch (_) {}
        setState(() => _error = msg);
      }
    } catch (e) {
      setState(() => _error = 'Could not reach server. Is the backend running on ${apiBaseUrl()}?');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 36, 24, 24),
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
                    Text('Sign in', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text('Secure access to your XP Tech gas monitor', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 28),
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
                      onSubmitted: (_) => _submit(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600)),
                    ],
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _busy ? null : _submit,
                        child: const Text('Log in'),
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
              child: const Center(
                child: GaugeLoadingIndicator(
                  size: 150,
                  label: 'Signing you in…',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
