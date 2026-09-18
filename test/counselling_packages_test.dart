import 'package:caring_haven/haven.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late HavenStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = HavenStore(await SharedPreferences.getInstance());
  });

  tearDown(() => store.dispose());

  Map<String, dynamic> package({
    String name = 'Single Session',
    int sessions = 1,
    int? minutes = 50,
    int? price,
    int? compare,
    String description = 'A session.',
    bool active = true,
  }) => {
    'name': name,
    'sessions': sessions,
    'minutes': minutes,
    'price_ugx': price,
    'compare_at_ugx': compare,
    'description': description,
    'active': active,
  };

  group('Counselling packages', () {
    test('members only see named, active packages in server order', () {
      store.settings = {
        'counselling_packages': [
          package(name: 'Single Session'),
          package(name: 'Hidden Retreat', active: false),
          {'sessions': 2, 'price_ugx': 1000},
          package(name: '4-Session Journey', sessions: 4),
        ],
      };

      expect(
        counsellingPackages(store).map((p) => p['name']).toList(),
        ['Single Session', '4-Session Journey'],
      );
    });

    test('a missing setting is not treated as a catalogue of packages', () {
      expect(counsellingPackages(store), isEmpty);
      store.settings = {'counselling_packages': 'not-a-list'};
      expect(counsellingPackages(store), isEmpty);
    });

    test('a blank price means price on request, zero means free', () {
      expect(packagePriceLabel(package(price: null)), 'Price on request');
      expect(packagePriceLabel(package(price: 0)), 'Free');
      expect(packagePriceLabel(package(price: 50000)), 'UGX 50,000');
      expect(packagePriceLabel(package(price: 1000000)), 'UGX 1,000,000');
      expect(packageAmount(package(price: null)), isNull);
      expect(packageAmount(package(price: 0)), 0);
      expect(packageAmount(package(price: 25000)), 25000);
    });

    test('only a priced package has to be paid for', () {
      expect(packageNeedsPayment(package(price: null)), isFalse);
      expect(packageNeedsPayment(package(price: 0)), isFalse);
      expect(packageNeedsPayment(package(price: 1)), isTrue);
    });

    test('session count and length describe the package', () {
      expect(packageMeta(package(sessions: 1, minutes: 50)), '1 session · 50 min');
      expect(packageMeta(package(sessions: 4, minutes: 50)), '4 sessions · 50 min');
      expect(packageMeta(package(sessions: 2, minutes: null)), '2 sessions');
    });

    test('payment states are described for members and admins', () {
      expect(paymentLabel('not_required'), 'No payment needed');
      expect(paymentLabel('unpaid'), 'Awaiting payment');
      expect(paymentLabel('pending'), 'Payment pending');
      expect(paymentLabel('paid'), 'Paid');
      expect(paymentLabel('failed'), 'Payment failed');
      expect(paymentLabel(null), '');
    });

    test('amounts from the API are read whether numeric or textual', () {
      expect(moneyValue(50000), 50000);
      expect(moneyValue('50000.00'), 50000);
      expect(moneyValue(null), isNull);
      expect(moneyValue(''), isNull);
      expect(moneyValue('not-a-number'), isNull);
      expect(ugx(50000), 'UGX 50,000');
    });
  });
}
