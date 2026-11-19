import 'dart:async';
import 'dart:convert';

import 'package:ai_kanban/core/api.dart';
import 'package:ai_kanban/core/models.dart';
import 'package:ai_kanban/core/router.dart';
import 'package:ai_kanban/core/theme.dart';
import 'package:ai_kanban/core/user_store.dart';
import 'package:ai_kanban/features/auth/auth.dart';
import 'package:ai_kanban/features/auth/login_page.dart';
import 'package:ai_kanban/features/boards/members.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Workspace 'w' holds board 'b'; the viewer (ann, u1) has [role] in it.
class _FakeApi extends Api {
  _FakeApi(this.role, this.list) : super(Dio());
  final String role;
  final List<Map<String, dynamic>> list;
  int memberReads = 0, inviteReads = 0;
  final invited = <String>[], roles = <(String, String)>[];
  Future<String> Function(String token) accept = (_) async => 'Acme';

  @override
  Future<({List<Workspace> items, bool offline})> workspaces() async => (
    items: [
      Workspace(
        id: 'w',
        name: 'Acme',
        role: role,
        boards: [BoardRef(id: 'b', name: 'B')],
      ),
    ],
    offline: false,
  );

  @override
  Future<List<Member>> members(String workspaceId) async {
    memberReads++;
    return [for (final m in list) Member.fromJson(m)];
  }

  @override
  Future<List<Invite>> invites(String workspaceId) async {
    inviteReads++;
    final now = DateTime.now().toUtc();
    return [
      Invite.fromJson({
        'id': 'i1',
        'email': 'new@example.com',
        'invitedBy': 'ann',
        'createdAt': now.toIso8601String(),
        'expiresAt': now.add(const Duration(days: 7)).toIso8601String(),
      }),
      Invite.fromJson({
        'id': 'i2',
        'email': 'old@example.com',
        'invitedBy': null,
        'createdAt': now.subtract(const Duration(days: 9)).toIso8601String(),
        'expiresAt': now.subtract(const Duration(days: 2)).toIso8601String(),
      }),
    ];
  }

  @override
  Future<void> invite(String workspaceId, String email) async =>
      invited.add(email);

  @override
  Future<void> setMemberRole(
    String workspaceId,
    String userId,
    String role,
  ) async => roles.add((userId, role));

  @override
  Future<String> acceptInvite(String token) => accept(token);

  /// What each resend waits for.
  Future<void> resendGate = Future.value();
  int resends = 0;

  @override
  Future<void> resendInvite(String workspaceId, String inviteId) {
    resends++;
    return resendGate;
  }

  // Sign-in, for the "Sign in again" round trip.
  @override
  Future<String> health() async => 'dev';

  @override
  Future<Session> devLogin(String login) async => Session.fromJson({
    'token': 't2',
    'user': {'id': 'u1', 'login': login, 'displayName': login},
  });

  @override
  Future<void> logout() async {}
}

Map<String, dynamic> _member(String id, String login, String role) => {
  'userId': id,
  'login': login,
  'displayName': login,
  'role': role,
};

Future<SharedPreferences> _signedIn() async {
  SharedPreferences.setMockInitialValues({
    'session': jsonEncode({
      'token': 't',
      'user': {'id': 'u1', 'login': 'ann', 'displayName': 'ann'},
    }),
  });
  return SharedPreferences.getInstance();
}

Future<void> _pumpMembers(WidgetTester tester, _FakeApi api) async {
  final prefs = await _signedIn();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: MembersDialog(boardId: 'b')),
      ),
    ),
  );
  await tester.pump(); // workspaces
  await tester.pump(); // members and invites
}

Future<void> _pumpInvite(WidgetTester tester, _FakeApi api) async {
  final prefs = await _signedIn();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light),
        routerConfig: GoRouter(
          initialLocation: '/invite/tok',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(body: Text('Home')),
            ),
            GoRoute(
              path: '/invite/:token',
              builder: (_, s) => InvitePage(token: s.pathParameters['token']!),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump(); // accept answers
  await tester.pump(); // navigation
}

DioException _refused(int status, String message, {String? code}) {
  final req = RequestOptions(path: '/invites/tok/accept');
  return DioException(
    requestOptions: req,
    response: Response(
      requestOptions: req,
      statusCode: status,
      data: {'message': message, 'code': ?code},
    ),
  );
}

