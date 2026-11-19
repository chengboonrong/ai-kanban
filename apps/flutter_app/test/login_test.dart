import 'package:ai_kanban/core/api.dart';
import 'package:ai_kanban/core/theme.dart';
import 'package:ai_kanban/core/user_store.dart';
import 'package:ai_kanban/features/auth/auth.dart';
import 'package:ai_kanban/features/auth/login_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_secure.dart';

class FakeAuthApi extends Api {
  FakeAuthApi(this.mode) : super(Dio());
  final String mode;
  int polls = 0;
  bool approved = false;
  int failFirst = 0; // polls that answer 503 before anything else

  @override
  Future<String> health() async => mode;

  @override
  Future<GithubDevice> githubDevice() async => const GithubDevice(
    deviceCode: 'dc',
    userCode: 'WDJB-MJHT',
    verificationUri: 'https://github.com/login/device',
    interval: 1,
    expiresIn: 900,
  );

  @override
  Future<({Session? session, int interval, String? failed})> githubToken(
    String deviceCode,
    int interval,
  ) async {
    if (++polls <= failFirst) {
      final req = RequestOptions(path: '/auth/github/token');
      throw DioException(
        requestOptions: req,
        response: Response(requestOptions: req, statusCode: 503),
      );
    }
    return !approved
        ? (session: null, interval: 1, failed: null)
        : (
            session: Session.fromJson({
              'token': 't',
              'user': {'id': 'u1', 'login': 'ann', 'displayName': 'ann'},
            }),
            interval: 0,
            failed: null,
          );
  }
}

Future<ProviderContainer> pump(WidgetTester tester, FakeAuthApi api) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      sessionStoreProvider.overrideWithValue(SessionStore(prefs, FakeSecure())),
      authApiProvider.overrideWithValue(api),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const LoginPage(),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets('github mode shows the code, polls pending, then signs in', (
    tester,
  ) async {
    final api = FakeAuthApi('github');
    final container = await pump(tester, api);
    expect(find.text('Sign in with GitHub'), findsOneWidget);
    expect(find.text('Login'), findsNothing);

    await tester.tap(find.text('Sign in with GitHub'));
    await tester.pump();
    expect(find.text('WDJB-MJHT'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(container.read(authProvider), isNull);

    await tester.pump(const Duration(seconds: 1)); // first poll: pending
    expect(api.polls, greaterThan(0));
    expect(container.read(authProvider), isNull);
    api.approved = true;
    await tester.pump(const Duration(seconds: 1)); // second poll: approved
    expect(container.read(authProvider)?.user.login, 'ann');
  });

  testWidgets('a 503 while polling does not end the sign-in', (tester) async {
    final api = FakeAuthApi('github')
      ..failFirst = 1
      ..approved = true;
    final container = await pump(tester, api);
    await tester.tap(find.text('Sign in with GitHub'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // poll 1: 503
    expect(container.read(authProvider), isNull);
    expect(find.text('WDJB-MJHT'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // poll 2: approved
    expect(container.read(authProvider)?.user.login, 'ann');
  });

  testWidgets('dev mode shows the login form', (tester) async {
    await pump(tester, FakeAuthApi('dev'));
    expect(find.text('Login'), findsOneWidget);
    expect(find.text('Sign in (dev)'), findsOneWidget);
    expect(find.text('Sign in with GitHub'), findsNothing);
  });
}
