pianobar for iOS
================

An iOS port of `pianobar`_, a free/open-source client for the personalized
online radio Pandora_. Everything here is the iOS app: a simple, button-first
SwiftUI front end over the original C core. The console client, downloads,
older releases, and the surrounding ecosystem live on the `upstream project`_ —
this repo doesn't repeat them.

.. _pianobar: https://github.com/PromyLOPh/pianobar
.. _upstream project: https://github.com/PromyLOPh/pianobar
.. _Pandora: http://www.pandora.com

.. image:: https://github.com/user-attachments/assets/53741f8a-f3ad-4a94-a906-3291ccf0ed1a
    :alt: pianobar for iOS — single-screen app

What this port does
-------------------

The app is a deliberately simple single screen (portrait-locked, no artwork,
all controls on one screen; a text field + keyboard appears whenever the
backend asks for input):

- **Play** — play/pause, skip to the next song (Pandora has no backward skip),
  volume control, and a stock AirPlay/output picker.
- **Rate** — love (thumbs up), tired (thumbs down), and "explain this song".
- **Stations** — see your stations, switch, rename, delete, and create new
  ones by searching for artists or songs and adding them.
- **Save** — save the current song to an ``.m4a`` and share it to Music,
  Files, or any app.
- **Now Playing** — lock-screen and Control Center controls, plus a live
  now-playing line, via the Media Session / ``MPNowPlayingInfoCenter`` path.
- **Sign in** — enter your Pandora account once; credentials are stored in the
  iOS keychain and you're logged in automatically on the next launch.

How the port works
------------------

The port reuses the unmodified C core (``src/libpiano``) and replaces the
Linux-only dependencies with iOS equivalents behind small shims:

- ``gcrypt`` (Blowfish) → Apple's CommonCrypto
- ``libcurl`` → ``URLSession``
- ``json-c`` → ``JSONSerialization``
- ``libao``/``ffplay`` audio → ``AVPlayer`` streaming the Pandora stream

The GUI is a SwiftUI app (``ios/PianoApp``); the C core is compiled into the
app unchanged via the glue layer (``ios/Glue``).

Install
-------

The easiest way to get the app is the prebuilt build CI publishes:

- CI builds an unsigned ``.ipa`` and publishes it as a GitHub **release** asset
  (``ios-latest``), refreshed on every push to ``master``. Tagged builds are
  published under their tag name.
- Download the ``.ipa`` (it arrives as the bare file, not a zip), then
  re-sign it with your own Apple credentials to install — e.g. with
  Sideloadly, AltStore, or an ad-hoc provisioning profile.

Building from source (macOS + Xcode + `xcodegen`_)
-------------------------------------------------

::

	cd ios
	brew install xcodegen
	xcodegen generate --spec project.yml
	./build.sh                # quick simulator build (plain clang/swiftc)
	xcodebuild -project Piano.xcodeproj -scheme PianoApp test \
	    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
	    CODE_SIGNING_ALLOWED=NO

The Xcode project is *generated* from ``ios/project.yml`` (not
committed). ``ios/Tests/PianoTests.m`` is the unit test suite covering
the shims and the core list/response helpers, and
``ios/Tests/PianoNetworkTests.swift`` adds a live login test that
exercises the real ``PianoClient`` -> C core -> URLSession path
(skipped automatically if the runner cannot reach pandora.com);
both run on the simulator via the command above.

CI (``.github/workflows/ios.yml``) runs the unit tests on a simulator
and additionally produces an unsigned ``.ipa`` published as a GitHub
*release* asset (``ios-latest``) — i.e. it downloads as the bare
``.ipa`` file rather than a zip. An unsigned ``.ipa`` has to be
(re-)signed with your own Apple credentials to install on a device,
e.g. via Sideloadly, AltStore, or an ad-hoc provisioning profile.

.. _xcodegen: https://github.com/yonaskolb/XcodeGen
