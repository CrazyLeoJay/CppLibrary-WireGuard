import singleFlightLoopTest from './SingleFlightLoop.test';
import vpnRunStatusTextTest from './VpnRunStatusText.test';
import vpnEventFreshnessTest from './VpnEventFreshness.test';

export default function testsuite() {
  singleFlightLoopTest();
  vpnRunStatusTextTest();
  vpnEventFreshnessTest();
}