void main() {
  group('members sheet', () {
    testWidgets('owner sees role controls, invites and pending invites', (
      tester,
    ) async {
      final api = _FakeApi('owner', [
        _member('u1', 'ann', 'owner'),
        _member('u2', 'bob', 'member'),
      ]);
      await _pumpMembers(tester, api);
      expect(find.text('Members of Acme'), findsOneWidget);
      expect(find.text('bob · member'), findsOneWidget);
      expect(find.text('Leave'), findsNothing);
      expect(find.byTooltip('Manage ann'), findsNothing); // the owner row
      expect(find.text('new@example.com'), findsOneWidget);
      expect(find.textContaining('expired'), findsOneWidget);

      await tester.tap(find.byTooltip('Manage bob'));
      await tester.pumpAndSettle();
      expect(find.text('Make member'), findsNothing);
      expect(find.text('Remove'), findsOneWidget);
      await tester.tap(find.text('Make admin'));
      await tester.pumpAndSettle();
      expect(api.roles, [('u2', 'admin')]);
      expect(api.memberReads, 2);

      await tester.enterText(find.byType(TextField), ' sue@example.com ');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(api.invited, ['sue@example.com']);
      expect(api.inviteReads, greaterThan(1));
    });

    testWidgets('admin sees invite controls but not role controls', (
      tester,
    ) async {
      final api = _FakeApi('admin', [
        _member('u0', 'carol', 'owner'),
        _member('u1', 'ann', 'admin'),
        _member('u2', 'bob', 'member'),
      ]);
      await _pumpMembers(tester, api);
      expect(find.text('Email address'), findsOneWidget);
      expect(find.text('Invite'), findsOneWidget);
      expect(
        find.byTooltip('Manage invite to new@example.com'),
        findsOneWidget,
      );
      expect(find.byTooltip('Manage bob'), findsNothing);
      expect(find.byTooltip('Manage carol'), findsNothing);
      expect(find.text('Leave'), findsOneWidget);
    });

    testWidgets('resend is disabled while one is sending', (tester) async {
      final gate = Completer<void>();
      final api = _FakeApi('owner', [_member('u1', 'ann', 'owner')])
        ..resendGate = gate.future;
      await _pumpMembers(tester, api);
      const tip = 'Manage invite to new@example.com';
      bool enabled() => tester
          .widget<PopupMenuButton<String>>(
            find.ancestor(
              of: find.byTooltip(tip),
              matching: find.byType(PopupMenuButton<String>),
            ),
          )
          .enabled;
      await tester.tap(find.byTooltip(tip));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Resend'));
      await tester.pumpAndSettle();
      expect(api.resends, 1);
      expect(enabled(), isFalse);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );

      gate.complete();
      await tester.pumpAndSettle();
      expect(enabled(), isTrue);
    });

    testWidgets('member sees only the list and Leave', (tester) async {
      final api = _FakeApi('member', [
        _member('u0', 'carol', 'owner'),
        _member('u1', 'ann', 'member'),
      ]);
      await _pumpMembers(tester, api);
      expect(find.text('carol · owner'), findsOneWidget);
      expect(find.text('ann · member · you'), findsOneWidget);
      expect(find.text('Leave'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(api.inviteReads, 0);
    });
  });

  group('invite page', () {
    testWidgets(
      'sign_in_again signs out, then comes back to the invite after sign-in',
      (tester) async {
        const message =
            'Sign in again so we can check your GitHub email addresses';
        var accepts = 0;
        final api = _FakeApi('member', [])
          ..accept = (_) {
            if (++accepts == 1) {
              throw _refused(403, message, code: 'sign_in_again');
            }
            return Completer<String>().future; // stays on the invite page
          };
        final container = ProviderContainer(
          overrides: [
            prefsProvider.overrideWithValue(await _signedIn()),
            apiProvider.overrideWithValue(api),
            authApiProvider.overrideWithValue(api),
          ],
        );
        addTearDown(container.dispose);
        final router = container.read(routerProvider)..go('/invite/tok');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              theme: buildTheme(Brightness.light),
              routerConfig: router,
            ),
          ),
        );
        await tester.pump();
        expect(find.text(message), findsOneWidget);
        expect(find.text('Go to workspaces'), findsNothing);

        await tester.tap(find.text('Sign in again'));
        await tester.pump();
        await tester.pump(); // LoginPage asks how to sign in
        expect(container.read(authProvider), isNull);
        expect(find.byType(LoginPage), findsOneWidget);
        expect(
          router.routerDelegate.currentConfiguration.uri.toString(),
          '/login?from=%2Finvite%2Ftok',
        );

        await tester.tap(find.text('Sign in (dev)'));
        await tester.pump();
        await tester.pump();
        expect(
          router.routerDelegate.currentConfiguration.uri.path,
          '/invite/tok',
        );
        expect(accepts, 2);
      },
    );

    testWidgets('accepts, goes home and names the workspace', (tester) async {
      String? token;
      final api = _FakeApi('member', [])
        ..accept = (t) async {
          token = t;
          return 'Acme';
        };
      await _pumpInvite(tester, api);
      expect(token, 'tok');
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('You joined Acme'), findsOneWidget);
    });

    for (final (status, message) in [
      (403, 'This invite was sent to j***@example.com'),
      (404, 'This invite expired or was already used'),
    ]) {
      testWidgets('shows the $status message', (tester) async {
        final api = _FakeApi('member', [])
          ..accept = (_) async => throw _refused(status, message);
        await _pumpInvite(tester, api);
        expect(find.text(message), findsOneWidget);
        expect(find.text('Home'), findsNothing);
        await tester.tap(find.text('Go to workspaces'));
        await tester.pumpAndSettle();
        expect(find.text('Home'), findsOneWidget);
      });
    }
  });

  test('inviteToken reads a link or a bare token', () {
    expect(inviteToken('https://kanban.example.com/#/invite/aB3_-x'), 'aB3_-x');
    expect(inviteToken('  http://localhost:3000/#/invite/tok/ \n'), 'tok');
    expect(inviteToken('http://localhost:3000/#/invite/tok?x=1'), 'tok');
    expect(inviteToken('aB3_-x'), 'aB3_-x');
    expect(inviteToken('http://localhost:3000/#/invite/'), isNull);
    expect(inviteToken('https://kanban.example.com/#/boards/1'), isNull);
    expect(inviteToken('not a token'), isNull);
    expect(inviteToken(''), isNull);
  });

  test('signing in returns to an invite link, and only to one', () {
    String? go(bool signedIn, String location) =>
        authRedirect(signedIn: signedIn, uri: Uri.parse(location));
    final login = go(false, '/invite/tok')!;
    expect(go(false, login), isNull);
    expect(go(true, login), '/invite/tok');
    expect(go(false, '/boards/b'), '/login');
    expect(go(true, '/login'), '/');
    expect(go(true, '/login?from=/boards/b'), '/');
    expect(go(true, '/invite/tok'), isNull);
  });
}
