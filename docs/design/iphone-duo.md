# 多多随身 on iPhone Duo

How the app lays out on the foldable. Every other iPhone keeps the phone layout and stays portrait.

The layout follows the size classes, the window size and the fold the system reserves, never the
device model (`DuoLayout.choose` in PocketCore, `ConversationView`). Only a foldable allows landscape
(`Foldable`, `AppDelegate`). The app tells from the screen's shape at launch: both displays are far
squarer than any iPhone that does not fold. Knowing it from the first frame matters because a window
that starts portrait and turns later stays portrait, drawn a quarter turn off, under anything
presented before the turn (the call view, a sheet). A hinge update also marks the device foldable,
for a foldable whose screens the shape check does not recognise.

## One order

Every layout shows the same three things in the same order: **the room, then 多多, then an opened
session**. Opening a session pushes 多多 away from it: to the right in landscape, up in portrait.
Closing it pushes 多多 back. A swipe toward the edge the session leaves by closes it.

The room is the ambient state read from a distance: the animated 多多 mark (the openduo.ai mark,
`LogoMark`), the state under it, and in large type what is being said, the current tool step, or the
last answer with its question (`LastExchange`). Where a layout draws the room, ambient mode opens no
full-screen call view and the ambient pill is hidden; the ambient button toggles it.

## Layouts

| Posture | Layout | Room | Session |
|---|---|---|---|
| Closed, upright (and every iPhone) | `phone`: today's column | full-screen call view and the pill | the drawer lists sessions; a session is pushed, system back |
| Outer display in landscape (tent, or held sideways) | `tent`: the big room with its own row of round controls (静音 · 别说了 · 关闭, or 开环境模式, and 对话) | inline | 对话 opens the thread in a sheet |
| Inner display, landscape | `side`: 多多 beside the room, ambient on or off | right half, controls under it (开环境模式 while off) | opens on the left from the leading drawer; 多多 is pushed right. Back: the glass ‹ or a swipe left |
| Inner display, portrait, flat | `stacked`: the room above 多多 while ambient is on, folded into a band by the handle | top half, or the band with small controls | the list rises from the bottom over the lower half and becomes the session; 多多 is pushed up, the room folds to its band. Back: ‹ in the bar or pulling the list down past its top |
| Half-folded on a table | `tabletop`: the upright half only displays the room; one row of round controls (会话, 静音, 别说了, 关闭) and 多多 below | upright half | rises from the bottom over the lower half; 多多 goes behind the fold. Back: 回到多多 or pulling down |

Every function appears once per layout: what the bar offers is not repeated in the content.

In `tabletop` a hairline (the composer's) marks the fold under the room's controls, and the
conversation scrolls out under it with the system's soft scroll edge, so no row looks cut. `side`
needs neither: its room and conversation meet at a vertical edge rows never cross.

## The vertical bar

Where the system places its vertical bar at the trailing edge (the closed outer display, and the
inner display in landscape), every bar item goes into it (`axisBehavior(.verticalPreferred)`) and
the top keeps no title band. The live mark stands at the top of the bar in place of 多多's title,
then the sessions list or the way back, settings, the Passport (device, link dot, battery under
it) and the ambient button. Where the layout draws the room, the bar leaves out the mark and the
ambient button: the room has both. The bar's presence is the `verticalBarEdge` trait, not the
device model.

## Keyboard

With a session open in `stacked`, the composer sits at the fold and the keyboard covers the
session instead of squeezing both halves. Everywhere else the keyboard lifts the composer as usual.

## Not in this round

- A hint to the brain that the reply will be read on a large display (tent, tabletop).
- Keeping the screen on in the tent or on the table: it follows the existing 保持屏幕常亮 setting.

## Prototype

A prototype with fixture data (not published) was used to choose these layouts in the iOS 27.1
iPhone Duo simulator. To see the real app in each posture:
`-PocketDemo sessions` (DEBUG) shows ambient speaking with a session list and rows.
