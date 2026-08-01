import 'package:integration_test/integration_test.dart';

import '../test/support/demo_flow_suite.dart';
import '../test/support/production_verification_suite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerDemoFlowTests();
  registerProductionVerificationTests(physicalDevice: true);
}
