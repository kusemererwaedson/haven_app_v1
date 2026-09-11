import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:caring_haven/haven.dart';

class OfflineStore extends HavenStore {
  OfflineStore(super.preferences);
  @override
  Future<void> refresh() async {}
}

void main() {
  testWidgets('Cached messages remain searchable and readable offline', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = OfflineStore(await SharedPreferences.getInstance());
    store.contents = [
      {
        'id': 1,
        'title': 'Grace for today',
        'type': 'devotional',
        'category': 'Faith',
        'audience': 'adult',
        'body': 'A word of hope.',
      },
    ];
    await tester.pumpWidget(HavenApp(store: store));
    await tester.pumpAndSettle();
    expect(find.text('A little closer to God.'), findsOneWidget);
    await tester.tap(find.text('Devotionals'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('No messages found. Try another search.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Grace');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Grace for today').first);
    await tester.pumpAndSettle();
    expect(find.text('A word of hope.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
