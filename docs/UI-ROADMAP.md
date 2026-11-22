# Lily UI roadmap: Apple HIG, Liquid Glass and Apple Music

Branch: `ccr-97648d31-v30xzd`. Every change is checked by CI on GitHub's `xcode-27` runner (lint, package tests, app build).

## Done (round 1)

1. Dynamic Type text styles everywhere
2. SF Symbols in place of Material icons
3. iOS system colours for surfaces and text
4. 44-point touch targets
5. Glass and prominent glass buttons
6. Glass controls on Now Playing
7. Mini player as the tab bar accessory; tab bar shrinks on scroll
8. Sheets show their own glass
9. Glass toast
10. Reduce Transparency
11. Settings as iOS grouped Forms
12. ContentUnavailableView empty and error states
13. iOS activity indicator and system placeholder fill
14. Swipe actions (queue, recent searches)
15. Sheet sizes and grabbers
16. No double press effect on glass
17. Haptics
18. Reduce Motion
19. VoiceOver adjustable sliders (already there)
20. Match System look, now the default

## Next: features (round 2, picked)

1. Artwork shrinks when paused, grows on play
2. AirPlay and output picker by the volume slider
3. Sleep timer
4. Full-screen synced lyrics on the phone, tap a line to jump
5. Autoplay (∞) toggle at the top of the queue
6. SF Symbols and sections in every menu
7. Preview above the menu on a long press of albums and playlists
8. System share sheet (ShareLink) in place of only Copy link
9. Title Case for buttons and menu items
15. Large titles on Home and Library
16. Library sort and filter
17. Search scopes (Songs, Albums, Artists, Playlists)

## Deferred

10. Siri and Shortcuts (App Intents)
11. Home screen widgets and a Control Centre control
12. CarPlay (needs an Apple entitlement)
13. Spotlight
14. Handoff
18. VoiceOver headings rotor
19. String catalog for translation
20. Dark, clear and tinted app icon check

## Done: UI/UX, motion and touch (round 3)

All built and checked by CI. Notes:
- U4: header actions sit on glass so iOS 26 menus grow out of them; they stay in the header rather than the toolbar.
- U5, U6: the Up Next / Lyrics switch is iOS's segmented control, and the mini player is the system accessory; both morph themselves.
- U9: presses spring; iOS gives the long-press haptic itself.
- U13: iOS's soft scroll edge is on by default; page tops hide it until the sticky title shows, as before.
- U14: left to iOS's tab bar, which pops to the root and scrolls to the top on a second tap; check on a phone.
- U18: not needed yet: system glass and sheets are concentric already, and no artwork sits inside a rounded container.

### Motion system
- U1. Springs everywhere: `Theme.fast` and `Theme.normal` are ease-out curves; iOS 26 uses springs (`.snappy`, `.smooth`, `.bouncy`).
- U2. Zoom from every card and artwork into its album, playlist or artist page, as Apple Music does.
- U3. Settings sheet zooms out of the account button.
- U4. Menus morph out of their glass buttons: page and Now Playing "more" move into toolbars.
- U5. Glass morphing with `glassEffectID`: play and pause, mini player inline and expanded.
- U6. Sliding selection in pill groups (Up next / Lyrics) rather than a jump.

### Touch feedback
- U7. Symbol effects on every icon action: like bounces, download fills then ticks, shuffle and repeat bounce.
- U8. Scrubber and volume thicken under the finger and stretch at the ends, as Apple Music's do.
- U9. Card and row presses with a spring highlight, and a haptic as a long press opens its menu.
- U10. Changing numbers roll (`.numericText`): elapsed time, song counts, download sizes.

### Scrolling
- U11. Stretchy header: album art and artist banners stretch when pulled down, and the title hands over to the bar smoothly.
- U12. Carousels: cards ease in scale and opacity at the edges (`scrollTransition`).
- U13. Soft scroll edge effect under every bar.
- U14. Tapping the current tab scrolls to the top, then pops to the root.

### Now Playing
- U15. Background colours drift slowly, as Apple Music's do; still with Reduce Motion.
- U16. Lyrics: the sung line grows and the rest soften and blur, gliding between lines.
- U17. Swipe the artwork left or right to skip, with a spring.

### Shape and loading
- U18. Concentric corners (`ConcentricRectangle`) so artwork and cards nest in their containers' curves.
- U19. Sections fade in one after another as a page loads; images settle with a spring.
