# 多多随身 on iPhone Duo

How the app lays out on the foldable. Every other iPhone keeps the phone layout and stays portrait.

The layout follows the size classes, the window size and the fold the system reserves, never the
device model (`DuoLayout.choose` in PocketCore, `ConversationView`). Only a foldable allows landscape
(`Foldable`, `AppDelegate`). The app tells from the screen's shape at launch: both displays are far
squarer than any iPhone that does not fold. Knowing it from the first frame matters because a window
that starts portrait and turns later stays portrait, drawn a quarter turn off, under anything
presented before the turn (the call view, a sheet). A hinge update also marks the device foldable,
for a foldable whose screens the shape check does not recognise.

## 多多 stays put

On the inner display 多多's conversation keeps one place, as on the outer display: the trailing
side in landscape, the lower half in portrait. Large type reads best there. The other side is a
**pane** with three levels: the room (by default), the session list, and an opened session. The
sessions button shows and hides the list in the pane (filled while the pane is away from the room);
picking a session replaces the list; ‹ on a session goes back to the list. The list has no
‹: its room row, the sessions button or a swipe right return to the
room. The sessions button goes up one level each time: a session to the list, the list to the room.

Inside the pane a deeper level comes in from the trailing side (toward 多多), as a phone pushes a
page in from the right; going back reverses it, and a swipe right goes back, as on a phone. Only
the pane moves; 多多 and the line between them never do.

The room is the ambient state read from a distance: the animated 多多 mark (the openduo.ai mark,
`LogoMark`), the state under it, and in large type what is being said, the current tool step, or the
last answer with its question (`LastExchange`). Where a layout draws the room, ambient mode opens no
full-screen call view and the ambient pill is hidden; the ambient button toggles it.

## Layouts

| Posture | Layout | Room | Session |
|---|---|---|---|
| Closed, upright (and every iPhone) | `phone`: today's column | full-screen call view and the pill | the drawer lists sessions; a session is pushed, system back |
| Outer display in landscape (tent, or held sideways) | `tent`: the big room with its own row of round controls (静音 · 别说了 · 关闭, or 开环境模式, and 对话) | inline | 对话 opens the thread in a sheet |
| Inner display, landscape | `side`: the pane on the left, 多多 on the right | the pane's first level, ambient on or off, controls under it (开环境模式 while off) | the list and then the session replace the room in the pane. Back: the glass ‹ or a swipe right |
| Inner display, portrait, flat | `stacked`: the pane above 多多 | the pane's first level while ambient is on, folded into a band by the handle; with ambient off and nothing opened there is no pane and 多多 takes the screen | the list and then the session replace the room in the upper half (no handle: they are being read, and ‹ leaves them). Back: ‹ or a swipe right |
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

The keyboard lifts the composer as usual: 多多 is at the bottom in every layout that types.

## Not in this round

- A hint to the brain that the reply will be read on a large display (tent, tabletop).
- Keeping the screen on in the tent or on the table: it follows the existing 保持屏幕常亮 setting.

## Prototype

A prototype with fixture data (not published) was used to choose these layouts in the iOS 27.1
iPhone Duo simulator. To see the real app in each posture:
`-PocketDemo sessions` (DEBUG) shows ambient speaking with a session list and rows.
