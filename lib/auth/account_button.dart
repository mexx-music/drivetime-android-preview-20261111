import 'package:flutter/material.dart';

import '../account/account_service.dart';
import 'auth_service.dart';

/// Anmelde-Knopf in der Kopfzeile. Bei ausgeschaltetem Login unsichtbar.
class AccountButton extends StatelessWidget {
  const AccountButton({super.key, required this.auth, this.account});

  final AuthService auth;

  /// Kontozustand laut Proxy; null = nicht angebunden.
  final AccountService? account;

  @override
  Widget build(BuildContext context) {
    if (!auth.enabled) return const SizedBox.shrink();
    return ValueListenableBuilder<AuthUser?>(
      valueListenable: auth.user,
      builder: (context, user, _) {
        if (user == null) {
          return IconButton(
            tooltip: 'Anmelden',
            icon: const Icon(Icons.person_outline_rounded),
            onPressed: () => showLoginSheet(context, auth),
          );
        }
        return PopupMenuButton<String>(
          tooltip: 'Konto',
          icon: const Icon(Icons.account_circle_rounded),
          onSelected: (value) async {
            if (value == 'logout') await auth.signOut();
            if (value == 'retry') await account?.retry();
          },
          itemBuilder: (_) {
            final state = account?.state.value;
            return [
              PopupMenuItem<String>(
                enabled: false,
                child: Text(user.email ?? 'Angemeldet'),
              ),
              if (state != null)
                PopupMenuItem<String>(
                  key: const Key('account-state'),
                  enabled: false,
                  child: Text(accountStateLabel(state)),
                ),
              if (state?.phase == AccountPhase.error)
                const PopupMenuItem<String>(
                    value: 'retry', child: Text('Erneut versuchen')),
              const PopupMenuItem<String>(value: 'logout', child: Text('Abmelden')),
            ];
          },
        );
      },
    );
  }
}

/// Anzeige des Kontozustands. Ein Plan erscheint nur, wenn der Proxy ihn
/// bestätigt hat – bei einem Fehler nie ein Ersatz-Plan.
String accountStateLabel(AccountState state) {
  switch (state.phase) {
    case AccountPhase.disabled:
    case AccountPhase.signedOut:
      return '';
    case AccountPhase.loading:
      return 'Konto wird geladen …';
    case AccountPhase.ready:
      return 'Plan: ${state.info!.planKey}';
    case AccountPhase.error:
      return switch (state.error!) {
        AccountErrorKind.sessionRejected =>
          'Konto nicht verfügbar: bitte neu anmelden',
        AccountErrorKind.forbidden => 'Konto nicht verfügbar: kein Zugriff',
        AccountErrorKind.network => 'Konto nicht verfügbar: keine Verbindung',
        AccountErrorKind.unavailable ||
        AccountErrorKind.notConfigured ||
        AccountErrorKind.invalidResponse =>
          'Konto gerade nicht verfügbar',
      };
  }
}

Future<void> showLoginSheet(BuildContext context, AuthService auth) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => LoginSheet(auth: auth),
  );
}

/// Zwei Schritte: E-Mail → Code. Kein Passwort, kein Link.
class LoginSheet extends StatefulWidget {
  const LoginSheet({super.key, required this.auth});

  final AuthService auth;

  @override
  State<LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<LoginSheet> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on AuthFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (_) {
      if (mounted) setState(() => _error = const AuthFailure(AuthFailureKind.unknown).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() => _run(() async {
        await widget.auth.requestCode(_email.text);
        if (mounted) setState(() => _codeSent = true);
      });

  Future<void> _verify() => _run(() async {
        await widget.auth.verifyCode(_email.text, _code.text);
        if (mounted) Navigator.of(context).pop();
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Anmelden', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            _codeSent
                ? 'Wir haben dir einen Code an ${_email.text.trim()} geschickt.'
                : 'Du bekommst einen Code per E-Mail. Kein Passwort nötig.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          if (!_codeSent) ...[
            TextField(
              key: const Key('login-email'),
              controller: _email,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'E-Mail-Adresse'),
              onSubmitted: (_) => _sendCode(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _sendCode,
              child: const Text('Code senden'),
            ),
          ] else ...[
            TextField(
              key: const Key('login-code'),
              controller: _code,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: const InputDecoration(labelText: 'Code aus der E-Mail'),
              onSubmitted: (_) => _verify(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _verify,
              child: const Text('Anmelden'),
            ),
            Row(
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _codeSent = false;
                            _code.clear();
                            _error = null;
                          }),
                  child: const Text('Andere E-Mail'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _busy ? null : _sendCode,
                  child: const Text('Code erneut senden'),
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                key: const Key('login-error'),
                style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
