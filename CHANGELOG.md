# Changelog

All notable changes to the solstone app for iphone and ipad, including its embedded apple watch app, are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- after you forget a journal, the solstone app no longer tries that journal's addresses when it connects to the next one, and notifications stay off until you turn them on again.
- sharing something that's already in your journal no longer shows up as needing attention with a block of code. it's marked as in your journal. when your journal turns something away, the item now says why in plain words instead of a block of code.
- the recent list on audio now updates when a recording reaches your journal, and shows each one by when it started and how long it ran instead of a code. screen now lists its recent recordings the same way. before you connect a journal, both say recordings will show up there once you do, instead of "couldn't load recent".
- your journal's mark now shows everywhere the app opens your journal, including from location and from an item on this device, and it comes back on its own after you reinstall the app.
- after you delete and reinstall the solstone app, it now tells you once that this device is still connected to your journal, and lets you stay connected or forget the journal.
- sending a test notification now tells you whether it went out to this device.
- when camera access is off for the solstone app, pairing now says so and offers a way to settings, instead of saying the camera is unavailable.
- wording and polish: the audio page calls a waiting recording a recording, not a location update, and the audio page and its home tile no longer repeat "on" while recording. once a journal is connected, the import and audio pages no longer say things stay on this device until you connect one. a file whose size isn't known no longer says "not provided", and rows in the list of what's on this device no longer show a red edge when you aren't swiping them.

## [2.0.5 (108)] - 2026-09-25

### Added
- you can now turn on notifications from your journal on your iphone or ipad, and send a test one, under notifications. your journal encrypts each one to that device's own key, and turning them off tells your journal to stop sending them.
- when your iphone or ipad can't reach your journal, the status screen now shows which addresses it tried and what happened with each one, saying how many more were tried if not all are shown. journal settings also lists your journal's addresses, whether it's using a relay, and which address you're connected through, under technical details.

### Fixed
- on your apple watch, while audio was on, the solstone card and complication switched to "the solstone app hasn't checked in" about ten minutes in, and stayed that way for most of every half hour. they now keep showing "on" for as long as audio is on.

## [2.0.5 (107)] - 2026-09-23

### Changed
- the solstone app on your iphone and ipad follows your light or dark setting again, and its background sun has a version for each. after sunset a warm glow stays in the corner, goes out in the middle of the night, and comes back before sunrise. on your apple watch, the sun now shows only while your wrist is down and the screen is dimmed, and raising your wrist or tapping the screen swaps it for the status and the start and stop button.

### Fixed
- the solstone app on your iphone or ipad now removes a recording only after every file has landed in your journal exactly as your device had it. if something doesn't match, the recording stays on your device and shows as needing attention.

## [2.0.4 (105)] - 2026-09-23

### Fixed
- this is a security fix. other apps and web pages on your iphone or ipad could reach your journal through the solstone app's connection to it, with the same access you have. now that connection only opens for requests carrying a key the solstone app makes each time it starts. if you haven't updated in a while, this is worth doing now.
- a link to an outside website inside your journal now opens in your browser instead of inside the app.
- pairing no longer waits about a minute on an address where your journal can't be reached before it tries the next one. it moves on after a few seconds.

## [2.0.4 (104)] - 2026-09-22

### Changed
- the solstone app now has a sun arc in its background that follows the time of day, on your iphone and ipad and on your apple watch. on your iphone and ipad the app now turns light by day and dark at night with it, instead of following your light or dark setting.
- on your apple watch, the running time now reads like 1h 25m, or 10s in its first minute, instead of a clock-style 85:00.
- the screen source on home is now a switch, like your other sources. it only shows on once your screen is actually being shared, and turning it on or off still goes through the ios screen-sharing sheet.
- the solstone app on your iphone and ipad now opens on a larger solstone mark.
- the "this device" page now shows the name this device uses when it pairs with your journal.

