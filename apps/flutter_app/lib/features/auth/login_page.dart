import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/glyphs.dart';
import '../../core/theme.dart';
import 'auth.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _login = TextEditingController(text: 'dev');
  String? _error;
  bool _busy = false;
  String? _mode; // from /health: 'dev', 'github' or 'none'; null until known
  GithubDevice? _device;
  // Bumped to stop the poll in flight (Cancel, or a new start).
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final mode = await ref.read(authApiProvider).health();
      if (mounted) setState(() => _mode = mode);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _startGithub() async {
    final mine = ++_attempt;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final device = await ref.read(authApiProvider).githubDevice();
      if (!mounted || mine != _attempt) return;
      setState(() => _device = device);
      final failed = await ref
          .read(authProvider.notifier)
          .githubSignIn(device, () => !mounted || mine != _attempt);
      if (mounted && mine == _attempt) {
        setState(() {
          _device = null;
          _error = failed;
        });
      }
    } catch (e) {
      if (mounted && mine == _attempt) {
        setState(() {
          _device = null;
          _error = errorMessage(e);
        });
      }
    } finally {
      if (mounted && mine == _attempt) setState(() => _busy = false);
    }
  }

  void _cancel() => setState(() {
    _attempt++;
    _device = null;
    _busy = false;
  });

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authProvider.notifier)
          .devLogin(_login.text.trim().toLowerCase());
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _attempt++;
    _login.dispose();
    super.dispose();
  }

  Widget _screen(BuildContext context, Glyph glyph, Widget body) {
    final t = context.tokens;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.screen,
        borderRadius: BorderRadius.circular(Tokens.radiusScreen),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            GlyphKey(glyph, color: t.idle, size: 32),
            const SizedBox(width: 14),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget _statusPanel(BuildContext context) {
    final t = context.tokens;
    final small = Theme.of(context).textTheme.bodySmall!;
    final text = switch (_mode) {
      'none' => 'The server has no sign-in configured.',
      null when _error != null => 'Could not reach the server.',
      null => 'Asking the server how to sign in...',
      _ => 'Server: ${Uri.base.resolve(apiUrl)}',
    };
    return _screen(
      context,
      Glyph.worker,
      Text(text, style: t.mono(small.copyWith(color: t.screenInk))),
    );
  }

  Widget _codePanel(BuildContext context, GithubDevice d) {
    final t = context.tokens;
    final theme = Theme.of(context);
    return _screen(
      context,
      Glyph.link,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter this code on GitHub',
            style: t.mono(
              theme.textTheme.bodySmall!.copyWith(color: t.screenMuted),
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            d.userCode,
            style: t.mono(
              theme.textTheme.headlineMedium!.copyWith(
                color: t.screenInk,
                letterSpacing: 2,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: d.userCode)),
                child: const Text('Copy'),
              ),
              OutlinedButton(
                onPressed: () => launchUrl(Uri.parse(d.verificationUri)),
                child: const Text('Open github.com/login/device'),
              ),
              TextButton(onPressed: _cancel, child: const Text('Cancel')),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Waiting for you to approve...',
            style: t.mono(
              theme.textTheme.bodySmall!.copyWith(color: t.screenMuted),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('AI Kanban', style: theme.textTheme.headlineMedium),
                const SizedBox(height: 8),
                if (_mode == 'github' || _mode == 'dev')
                  Text(
                    _mode == 'github' ? 'Sign in with your GitHub account.' : 'Local development sign-in. The API must be running with AUTH_MODE=dev.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: t.muted),
                  ),
                const SizedBox(height: 24),
                if (_device != null)
                  _codePanel(context, _device!)
                else if (_mode == 'dev')
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: t.screen,
                      borderRadius: BorderRadius.circular(Tokens.radiusScreen),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          GlyphKey(Glyph.worker, color: t.idle, size: 32),
                          const SizedBox(width: 14),
                          // What the code proves about sign-in: which API it asks, and that a login name is all it takes.
                          Expanded(
                            child: Text(
                              'Server: ${Uri.base.resolve(apiUrl)}\nSign-in: login name, no password',
                              style: t.mono(
                                theme.textTheme.bodySmall!.copyWith(
                                  color: t.screenInk,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  _statusPanel(context),
                const SizedBox(height: 24),
                if (_mode == 'dev') ...[
                  // 8px vertical padding brings the field to the button's 40px.
                  TextField(
                    controller: _login,
                    decoration: const InputDecoration(
                      labelText: 'Login',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: const Text('Sign in (dev)'),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(color: t.danger),
                  ),
                ],
                if (_mode == null && _error != null) ...[
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _load, child: const Text('Retry')),
                ],
                if (_mode == 'github' && _device == null) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _startGithub,
                    child: const Text('Sign in with GitHub'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
