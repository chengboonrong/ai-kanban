---
name: AI Kanban
description: A pocket synth for specs. Every worker and run is a small instrument whose state lives in coloured keys and a black screen.
colors:
  shell: "#E6E6E3"
  sheet: "#F4F4F2"
  side-field: "#DADAD6"
  seam: "#CFCFCB"
  ink: "#1C1C1E"
  ink-secondary: "#34363A"
  muted: "#5A5E63"
  live-orange: "#FF5A1F"
  live-orange-ink: "#1C1C1E"
  live-orange-soft: "#FFD9C9"
  verified-green: "#0E7A42"
  verified-green-soft: "#CDEBD9"
  danger-red: "#C92A2A"
  evidence-blue: "#2F6BFF"
  evidence-blue-soft: "#D5E1FF"
  idle-grey: "#9AA0A6"
  screen: "#111214"
  screen-ink: "#E9E9E6"
  screen-muted: "#8A8F95"
  screen-green: "#2FD27C"
  screen-orange: "#FF6A33"
  screen-blue: "#6E97FF"
  shell-dark: "#26272B"
  sheet-dark: "#303135"
  side-field-dark: "#202124"
  seam-dark: "#3C3E43"
  ink-dark: "#ECECEA"
  ink-secondary-dark: "#D2D3D0"
  muted-dark: "#A3A7AD"
  live-orange-dark: "#FF6A33"
  live-orange-ink-dark: "#151617"
  live-orange-soft-dark: "#4A2414"
  verified-green-dark: "#2FD27C"
  verified-green-soft-dark: "#173A26"
  danger-red-dark: "#FF6B6B"
  evidence-blue-dark: "#6E97FF"
  evidence-blue-soft-dark: "#1E2A4A"
  idle-grey-dark: "#6B7076"
  screen-dark: "#0B0C0D"
typography:
  display:
    fontFamily: "Manrope, sans-serif"
    fontSize: "30px"
    fontWeight: 800
    lineHeight: 1.2
    letterSpacing: "-0.4px"
  headline:
    fontFamily: "Manrope, sans-serif"
    fontSize: "24px"
    fontWeight: 800
    lineHeight: 1.25
    letterSpacing: "-0.3px"
  title:
    fontFamily: "Manrope, sans-serif"
    fontSize: "20px"
    fontWeight: 800
    lineHeight: 1.3
    letterSpacing: "-0.2px"
  title-small:
    fontFamily: "Manrope, sans-serif"
    fontSize: "16px"
    fontWeight: 800
    lineHeight: 1.35
  body-large:
    fontFamily: "Manrope, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.55
  body:
    fontFamily: "Manrope, sans-serif"
    fontSize: "14.5px"
    fontWeight: 400
    lineHeight: 1.5
  body-small:
    fontFamily: "Manrope, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.45
  label:
    fontFamily: "Manrope, sans-serif"
    fontSize: "14.5px"
    fontWeight: 800
    lineHeight: 1.2
  label-medium:
    fontFamily: "Manrope, sans-serif"
    fontSize: "13px"
    fontWeight: 600
    lineHeight: 1.2
  label-small:
    fontFamily: "Manrope, sans-serif"
    fontSize: "12px"
    fontWeight: 600
    lineHeight: 1.2
  mono:
    fontFamily: "JetBrains Mono, monospace"
    fontWeight: 400
    fontFeature: "tnum"
rounded:
  keycap: "4px"
  control: "10px"
  card: "12px"
  screen: "14px"
  pill: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
  2xl: "24px"
  3xl: "48px"
components:
  button-ink:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.sheet}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "0 20px"
    height: "42px"
  button-live:
    backgroundColor: "{colors.live-orange}"
    textColor: "{colors.live-orange-ink}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "0 20px"
    height: "42px"
  button-outline:
    backgroundColor: "{colors.sheet}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "0 20px"
    height: "42px"
  button-danger:
    backgroundColor: "{colors.danger-red}"
    textColor: "{colors.sheet}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "0 20px"
    height: "42px"
  input:
    backgroundColor: "{colors.sheet}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "13px 14px"
  card:
    backgroundColor: "{colors.sheet}"
    rounded: "{rounded.card}"
  screen-strip:
    backgroundColor: "{colors.screen}"
    textColor: "{colors.screen-ink}"
    rounded: "{rounded.screen}"
    padding: "16px 20px"
  glyph-key:
    backgroundColor: "{colors.verified-green}"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    size: "32px"
  keycap:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.sheet}"
    typography: "{typography.mono}"
    rounded: "{rounded.keycap}"
    padding: "1px 5px"
  status-pill-ready:
    backgroundColor: "{colors.live-orange}"
    textColor: "{colors.live-orange-ink}"
    typography: "{typography.label-medium}"
    rounded: "{rounded.pill}"
    padding: "3px 10px 3px 6px"
