#!/bin/zsh
# Double-click in the Finder: import from the glasses what the Mac does not have yet.
# Options pass through, for example `scripts/Import.command --all` from a terminal.
cd "$(dirname "$0")/.." || exit 1
if [ ! -x .build/release/visor-mac ]; then
  echo "First run: building the client..."
  swift build -c release --product visor-mac || exit 1
fi
echo "Glasses on, out of the case, next to the Mac."
echo "During the transfer the Mac joins the glasses' Wi-Fi and has no internet; it comes back by itself."
echo
.build/release/visor-mac import "$@"
rc=$?
echo
if [ $rc -ne 0 ]; then
  echo "Failed. If the glasses could not be reached: open them, turn off Bluetooth on your phone,"
  echo "put them in pairing mode (hold the capture button until the LED blinks blue), and try again."
fi
open "$(.build/release/visor-mac export-dir 2>/dev/null)" 2>/dev/null
exit $rc
