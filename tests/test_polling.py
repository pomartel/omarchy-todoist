"""Exercise the actual panel Timer in Qt without loading the plugin/account."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

QML = Path('/usr/lib/qt6/bin/qml')

@unittest.skipUnless(QML.exists(), 'Qt 6 qml runtime is required')
class PollingTests(unittest.TestCase):
    def test_timer_tracks_visibility_and_disconnect(self):
        source = (Path(__file__).parents[1] / 'Panel.qml').read_text()
        timer = re.search(r'  Timer \{\n    id: refreshTimer\n.*?\n  }', source, re.S).group(0)
        qml = '''import QtQml
QtObject {
 id: root
 property bool opened: false
 property bool settingsLoaded: true
 property string apiToken: "dummy"
 function refresh() {}
 property Timer poll: ''' + timer + '''
 Component.onCompleted: Qt.callLater(function() {
   if (!refreshTimer.running || refreshTimer.interval !== 1200000) { Qt.exit(1); return }
   root.opened = true
   Qt.callLater(function() {
     if (!refreshTimer.running || refreshTimer.interval !== 120000) { Qt.exit(2); return }
     root.apiToken = ""
     Qt.callLater(function() { Qt.exit(refreshTimer.running ? 3 : 0) })
   })
 })
}'''
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'poll.qml'; path.write_text(qml)
            result = subprocess.run([str(QML), '--apptype', 'core', '-f', str(path)],
                capture_output=True, text=True, timeout=10, env=dict(os.environ, QT_QPA_PLATFORM='offscreen'))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == '__main__': unittest.main()