---

# Design System: AI Kanban

## Overview

**Creative North Star: "The Pocket Synth"**

Every worker and every refinement run is a small instrument. The app is a light anodized shell (graphite in the dark edition) carrying round colour keys and, where something is live or worth a glance, one black screen strip on which Lucide line glyphs sit over tiny lowercase labels and mono readouts. State is read first as colour and motion, then as words; words drop to the smallest size that still reads.

The shell is flat and quiet. Depth comes from three neutral fields (shell, sheet, side field) separated by one-pixel seams, never from shadow. Prose (briefs, spec sections) stays plain readable Manrope at a 680px measure, with the agent's RFC 2119 keywords set as dark key-caps. Orange is scarce on purpose: it marks only what is running right now or waiting on the person.

Motion has one grammar. Glyphs are still by default, loop only while work runs, play once when a state arrives, and freeze entirely under reduced motion. Light and dark both ship and follow the system setting.

**Key Characteristics:**
- Neutral anodized shell, three tonal fields, hairline seams, no shadows, gradients or glass.
- Colour-coded round keys: orange live, green online/verified, blue evidence, grey idle.
- At most one black screen strip per screen, for live or summary state only.
- Lucide line glyphs as the only icon language, animated only while something is live.
- Manrope 800 for hierarchy, JetBrains Mono for data only.
- Pill buttons, round keys, 10/12/14px rectangles.

## Colors

A neutral grey shell with four functional key colours and a black instrument screen; the screen has its own brighter key set so glyphs read on black.

### Primary
- **Live Orange** (live-orange; dark: live-orange-dark): the running refinement (spinning run arc, current lifecycle stage), the "Spec ready for review" pill on a card, the board strip's ready-for-review glyph when the count is above zero, a busy worker's key, and the Approve spec button. Text and glyphs on it use Live Orange Ink, which is near-black in both themes. Live Orange Soft is the text-selection highlight.
- **Screen Orange** (screen-orange): the same role drawn on the black screen.

### Secondary
- **Verified Green** (verified-green; screen-green on the screen): worker online, evidence verified, spec approved, CI passing, readiness dial.
- **Evidence Blue** (evidence-blue; screen-blue on the screen): evidence and reading: the evidence cell, evidence section keys, reading activity.