### Fixed
- if the app could not finish checking your journal's mark in time while connecting, it no longer completes pairing silently. it now lets you choose whether to continue or cancel.
- if you turned the microphone on when ios asked about sharing your screen, that sound never reached your journal. it does now, alongside the screen.
- the system ends screen sharing when your device locks, and the app kept saying screen was on. it now shows screen as off, and what you shared up to that moment still reaches your journal.
- screen on your iphone or ipad used to stop about ten minutes after you left the app, and the last stretch of screen before it stopped was thrown away. screen no longer stops on its own just because you left the app, and a cut-off stretch now reaches your journal up to its last second.
- audio on your apple watch now starts again after another app temporarily interrupts it. before, that interruption could end the moment even though you hadn't turned audio off.
- screen waiting to sync could appear under audio in status. it now appears under screen.
- pairing from a link no longer asks for camera access. that prompt only shows now when you actually choose to scan a code.
- pairing failures for a journal reachable from the internet no longer tell you to join the same wi-fi or blame your cellular connection. that advice only shows when a home network really is the reason pairing can't reach it.
- the pairing screen's title said "scan your pairing code" even on its paste tab, which is where a pairing link that failed lands you. the paste tab's title now says "paste your pairing link".
- opening a pairing link to a journal that couldn't be reached could leave the screen on "connecting…" and a spinner for about a minute. after about eight seconds it now adds "still trying to reach your journal."
- scanning a pairing code or pasting a pairing link used to leave the scan screen up, or a greyed-out button, for as long as it took to reach your journal. both now show "connecting…". if the attempt then fails, a scan lands you on the paste tab with the reason.
- scanning a code that wasn't a pairing link told you to "enter a valid pairing link", as if you had typed it in yourself. it now says "this doesn't look like a pairing link".
- opening your journal left the top of home showing above it. your journal now opens to the top of the screen, and the bar you tap to open it now lines up with the cards above it.
- your journal's fingerprint no longer shows as a plain row in journal settings. it's now under "technical details".

### Removed
- the watch no longer tries to send a notification to your wrist when intake stops unexpectedly. opening the solstone app on your watch still tells you why the last session ended.

## [2.0.3 (96)] - 2026-09-17

### Fixed
- after you stopped sharing your screen, turning it back on could say it could not start. it now starts sharing your screen again.

## [2.0.3] - 2026-09-16

### Fixed
- if you turned your screen source off on your iphone or ipad and then back on, it wouldn't start again, and nothing from that attempt reached your journal. it does now.
- pairing told you your journal's dashboard showed a pairing code. it does not. it now says to open the dashboard, go to the network app, and choose "pair a device".
- if this device and your journal were on different networks, pairing said you could switch the journal to private network to pair from anywhere. that was not true of pairing. those messages now say private network lets your devices reach your journal from anywhere, and the cellular failure no longer mentions it.
- the screen tile looked like a switch. it was not. it is now a button that shows what to tap before ios asks, then opens the system sheet. dismissing that sheet no longer leaves screen stuck waiting.
- if the camera became unavailable while you were pointing it at a pairing code, the scan screen stayed up. it now offers paste instead.

## [2.0.2] - 2026-09-16

### Fixed
- if audio from your iphone or ipad stopped partway through, that moment could still land in your journal as if it had finished, with nothing playable in it. the unfinished audio is now deleted instead: a moment that held only that audio no longer reaches your journal, and one that also held location or screen arrives without the audio. thanks to @dvanduzer, who diagnosed it.
- if the solstone app on your iphone or ipad restarted just as audio was starting, that moment could be discarded before it ever reached your journal. the moment now waits for its audio, and reaches your journal if the audio starts.
- while your iphone or ipad is connected to your journal over your local network, sending a lot at once no longer drops the connection partway through.

## [2.0.1 (91)] - 2026-09-14

### Changed
- the paused mark on your apple watch is now a single dash instead of two bars.
- while audio is on, your apple watch does less in the background: its watch-face card refreshes when audio starts or stops rather than each time it checks in, and its timer only runs while the screen is awake.

### Fixed
- once audio from your watch had reached your iphone and was only waiting on confirmation, the watch row could still say it was on your watch and to keep your watch nearby. it now reads as confirming with your iphone.
- if your journal stopped opening from the app with "couldn't reach your journal" after the app had been open a while, this resolves it.
- a connection to your journal that dropped before it finished connecting no longer waits more than it should before trying again.

## [2.0.1] - 2026-09-11

### Added
- report a problem opens the support site with your app version, ios version and a short problem status included.

### Changed
- audio, location and screen now read ready to set up until you've first enabled them. declining microphone or location access during first setup also leaves that source ready to set up, with a way back to ios settings.

### Fixed
- web addresses and common device file paths no longer appear in error details from a network failure or a refused transfer.
- retry messages now say why a transfer is retrying, such as a timeout or a network problem.
- reopening the app on your apple watch now shows needs attention if the app stopped during a moment. it could previously open showing off and miss the wrist alert.

## [2.0.0] - 2026-09-10

### Added
- solstone has a layout of its own on ipad. your sources stay in a column down the left while whatever you open fills the rest of the window, and a menu bar carries keyboard shortcuts for moving between them. before, ipad ran the iphone screen stretched wide.
- widgets on your iphone home and lock screens: pick a source and see whether it's on and how much is waiting. control center gets a button to turn audio on and off and another that goes straight to your journal, and siri can turn audio on.
- the solstone card rises toward the top of your watch's smart stack while audio is on, so you can see it without going to look for it. the live activity on your iphone also has a layout made for your apple watch now. before, the watch built its own from the icon and timer, with nothing to say what it was.

