# Design notes

What the UI is made of, and why each number is what it is. This is the counterpart to the test
suite: the specs prove behaviour, lifetimes and frame cost; this file records the visual decisions
that a headless harness cannot check.

Nothing here was screenshotted from a running client. Treat it as the specification the code was
written against, not as evidence that it looks right.

## Surface

One window, one accent, flat fills. Depth comes from three values and a 1 px border rather than from
shadows or gradients, because a hub sits on top of a game that is already busy.

```
Background        16, 16, 20     the game shows through; the hub never owns a full-screen backdrop
WindowBackground  18, 18, 24
Panel             24, 24, 30     a card
PanelSecondary    29, 29, 38     a nested surface, a tooltip
Field             31, 31, 38     an input well, a switch track at rest
Chip              33, 33, 40     a keybind chip, a tab pill
Hover             36, 36, 46
Selection         40, 40, 52     the *selected* row, not the hovered one
BorderPrimary     37, 37, 48
BorderSecondary   48, 48, 59
TextPrimary      231, 231, 237
TextSecondary    153, 153, 168
TextMuted        104, 104, 120
Accent           255, 79, 104    the only saturated colour on screen
```

The steps between `Panel` (24) and `Selection` (40) are deliberately small: a control announces
itself with the accent, not by jumping in brightness. Selected states get a flat fill; nothing uses
a bold weight, and nothing uses a placeholder graphic.

Roles, not hex: `AccentSoft` is the *filled* side of a switch, `Accent` its stroke and knob, so a
toggle reads as one motion of colour and position rather than two unrelated events. A theme swap
rebinds every instance that asked for a role, which is why no component stores a colour.

## Structure

```
header  72 px   icon · title/subtitle · search cluster · minimise · close
nav     52 px   horizontal icon pills, in a scrolling frame so nine tabs still reach
content         two columns, 16 px apart, 18 px padding
footer  40 px   status line left, version right
```

Horizontal tabs rather than a left sidebar: a hub is usually a dozen controls across four sections,
and a sidebar spends the widest axis on the shortest list. Pills are icon-plus-label inside a
`ScrollingFrame` with a real `UIListLayout`, which is the difference between a strip that scrolls and
one whose ninth tab cannot be clicked.

Rows are full width with the label on the left and the control on the right (`Element.row`), 30 px
tall, plus 12 px when the row carries a description. Every component builds through that helper, so
the alignment of a slider cannot drift from the alignment of a toggle. The hit area is the whole row,
not the 42 px switch — on a phone the small version is unusable.

Cards (`GroupBox`) are the only containers, are collapsible by default, and carry their own chevron.
Their search behaviour is the one visible piece of logic here: a card that matches through its own
title or description opens *with* its rows, because an empty panel under the word the user typed
reads as a broken filter.

## Motion

Hand-interpolated on one `RenderStepped` loop that only exists while something is moving:

| Event | Duration | Curve |
| --- | --- | --- |
| row hover in | 0.12 s | `outQuad` |
| press | 0.08 s | `outQuad` |
| hover out / restore | 0.12 s | `outQuad` |
| button squash on press | 0.06 s down, 0.10 s back | `outQuad` |
| switch knob | 0.16 s | `outQuad` |
| progress fill | 0.25 s | `outQuint` |
| toast in | 0.16 s | `outQuad` |
| toast out | 0.12 s | `outQuad` |
| page fade on tab open | 0.18 s | `FadeIn` preset |
| window open | 0.22 s | `PopIn` preset |

Collapsing a card is not animated: the chevron's rotation is set and the row host is hidden, and the
panel's automatic height does the rest. A tween there would need the card's expanded height, which is
exactly the bookkeeping that goes out of sync when a row is added while the card is closed.

Two rules: a value that is already set when a row is first built is painted, not animated (an
entrance tween on a switch that was already on looks like the hub turning features on by itself);
and reduced motion multiplies the clock instead of removing tweens, so the resting state is always
reached and never left mid-fade.

## Typography

Gotham for everything, `Code` for numeric readouts. Window title 17, subtitle 12, row label 13, hint
11, search field 13, footer 11, toast title 14, toast body 13. A label that needs more room is
wrapped and given height — text is never truncated to keep a row tidy, because the row is the thing
the user has to read.

## Radius and stroke

12 window · 10 panel · 8 field · 6 chip · 24 pill, with a 1 px stroke on cards and fields. The stroke
exists because a flat dark panel on a flat dark window has no edge at all; it is `BorderPrimary` at
rest and `Accent` when the control it outlines is active.
