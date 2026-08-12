import 'package:flutter_test/flutter_test.dart';
import 'package:vokabeltrainer/main.dart';

void main() {
  testWidgets('Vokabeltrainer startet', (WidgetTester tester) async {
    await tester.pumpWidget(const VokabelTrainerApp());
    expect(find.text('Meine Vokabelgruppen'), findsOneWidget);
  });
}