### Changed
- the omi pendant is no longer supported. solstone doesn't connect to a pendant over bluetooth anymore, and no longer asks for bluetooth at all. if a pendant was one of your sources, it's gone from this release, though audio from it that was already waiting to sync still lands in your journal.
- the app on your home screen is called solstone now, on iphone, ipad and apple watch, and it carries a new icon.
- home is rebuilt around your sources: each one is a tile you can read at a glance, settings live in a drawer that slides in from the left, and your journal opens as a pane over it. solstone also follows your light or dark setting instead of always being light, works in landscape on iphone, and holds its layout at the largest text sizes.
- asking a question inside the app is gone, along with the notifications that came with it.
- sharing a large file onto this phone now keeps one copy on the phone, and solstone tells you when the phone cannot hold it. a file your journal turns away stays on the phone instead of disappearing.

### Fixed
- solstone no longer shows your journal as reachable when it isn't. an open connection was taken as proof your journal was still answering behind it, so one that had gone quiet could keep reading connected while nothing was moving. a single failed check now withdraws that, and a connection that is cycling reads connecting rather than claiming to be either up or down.
- a voice memo from your iphone plays back at its true length. a seven-second memo could land in your journal running three times longer than that.
- a moment your watch can't hand to your iphone no longer waits on the watch indefinitely. your watch retries while your iphone is in reach and restarts a transfer that stalls; after about twelve hours of trying it stops, the audio is deleted from the watch, and the entry reads never reached your iphone rather than looking like it's still on its way. the card on your watch face can also no longer get stuck reading audio on after solstone has stopped.

## [0.1.2] - 2026-08-02

### Added
- sol taps your wrist when the audio stops during a moment on your watch, and tells you what happened without making a sound. a moment is audio and location on the way to your journal.

### Changed
- sol won't start a moment on your watch unless it can take audio in. it used to be able to start on location alone, with no audio in it at all. if microphone access is off, sol says so instead of starting.
- the sol complication on your watch face carries the sol mark now, with a distinct shape for each state. it also says when sol hasn't checked in, which used to look identical to sol being off.

### Fixed
- a moment on your apple watch now ends when its audio stops, and your phone shows the watch as needing your attention. before, a moment could keep running after its audio had stopped and report itself as fine while it did, and your phone could then show the watch as "all caught up".
- sol stops showing your journal as reachable once the connection is gone. coming back to sol also re-checks the connection and reconnects if it needs to, so what's waiting no longer sits on a connection that quietly died in the background.
- two iphones no longer show up under the same name when you pair them with your journal.

## [0.1.1] - 2026-07-25

### Added
- sol now shows where what it has taken in on your apple watch is waiting on the way to your journal: on the watch, in transfer to your phone, or on your phone. it reports only what it can verify, and reading it doesn't cost your watch battery when there's a backlog behind it.

### Changed
- sol pbc will never host a journal, so the app no longer offers one. your journal lives on a computer you choose. a journal kept on the phone itself is marked coming later, and you can now see what asking sol is like before you've paired a journal at all.
- sol gets back to your journal sooner after a connection drops. it tries again quicker, and the wait between tries no longer stretches as long as it did.

### Fixed
- your phone stays paired with your journal through a rejection it can't confirm. sol gives up a pairing only when your journal itself says the pairing is gone; before, a repeated rejection on the way to your journal could unpair your phone on its own and leave you scanning a new code. a connection your journal turns away no longer leaves sol stuck instead of trying again, and when pairing does fail, sol names the reason: an address that isn't on your local network is refused before your phone connects to it, with wording that holds up on a VPN, and a dropped pairing connection has its own message instead of sharing one with a different failure.
- a journal address that's already secure is never quietly downgraded to an insecure one. the journal view also either opens your journal or tells you it didn't: a load that stalls now stops and says so instead of sitting on a blank screen, and a message about a load that timed out stays up instead of clearing itself while nothing is loading.
- the watch row now separates three things it used to blur: whether the watch app is installed, whether it's running, and whether it has anything to send. first-run watch setup walks you through getting it going, and "On This Phone" no longer reads as caught up before your phone has reached your journal even once.
- a long answer from sol arrives smoothly. it used to slow down and stutter the longer it got.

## [0.1.0] - 2026-07-12

### Added
- sol on iphone, in beta and reaching invited testers through TestFlight. sol adds what you say and where you are to your journal.
- your iphone pairs with your own journal, on a computer you choose. the phone doesn't hold your journal. it carries what sol has taken in until your journal has it.
- an apple watch app ships with sol on your phone, covered by the same release.
