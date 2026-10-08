import 'package:flutter_test/flutter_test.dart';

import 'package:wall_e/main.dart';

void main() {
  testWidgets('App builds and shows the eyes screen', (WidgetTester tester) async {
    await tester.pumpWidget(const WallEApp());
    await tester.pump();

    expect(find.byType(EyesScreen), findsOneWidget);
  });
}