### Tertiary
- **Danger Red** (danger-red): failed states and every destructive confirm (the confirm dialog's filled button is red).
- **Idle Grey** (idle-grey): a key at rest (offline worker, sign-in key).

### Neutral
- **Anodized Shell** (shell): page ground, app bar, pinned action bar.
- **Sheet** (sheet): fields, cards, dialogs, menus, outline-button fill; also the text colour on ink fills.
- **Side Field** (side-field): board lanes, the task page's 360px activity rail, chips, disabled fills.
- **Seam** (seam): every one-pixel border and divider.
- **Ink / Ink Secondary / Muted** (ink, ink-secondary, muted): primary text and ink buttons; icons; secondary text, labels and timestamps.
- **Screen / Screen Ink / Screen Muted** (screen, screen-ink, screen-muted): the black strip, its readouts and its tiny labels and idle glyphs. Tooltips and snackbars use the same screen.

### Named Rules
**The Orange Means Now Rule.** Orange appears only on something live or awaiting the person: the running refinement, "Spec ready for review", and Approve spec. Starting work is not live: "Refine with AI" is an ink button and "Refine again" is an outline button.

**The Key Colour Is The State Rule.** A key's colour carries its state; its glyph names the thing. Never encode the same state in a second colour on the same element.

## Typography

**Display Font:** Manrope (self-hosted, 400/600/800, OFL)
**Body Font:** Manrope
**Label/Mono Font:** JetBrains Mono (self-hosted, 400/600, OFL), with tabular figures

**Character:** One geometric sans carries everything; hierarchy comes from size and the 800 weight, with slight negative tracking on the large sizes. Mono is the instrument readout, reserved for machine facts.

### Hierarchy
- **Display** (800, 30px, 1.2, -0.4px): the task title.
- **Headline** (800, 24-28px, 1.2-1.25): page titles.
- **Title** (800, 20px, 1.3): dialog titles; **Title small** (800, 16px): app bar title, section headings beside a colour key, "Activity".
- **Body large** (400, 16px, 1.55): spec prose, at a 680px max measure.
- **Body** (400, 14.5px, 1.5): UI text, inputs, list rows; **Body small** (400, 13px, muted): secondary lines.
- **Label** (800, 14.5px): buttons; **Label medium** (600, 13px): chips, pills, tooltips; **Label small** (600, 12px, muted, lowercase copy): screen-cell labels and lifecycle stage names.
- **Mono** (JetBrains Mono, one pixel under the role it replaces, tabular): screen readouts (600, 15px), commits, paths, line ranges, counts, ids, dates, repo names, issue numbers.

### Named Rules
**The Mono Is Data Rule.** JetBrains Mono is for data only: commits, paths, counts, ids, dates. Never for headings, labels, buttons or prose. The one typographic exception is the key-cap, which sets the agent's own normative keyword as a token.

## Layout

The task page is the reference composition. At 1000px and wider (a landscape tablet included) it is a spec column (max 900px, prose at 680px) centred in the space beside a fixed 360px activity rail on the side field; below 1000px the rail stacks under the spec. Save and Delete sit on their own quiet row under the brief, so the title keeps the column's width. Spec actions sit in a bar pinned under the spec column; its top seam runs the full width beside the rail and its buttons line up with the column. The app bar is 56px with a round back key, a title and a mono repo name; it stays at the window edge as the board's navigation rather than following the centred column.

Home and Workers centre an 880px column with side padding that grows with the window; the app bar title (and Workers' back key) sit on the same inset once it is wider than the 56px back key (from 992px); narrower, the Workers title follows its back key. Board lanes share the window from 288px (then the board scrolls) up to 360px, or take 85% of the screen under 600px so the next lane peeks in. Spacing runs on 4/8/12/16/20/24/48; the screen strip uses 20px horizontal by 16px vertical padding, 28px between cells and 14px between rows. Prose rows separate with 8px vertical padding over a bottom seam. Every layout works at a 360px phone width.

## Elevation & Depth

Flat. Every Material elevation is 0 and surface tint is off. Depth is tonal: shell, sheet and side field differ by a few lightness steps, and a one-pixel seam outlines every sheet. Hover darkens a card's seam to ink; keyboard focus is a 2px ring (ink in light, near-white in dark). A dragged card is the same sheet with an ink seam, at full strength, and the slot it left is an empty seam outline.

### Named Rules
**The No-Lift Rule.** No shadows, gradients, glass or blur anywhere, including dragged cards, menus, dialogs and snackbars. If something needs to stand forward, it gets a seam or the black screen, not a shadow.

## Shapes

Two silhouettes: the round key and the pill. Status keys (worker, sign-in, home board) and lifecycle stages are circles; every button, chip and status pill is a stadium. Rectangles step up with their role: key-caps 4px, controls and fields 10px, cards 12px, the screen strip and dialogs 14px. Small heading and activity keys are rounded squares with a radius of 28% of their size. Line glyphs follow Lucide's 24-grid at stroke 2 (1.75 at 16px and under).

## Components

### Buttons
- **Shape:** pill (stadium), 42px minimum height, 20px horizontal padding, 18px glyph, Label type.
- **Ink (default filled):** ink fill, sheet text, ink border. "Refine with AI", dialog confirms, Save.
- **Live:** orange fill, near-black ink, orange border. Approve spec only.
- **Outline:** sheet fill, ink text, 1.5px ink border. "Refine again", "Cancel" on a run, "Connect".
- **Danger:** red fill, sheet text. The confirm dialog's destructive action.
- **Text / icon:** ink text, no fill; icon buttons are 40px circles in ink secondary.
- **Hover / Focus:** no splash; a 5% ink hover wash; focus is a 2px ring. 120ms state changes.

### Chips
- **Style:** side-field fill, no border, pill, Label medium.
- **Status pill:** the card's "Spec ready for review" is an orange pill with a 14px spec glyph that plays once on arrival.

### Cards / Containers
- **Corner Style:** 12px.
- **Background:** sheet on the side-field lane, in both themes.
- **Shadow Strategy:** none (see Elevation).
- **Border:** one-pixel seam; ink on hover; 2px focus ring alone on keyboard focus.
- **Behaviour:** at rest a card shows state as glyphs (spinning run arc while refining, the ready pill, the GitHub badge); the words behind a glyph-only state come up on hover or focus. Touch devices long-press to drag.

### Inputs / Fields
- **Style:** sheet fill, one-pixel seam, 10px radius, 13px/14px padding, muted labels and hints.
- **Focus:** 2px focus-colour border.
- **Error / Disabled:** red border (2px when focused); disabled seam at 55% alpha.

### Navigation
- **App bar:** shell background, bottom seam, no elevation, 56px, Title small. The back button is the same glyph key on every route. Route changes are a 200ms fade, none under reduced motion.

### Glyph Key
A round synth key: a coloured disc carrying one Lucide glyph at 56% of its diameter (32px default, 28px in the task bar). The colour is the state. Square variants (18px headings, 26px activity rows) carry the glyph in sheet colour at 66%.

### Screen Strip
The black screen (14px radius, 20/16px padding) holding a wrap of cells. Each cell is a 26px glyph or a readiness dial, then a tiny lowercase label in screen muted over a mono 15px/600 value in screen ink. An optional footer line sits 14px under the cells on the same screen. On the task page the footer is the status readout: a 16px glyph, the status in its key colour ("Ready for review" orange, "Approved" green, "Being rewritten" muted), then version, commit and harness in mono.

### Lifecycle Strip
The run's stages (queued, claimed, reading, spec ready, approved) as 24px circles on one baseline joined by 2px lines: done stages are ink with a check, the current stage is orange (with the spinning arc while live), future stages are sheet with a seam. Stage names in Label small.

### Key-cap
RFC 2119 keywords the agent wrote (MUST, SHOULD, MAY, SHALL, REQUIRED and their NOT forms) render inline as dark key-caps: ink fill, sheet text, mono 600 at 80% of the prose size, 4px radius. The app adds none of its own.

### Glyph Motion
- **Still** is the default and covers every glyph that is not live.
- **Loop** only while work runs: refinement queued or running (the run arc spins once per 1400ms), outbox sending, CI running, waiting for a worker. Loops keep the glyph's own tempo.
- **Once** when a state arrives: worker online or busy, spec ready, approved, readiness reached. One beat: 400ms, ease-out-back (one small overshoot).
- **No hover animation.**
- **Reduced motion** freezes everything: loops stop, one-shots do not play, dials jump to value, route fades are removed.

## Do's and Don'ts

### Do:
- **Do** reserve orange for live or awaiting-you states: the running refinement, "Spec ready for review", and Approve spec.
- **Do** render "Refine with AI" as an ink button and "Refine again" as an outline button.
- **Do** keep glyphs still by default; loop only while work runs (refinement queued or running, outbox sending, CI running, waiting for a worker) and play once when a state arrives.
- **Do** freeze every glyph, dial and transition under reduced motion.
- **Do** use at most one black screen strip per screen, and only when it carries live or summary state. On home it appears once your workers have loaded (how many are online), and when items are unsent or the app is offline; on the task page its footer is the status readout.
- **Do** set the agent's MUST/SHOULD keywords as dark key-caps (ink fill, sheet text, mono 600, 4px radius).
- **Do** use JetBrains Mono for data only: commits, paths, line ranges, counts, ids, dates.
- **Do** separate surfaces with the three neutral fields and one-pixel seams.
- **Do** name icons by job through the Glyph enum; screens never reference a library icon class.

### Don't:
- **Don't** use orange to start work, decorate, or mark focus on idle content.
- **Don't** add hover animation to glyphs.
- **Don't** put a second screen strip on a screen, or show one that carries only static decoration.
- **Don't** set headings, labels, buttons or prose in mono.
- **Don't** use shadows, gradients, glass or blur, including on dragged cards and overlays.
- **Don't** add colours, font families or radii outside the tokens in this file.

## Open Gaps

- The home strip has no specs-ready cell; counting ready specs across boards needs an API call that does not exist yet.
