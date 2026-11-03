# rayban-meta-mac

Get the photos and videos off your Ray-Ban Meta glasses and onto your Mac at full quality, straight from the
glasses, with no phone involved. You can also run the glasses from the Mac: battery and status, remote shutter,
settings.

It is built on the protocol that [Visor](https://github.com/macedonga/visor) reverse engineered and documented on its
[wiki](https://github.com/macedonga/visor/wiki). It is written in Swift and has no dependencies.

> **Unofficial.** This project is not affiliated with Meta or EssilorLuxottica. It talks to the glasses the way the
> Meta AI app does, which may be against Meta's terms of use. Setting it up makes your Mac the **owner** of the
> glasses, and the Meta AI app on your phone loses them until you set them up there again. Use it at your own risk.

## What you get

**Glasses.app** is a menu bar app with a glasses icon and no Dock icon. It opens a page in your browser
(`http://127.0.0.1:47392`).

- **Gallery of the glasses**: thumbnails over Bluetooth, and a mark on each item that is already on the Mac.
- **Import**: everything not yet on the Mac, the new items, everything, or a selection, with a progress bar and the
  transfer speed.
- **Delete from the glasses**: optional, after an import, and only for files whose copy passed the checksum and
  size checks.
- **Library of the Mac**: thumbnails, a viewer for HEIC photos and HEVC videos, and byte-identical duplicates
  sent to the Trash.
- **Control**: take a photo, start or stop a video or hyperlapse, sync the clock, and a detailed status (battery,
  case, worn, storage, temperature, and more).
- **Settings of the glasses**: about 60 settings (Meta AI, "Hey Meta", audio, camera, notifications...). Risky
  ones are left out or shown read-only.
- **Account**: check the Meta login, pair again, and a live log.

**`visor-mac`** is the same feature set from the terminal: `status`, `list`, `import`, `delete`, and the rest.

## Requirements

- A Mac with macOS 13 or later, with Bluetooth and Wi-Fi. It was developed on Apple silicon; the emulator step is
  untested on Intel.
- Apple's command line tools. The setup offers to install them; you only click Install.
- About 12 GB of free disk during setup. You can reclaim most of it at the end.
- Ray-Ban Meta glasses, and the Meta account they are set up with. Tested on the Gen 2.
- About 30 minutes, most of it waiting for downloads and builds.

You don't need Homebrew, and the setup never asks for an administrator password. Java and the Android tools are
downloaded from their publishers, Eclipse Adoptium and Google, into your own Library folder, and each download's
checksum is verified.

## Quick start

There are two ways to run the same setup: a guided page in your browser where you only click, or a script in
Terminal.

### Step by step, without Terminal

You don't type any commands: you click, and you log in to Meta once. Allow about 30 minutes, most of it waiting.

**1. Download the project**

1. At the top of this page on GitHub, click the green **Code** button, then **Download ZIP**.
2. Open the ZIP in your Downloads folder by double-clicking it, if your browser has not already done so (Safari
   does). You get a folder named `rayban-meta-mac-main`.
3. Keep that folder. You need it again if you ever have to log in to Meta again or pair the glasses again. If you
   want it somewhere else, for example in Documents, move it now, before you start.

**2. Start the setup**

1. In the folder, double-click **`Install.command`**.
2. The first time, macOS refuses to open it and says it could not verify it. This happens to every file
   downloaded from the internet that does not come from the App Store. Click **Done** (not Move to Trash).
3. Open **System Settings > Privacy & Security** and scroll down to **Security**. Next to the line about
   `Install.command`, click **Open Anyway**, then confirm with your password or Touch ID. If macOS asks once more,
   click **Open Anyway** again. If nothing opens, double-click `Install.command` again.
4. A Terminal window opens. Leave it open until the end; you don't need to type anything in it. If macOS asks
   whether Terminal may access files in your Downloads (or Documents) folder, click **Allow**.
5. If Apple's command line tools are missing, macOS offers to install them. Click **Install**, then **Agree**,
   and wait until they are installed (a few minutes). The setup carries on by itself.
6. After about a minute, the setup page opens in your browser. If it does not, open
   <http://127.0.0.1:47393/>.

**3. Follow the page**

Click **Start the setup**. The page shows the seven steps and their progress. It stops only when it needs you:

1. **Download the Android tools?** Click **Continue**. Meta only hands its login to an Android app, so the setup
   downloads Java and Google's Android tools (about 10 GB) to run one on the Mac. This is the long part, 15 to 30
   minutes.
2. **Your turn: log in to Meta.** A window that looks like a phone screen opens with the Visor app. Log in there
   with the Meta account your glasses are set up with. Use the Mac's keyboard and mouse, and if Meta sends you a
   code, type it there too. The page carries on by itself once you are logged in, and the window closes.
3. **Make this Mac the owner of the glasses?** Read the warning, then click **Yes, pair them**.
4. **Get the glasses ready.** Turn Bluetooth off on your phone. Take the glasses out of the case, open the arms,
   and keep them next to the Mac. Hold the capture button until the light blinks blue, then click **The light is
   blinking blue: pair now**.
   - macOS asks whether Terminal may use Bluetooth: allow it.
   - A Bluetooth connection request for the glasses appears: click **Connect**.
   - If it does not work, the page asks you to put the glasses back in pairing mode and try again.
5. **Free … GB?** Click **Remove**. The Android tools were only needed for the login; if you ever log in again,
   the setup downloads them again.
6. **Setup finished.** Click **Open Glasses**. The page turns into the Glasses app, and you can close the Terminal
   window and turn Bluetooth back on on your phone.

If a step fails, the page says what to do and offers **Try again**: the steps already done are skipped. If you
closed the Terminal window by mistake, double-click `Install.command` again and the setup continues where it
stopped.

**4. Use Glasses**

Glasses lives in the menu bar, as a glasses icon at the top right of the screen, not in the Dock. To open it later,
click that icon and choose **Open Glasses**, or search for "Glasses" in Spotlight.

1. Keep the glasses out of the case with the arms open, and click **Connect**. The first time, macOS asks whether
   Glasses may use Bluetooth: allow it.
2. On **Home**, click **Import what is missing**. The first time, macOS asks whether Glasses may access the folder
   the files go to (in Pictures), and whether it may find devices on your local network: allow both, or the
   import cannot work.
3. During the import the Mac leaves your Wi-Fi for the glasses' own Wi-Fi, so it has no internet for a few
   minutes. It goes back to your Wi-Fi by itself.

**Later**

- **To update**, download the ZIP again, open its `Install.command` the same way (macOS asks for **Open Anyway**
  again), and click **Check everything again**. The setup rebuilds Glasses and skips what is already done.
- **To log in to Meta again or pair again**, double-click `Install.command` and open **More options**.

### In Terminal

```sh
git clone https://github.com/yass-dev/rayban-meta-mac.git
cd rayban-meta-mac
./setup.sh
```

### What happens

Both ways run `setup.sh`, which does everything and logs everything to `~/Library/Logs/rayban-meta-mac/`. It
only stops for these things:

1. **It asks before downloading the Android tools.** These are Java 21 (Eclipse Temurin) and Google's Android
   command line tools, plus the Android SDK licenses. They exist only to get a Meta login token (see
   [How the login works](#how-the-login-works)).
2. **You log in to Meta in the emulator window.** An Android emulator opens with the Visor app. You type your Meta
   credentials into Meta's own login screen there, and the setup waits until the login token appears. It never
   sees your password.
3. **It asks you to confirm the ownership transfer.**
4. **You put the glasses in pairing mode.** Turn Bluetooth off on your phone, take the glasses out of the case, and
   hold the capture button until the LED blinks blue. On the Mac, accept the Bluetooth prompts: let Terminal use
   Bluetooth, then click "Connect".
5. **It offers to remove the emulator and the Android tools**, which you no longer need.

When it finishes, **Glasses** opens: look for the glasses icon in the menu bar. Spotlight finds it as "Glasses".
On first launch macOS may ask for access to the export folder, and on the first connection it asks for Bluetooth.

The setup is safe to run again, because every step checks first whether it is already done. On the guided page,
these options are under **More options**. In Terminal they are flags:

| Option | What it does |
|---|---|
| `--relogin` | Log in to Meta again. |
| `--repair` | Take ownership again, for example after the glasses were reset. |
| `--cleanup` | Only remove the Android emulator and tools. |
| `--no-app` | Skip building Glasses.app. |

## Using it

Keep the glasses out of the case, with the arms open, near the Mac. In Glasses, click **Connect**: the
connection uses Bluetooth LE and can take up to a minute.

**During an import the Mac has no internet.** Over Bluetooth, the Mac asks the glasses to open a Wi-Fi network of
their own. The Mac joins it, receives the files at 7 to 8 MB/s, and goes back to your Wi-Fi when the transfer
ends. Don't switch networks while it runs.

From the terminal:

```sh
.build/release/visor-mac status              # model, serial, firmware
.build/release/visor-mac list                # what is on the glasses
.build/release/visor-mac import              # what the glasses have not handed to any phone yet
.build/release/visor-mac import --all        # everything
.build/release/visor-mac delete --handle H   # delete one capture from the glasses
.build/release/visor-mac help
```

You can also double-click `scripts/Import.command` in the Finder.

Exports go to `~/Pictures/Ray-Ban Meta` by default; you can change the folder in the app's settings. Files are
named `Visor_<yyyyMMdd_HHmmss>_<handle>.mp4|heic`, and a live photo's clip gets `_live.mp4`.

**Already imported to your phone?** The Meta AI app deletes captures from the glasses once it has them. Those
files are on the phone, not on the glasses, so this project cannot fetch them.

## Where things are

| Path | What is there |
|---|---|
| `~/Library/Application Support/visor-mac/` | The owner key (`owner_key.pem`), the Meta login (`meta_login.txt`), the app tokens (`tokens.json`), which glasses you own (`glasses.json`), and the preferences. Every file is `chmod 600`. |
| `~/Library/Caches/visor-mac/` | Previews and thumbnails. Safe to delete. |
| `~/Library/Logs/rayban-meta-mac/` | The setup logs. |
| `~/Applications/Glasses.app` | The app. `./make-app.sh` rebuilds it. |
| `.work/` (in the repository) | The Visor source, the APK, and the build used for the login. Removed by the cleanup. |
| `~/Library/Android/sdk`, `~/Library/Android/rayban-meta-mac-jdk21` | The Android tools and Java the login needs. An Android Studio SDK already there is reused, and is never removed. Removed by the cleanup otherwise. |
| `~/.android/avd/visor_login.avd` | The emulator. Removed by the cleanup. |

Your photos and videos never leave the Mac. The local server listens on `127.0.0.1` only. It refuses any request
whose Host is not the loopback address, and any change without its own `X-Visor` header, so a web page elsewhere
cannot drive your glasses.

## How the login works

The glasses accept an owner only once Meta's server has signed off on the pairing, and that needs a Meta login
token.

- **The web login does not work.** Meta's web login flow gives a code that its token exchange currently refuses
  with HTTP 500. Visor moved to Meta's native Android login for the same reason.
- **So `setup.sh` gets the token from Visor itself.**
  1. It downloads Visor's public release APK from GitHub, checks the published checksum, and reads the Meta app
     tokens (`HW|`, `AR|`, `FRL|`) compiled into it. The tokens are not in this repository.
  2. It builds Visor from source, at the commit it was tested with, with [a two-line patch](patches/visor-export-frla.patch)
     that also writes the login token to a file inside the app.
  3. It runs that build in an Android emulator, where you log in.
  4. It reads the token back with `adb` into `meta_login.txt`, and checks it with Meta.
- **After the pairing, no Meta server is involved.** Listing, importing, controlling and settings all go directly
  between the Mac and the glasses.

## Troubleshooting

- **The connection times out.** The glasses only accept their owner, and only when they are awake. Take them out of
  the case, open the arms, and retry. If that still fails, turn off Bluetooth on the phone and put the glasses in
  pairing mode.
- **Pairing fails, or you missed the macOS "Connect" prompt.** Put the glasses back in pairing mode and run
  `./setup.sh --repair`.
- **Meta refuses the login.** Run `./setup.sh --relogin`.
- **The tokens are not found in the APK.** Visor may have changed. Try a newer release with
  `VISOR_APK_VERSION=x.y.z ./setup.sh`, and open an issue.
- **The Mac did not return to your Wi-Fi after an import.** macOS normally rejoins on its own; if it doesn't, pick
  your network in the menu bar.
- **The Bluetooth or folder permission was denied.** Allow it again in System Settings > Privacy & Security >
  Bluetooth, or Files and Folders.
- **Something else went wrong.** Glasses has a **Log** tab: tick "technical details" and copy it. For the
  setup, look at the log file it names.

**Going back to the Meta AI app:** set the glasses up again in the Meta AI app, which takes ownership back. If the
app does not find them, reset the glasses first; see Meta's support pages for the reset procedure.

## Status

| What | Status |
|---|---|
| Pairing, Meta login through the emulator | Tested on Ray-Ban Meta Gen 2 (product 266) |
| Import over the glasses' Wi-Fi (HEVC 1728x2304 videos, 7-8 MB/s) | Tested on Gen 2 |
| Bluetooth LE transport, AirShield, DataX, trust | Tested on Gen 2 |
| Status, shutter, clock, settings, previews, delete | Implemented from Visor; lightly tested |
| Bluetooth Classic (RFCOMM channel 7) | The glasses refuse it from a Mac; LE is used instead |
| Live stream, assistant, video stabilisation | Not ported |

Other Meta glasses (Oakley Meta, Gen 1) speak the same protocol according to Visor, but are untested here.

## How it works

`VisorKit` is the protocol stack, `visor-mac` is the CLI, and `visor-web` is the menu bar app with its HTTP
server. The page itself is in `web/`.

How an import runs:

1. **Over Bluetooth LE.** The session starts with the handshake, trust and EndLinkSetup. Then svc18 lists the
   captures, as one type 6 flatbuffer per capture.
2. **Queuing.** For each wanted capture the Mac sends svc18 0x86 `<handle>:7` (the HIGH link), plus 0x83 for
   assets already delivered.
3. **The glasses' Wi-Fi.** svc10 CreateSoftApNetwork asks the glasses to host a 2.4 GHz network; they answer with
   the address, credentials and port. The Mac joins it with `networksetup`.
4. **A second session over TCP**, with the same handshake and trust. The glasses drop Bluetooth on their own.
5. **The transfer.** Airship (svc20) offers each file. The receiver accepts it with a cursor, appends the chunks,
   checks the adler32 when the file completes, and drops it.
6. **Back home.** DestroySoftApNetwork closes the glasses' network, and the Mac returns to its own.

Protocol traps carried over from Visor:

- EndLinkSetup and the Wi-Fi UUIDs must be RFC 4122 v4, or the glasses tear the channel down silently.
- Only the opening frame carries the service id and message type; continuations report 0 and are padded.
- The channel registry keys on the originator bit, the high bit of the channel id.
- Framing is `4 + length`, not `header_len + length`.
- Trust is ECDSA over the prehashed binding, with coordinates fixed at 32 bytes and `s` low. CryptoKit hashes
  before signing, so the code signs the 64-byte preimage whose SHA-256 is the binding.
- In airship, accepting or refusing a file must end with a drop on type 7, or the glasses' send queue stalls.

## Development

```sh
swift build            # debug build of the CLI and the app
swift test             # protocol tests (no hardware needed)
./make-app.sh          # release build into ~/Applications/Glasses.app
VISOR_WEB_DIR=$PWD/web .build/debug/visor-web    # run the app from the build, with live-reloaded web files
.build/debug/visor-web --setup --repo $PWD         # the guided setup page (port 47393), driving ./setup.sh
```

The guided setup and `setup.sh` share one implementation. With `SETUP_MACHINE=1`, `setup.sh` prints one
`@@kind<TAB>field...` line per event (`step`, `run`, `tick`, `ok`, `warn`, `skip`, `ask`, `pause`, `action`,
`fail`, `stopped`, `done`) and reads its answers on stdin; `Sources/visor-web/Setup.swift` turns those lines into
the page's state. To look at the page without touching anything, point `VISOR_SETUP_SCRIPT` at a script that
speaks the same protocol.

## Credits and license

The protocol work is [Visor](https://github.com/macedonga/visor)'s, by macedonga, documented on its wiki. This
project ports its Kotlin code to Swift and follows its structure. Like Visor, it is licensed under the
[GNU AGPL v3](LICENSE).
