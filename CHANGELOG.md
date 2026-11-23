# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with versions numbered
`<major>.<minor>` and a two-digit minor (v1.00, v1.01 ... v1.10) to match the release folder names.

## [Unreleased]

## [1.01] - 2026-11-23
### Added
- **MB or Hand**: every cover and list row has a mark showing where its details came from: **MB** (MusicBrainz,
  scanned or found with Look up) or **Hand** (entered by hand). A key at the top shows how many of each, and
  clicking one shows only those CDs (click again for all). `source:mb` and `source:hand` work in the search box.
- The details panel says where the CD's details came from, the list has a sortable **From** column, and the CSV
  and HTML report have a **Details from** / **From** column.
- **HTML report**: hover over an album for a card with its details (and its tracks, once More about the CD and
  artist has been opened for it).
- **HTML report**: hover over a cover to see it big (300 px) beside the pointer. Covers are saved at that size
  in the report, so it's a little larger than before.

## [1.00] - 2026-11-22
First release.

### Added
- **Add a CD by its barcode**: a barcode scanner (or the number typed in) looks the CD up in
  MusicBrainz for the artist, album, year (the album's first release when the pressing has none),
  label, country, tracks and discs, and gets the cover from the Cover Art Archive.
- Barcodes can be scanned one after another: they are looked up in turn in the background, about one
  a second, with waits and a retry when MusicBrainz is busy. Duplicates are pointed out, and unknown
  barcodes are kept as "(not found)" to fill in.
- **Artists**: every artist with how many CDs you have and the years they span; pick one to see all
  their albums together, oldest first (like a discography), with their genres and labels. The search works
  here too, and names count as the same artist whatever their capitals.
- **Search by field**: everything, or one thing picked with the button in the search box (artist, album,
  year, label, genre, barcode or notes), or typed and mixed, such as `year:1990-1999 label:"little wheel"`.
  A year can be one year, a range or a decade (1990s). The search runs a moment after you stop typing.
- **Its own look**: no Windows title bar, a teal and amber side bar, a wall of covers (or a sortable
  list), the selected CD's sleeve with its disc, and rounded controls in every window.
- **Scan several**: scan a pile of CDs onto a waiting list first, then press **Search** (or Enter in the
  empty box, or type "search") to look them all up one after another. Duplicates are pointed out as you
  scan; **Cancel** or Esc forgets the list, and closing the app with barcodes waiting asks first.
- **Which version is yours?**: when MusicBrainz has several versions (pressings) with a barcode, the app asks
  which you have once the look-ups finish, with each version's cover, date, country, label, catalogue number,
  format and tracks. **Choose the version** under a CD's details shows them again.
- **Add to MusicBrainz** for a barcode MusicBrainz doesn't know: opens its Add release page with the barcode
  (and any details typed in) filled in.
- **MB collection**: sends your CDs to a collection in your MusicBrainz account (OAuth sign-in with an
  application you register; tokens kept in settings.json, encrypted with Windows DPAPI).
- Opens big (most of the screen) to show as many CDs as fit, and remembers its size and maximised state.
- **Add by hand** and **Edit**, with Look up (by barcode, or by artist and album), and
  **Look up online** for CDs added by hand.
- **More about the CD and artist**: the track listing with times, first release, label and
  catalogue number, format, genres and the album's Wikipedia introduction, beside the artist's
  origin, dates, genres, members (with their years) and Wikipedia introduction, with links to
  MusicBrainz, Wikipedia, Discogs and the artist's site. Kept for next time; fills in a missing genre.
- **Export CSV** for Excel and other spreadsheets, and **HTML report** with covers (search and sort in
  the browser, prints cleanly, light or dark), each on its own button.
- **Excel-safe CSV**: barcodes keep every digit, titles such as 007 or 3/4 aren't turned into numbers
  or dates, and text starting with = + or - can't run as a formula.
- Search, sortable list with small covers, details panel with the large cover, Remove, MusicBrainz
  page, light, dark and auto looks, Help and an About box. Listed in the Home
  Launcher's Media tab.
