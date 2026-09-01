# Changelog

All notable changes to the solstone app for iphone, including its embedded apple watch app, are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- sharing a large file onto this phone now keeps one copy on the phone, and sol tells you when the phone cannot hold it. a file your journal turns away stays on the phone instead of disappearing.

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
