---
name: AI Kanban
description: A kanban board whose specs read like Internet-Drafts, put to work.
colors:
  paper: "#FFFFFF"
  side-field: "#FAF9F7"
  rule: "#E9E7E3"
  ink: "#1A1A1A"
  ink-secondary: "#33312E"
  muted: "#5E5B56"
  normative-red: "#9A2A1F"
  normative-red-soft: "#F5E2DF"
  verified-green: "#2F6B3A"
  verified-green-soft: "#E4EFE5"
  paper-dark: "#151413"
  sheet-dark: "#221F1D"
  side-field-dark: "#1B1A18"
  rule-dark: "#34312D"
  ink-dark: "#ECEAE6"
  ink-secondary-dark: "#D6D3CE"
  muted-dark: "#A19D96"
  normative-red-dark: "#E5735F"
  normative-red-soft-dark: "#4A231D"
  verified-green-dark: "#85C291"
  verified-green-soft-dark: "#1D3322"
typography:
  display:
    fontFamily: "Source Sans 3, sans-serif"
    fontSize: "30px"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.3px"
  headline:
    fontFamily: "Source Sans 3, sans-serif"
    fontSize: "24px"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "-0.2px"
  title-large:
    fontFamily: "Source Sans 3, sans-serif"
    fontSize: "20px"
    fontWeight: 700
    lineHeight: 1.3
  title:
    fontFamily: "Source Sans 3, sans-serif"
    fontSize: "17px"
    fontWeight: 700
    lineHeight: 1.35
  title-small:
    fontFamily: "Source Sans 3, sans-serif"
    fontSize: "15px"
    fontWeight: 600
    lineHeight: 1.35
  body-large:
    fontFamily: "Source Sans 3, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.5
  body:
    fontFamily: "Source Sans 3, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.5
  body-small:
    fontFamily: "Source Sans 3, sans-serif"
    fontSize: "13.5px"
    fontWeight: 400
    lineHeight: 1.45
  label:
    fontFamily: "Source Sans 3, sans-serif"
    fontSize: "15px"
    fontWeight: 600
    lineHeight: 1.2
  label-medium:
    fontFamily: "Source Sans 3, sans-serif"
    fontSize: "13.5px"
    fontWeight: 600
    lineHeight: 1.2
  mono-header:
    fontFamily: "Source Code Pro, monospace"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.7
    fontFeature: "tnum"
  mono-reference:
    fontFamily: "Source Code Pro, monospace"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
    fontFeature: "tnum"
rounded:
  badge: "4px"
  control: "6px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
  page: "48px"
components:
  button-normative:
    backgroundColor: "{colors.normative-red}"
    textColor: "{colors.paper}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "0 18px"
    height: "40px"
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "0 18px"
    height: "40px"
  button-outlined:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "0 18px"
    height: "40px"
  button-text:
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "0 18px"
    height: "40px"
  input:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "12px"
  status-chip-good:
    backgroundColor: "{colors.verified-green-soft}"
    textColor: "{colors.verified-green}"
    typography: "{typography.label-medium}"
    rounded: "{rounded.badge}"
    padding: "0 6px"
  status-chip-bad:
    backgroundColor: "{colors.normative-red-soft}"
    textColor: "{colors.normative-red}"
    typography: "{typography.label-medium}"
    rounded: "{rounded.badge}"
    padding: "0 6px"
  status-chip-active:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    typography: "{typography.label-medium}"
    rounded: "{rounded.badge}"
    padding: "0 6px"
  task-row:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    typography: "{typography.title-small}"
    rounded: "{rounded.control}"
  lane:
    backgroundColor: "{colors.side-field}"
    rounded: "{rounded.control}"
    width: "288px"
  activity-rail:
    backgroundColor: "{colors.side-field}"
    width: "360px"
  app-bar:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    typography: "{typography.title-large}"
    height: "56px"
---

# Design System: AI Kanban

## Overview

**Creative North Star: "The Internet-Draft, Put to Work"**

Every screen reads like a standards document that is being used rather than archived. A screen opens by stating what it holds and what it stands on: a monospaced header block (repository, version, commit, status, readiness) set between a heavy ink rule and a light one. The prose below is plain, set in Source Sans 3 on white paper, separated by hairlines rather than boxes. References to code are written the way an RFC cites a reference: `[E1] path:12-40 verified`.

Colour is almost entirely absent. Ink and paper do the work; warm grey hairlines and a faintly warm side field set the structure. One red is normative: it marks the single act that matters on a screen (Approve spec, Refine with AI), the MUST/SHOULD/MAY words the agent itself wrote, and the failures that need you. One quiet green says verified, approved or passing, and nothing else.

The system refuses the grey issue tracker with an indigo accent, and the warm-paper "Furrow" ledger it replaced. Light and dark both ship and follow the system setting. Dark is a warm near-black sheet with the same rules, not an inverted page.

**Key Characteristics:**
- White paper, near-black ink, warm grey hairlines; colour is a signal, never decoration.
- A mono header block between a 2px and a 1px ink rule opens the task, board, home, sign-in and workers screens.
- One normative red per screen; one quiet green for verified states.
- Flat: no elevation at rest, no cards inside cards, 6px corners.
- Source Sans 3 for UI and prose, Source Code Pro for anything you would copy.

## Colors

An ink-on-paper palette with one normative red and one quiet green, each mirrored in a warm dark set.

### Primary
- **Normative Red** (normative-red; normative-red-dark in dark): the fill of the one normative button on a screen, the floating action button, the RFC 2119 keywords inside agent-written text, text selection handles, and destructive confirms and failure chips. Its soft tint (normative-red-soft) is the ground of a failure chip and the text selection colour.

### Secondary
- **Verified Green** (verified-green, with verified-green-soft as its ground): "verified" evidence marks, the Approved status, CI passing and approved-review chips. It never appears as a button or decoration.

### Neutral
- **Paper** (paper / paper-dark): page ground, app bar, the bar pinned under the spec, inputs and task rows. In dark, raised sheets (fields, dialogs, task rows on a lane) step up to sheet-dark.
- **Side Field** (side-field / side-field-dark): the activity rail, board lanes, the live run panel and code wells. The only tonal step; it sits beside the page, never inside a card.
- **Ink** (ink / ink-dark): all primary text, the default filled button, header-block rules, the solid newest-event dot, focus rings, tooltips and snackbars.
- **Ink Secondary** (ink-secondary): icon buttons, run-event lines, evidence notes.
- **Muted** (muted / muted-dark): the brief under a title, hints, labels, timestamps, unverified marks, hollow timeline dots.
- **Rule** (rule / rule-dark): every hairline: app bar underline, row separators, input borders at rest, card borders, skeleton bars.

### Named Rules
**The One Normative Act Rule.** A screen carries at most one red-filled button, and it is the act the screen exists for. Everything else is ink, outlined, or text.

**The Agent Wrote It Rule.** Normative keywords are coloured only where the agent's own text contains them (`MUST NOT`, `SHALL NOT`, `SHOULD NOT`, `MUST`, `SHALL`, `SHOULD`, `MAY`, `REQUIRED`). The UI never adds a keyword of its own to borrow the red.

**The Green Means Checked Rule.** Green appears only for something verified, approved or passing.

## Typography

**Body Font:** Source Sans 3 (bundled, OFL; Regular, Semibold, Bold)
**Mono Font:** Source Code Pro (bundled, OFL; Regular, Semibold), always with tabular figures

**Character:** A plain, legible humanist sans for everything you read, and a technical mono for everything you would copy: repository names, commits, line ranges, ids, dates, counts and run lines. Hierarchy comes from size and weight, never from colour or case.

### Hierarchy
- **Display** (700, 30px, 1.2, -0.3px): the editable task title at desktop width.
- **Headline** (700, 24px, 1.25): the task title on phones (under 600px). A 28px bold step exists in the theme and is used, in mono, for the worker pairing code.
- **Title Large** (700, 20px, 1.3): app bar titles, the spec's own title, dialog titles.
- **Title** (700, 17px, 1.35): spec section headings (Summary, Requirements, Evidence in the repository) and the Activity heading. Sentence case, unnumbered.
- **Title Small** (600, 15px, 1.35): task row titles and column names.
- **Body Large** (400, 16px, 1.5): spec prose, held to a 680px measure inside the spec column.
- **Body** (400, 15px, 1.5): default UI text, list tiles, inputs, dialogs.
- **Body Small** (400, 13.5px, 1.45, muted): secondary lines, retry notes, expiry notes.
- **Label** (600, 15px / 13.5px / 12.5px): buttons, chips and the column tag.
- **Mono** (Source Code Pro, one pixel smaller than the style it replaces, tabular figures): header block lines at 12.5-13px with 1.7 line height; evidence references at 14px.

### Named Rules
**The Copyable Is Mono Rule.** If a reader might paste it into a terminal or a search box (a path, a commit, a line range, a timestamp, a count), it is set in Source Code Pro with tabular figures. Prose and labels never are.

**The Small Caps Keyword Rule.** Normative keywords render in normative red, bold, with the `c2sc` small-caps feature and 0.6px tracking, as the RFC 2119 convention asks. No other text uses small caps, uppercase or tracking.

## Layout

The task page at 1100px and wider is a spec column (max 900px, 48px side padding, 32px top) beside a 360px side-field activity rail. Below 1100px the rail drops away and padding falls to 16px (24px top). Inside the column, prose keeps a 680px measure, so the header block and hairlines run wider than the text. A bar pinned under the column carries the spec actions on a paper ground above a hairline.

The board is a horizontally scrolling run of lanes, 288px wide (85% of the viewport under 600px), 16px apart, 16px from the edge, under a full-width header block. Sign-in caps at 420px and the workers screen at 480px. The app bar is 56px tall with a hairline under it.

Spacing steps through 4, 8, 12, 16, 24 and 48px. List rows are 6px vertical with a hairline between them; spec section headings sit 22px above their first row.

**The Header Block Rule.** A screen that has a subject opens with a HeaderBlock: mono lines, 8px vertical padding, a 2px ink rule above and a 1px ink rule below. On the spec it splits into a left column (Repository; Version · commit · refiner on worker) and a right-aligned column (Status, Readiness, Evidence), and stacks below 560px.

## Elevation & Depth

Flat. Every surface sits at elevation 0, tint-free; depth comes from the side-field tone and from hairlines. Shadows appear only while something is held in the hand.

### Shadow Vocabulary
- **Card in hand** (`box-shadow: 0 6px 16px rgba(26,26,26,0.18)`): the task row being dragged on the board.
- **Lane in hand** (Material elevation 3, shadow ink at 25%): a board column being reordered.

**The Only Lifted Thing Rule.** Nothing casts a shadow at rest. A shadow means "you are moving this", and disappears when it drops.

## Shapes

Square-ish and quiet. Controls, cards, task rows, lanes, dialogs and menus use a 6px radius. Status chips, the column tag and tooltips use a tighter 4px. Borders are 1px hairlines in the rule colour; ink borders are kept for outlined buttons, the column tag, hovered task rows and the header block. Timeline dots are 11px circles with a 1.5px border: solid ink for the newest event, hollow (filled with the ground colour) for the rest, threaded on a hairline.

## Components

### Buttons
Restrained and square-shouldered; the colour of the fill is the only hierarchy.
- **Shape:** 6px radius, 40px tall, 18px horizontal padding, label type (600, 15px), no elevation, no splash.
- **Normative:** normative-red fill with paper text. Only for the one act of the screen (Approve spec, Refine with AI). Focus draws a 2px ink border.
- **Primary (default filled):** ink fill with paper text, 1px ink border. Focus draws a 2px normative-red border. Disabled is side-field with muted text.
- **Outlined:** paper ground, ink text, 1px ink border (Refine again). Focus is a 2px ink ring.
- **Text:** ink text, no border at rest, 2px focus ring (Save, Delete, Cancel).
- **Destructive confirm:** the danger fill inside a confirm dialog, the one red a confirm may carry.
- **Hover / Focus:** hover is a 5% ink wash; transitions run 120ms.

### Chips
- **StatusChip:** 4px radius, label-medium, compact. Tones: neutral (ink text, ink outline), quiet (muted text, rule outline), active (ink fill, paper text: Running, Spec ready for review), good (green on green-soft), bad (red on red-soft).
- **Column tag:** a 28px text button with an ink border and an expand chevron next to the task title; it moves the task between columns.

### Cards / Containers
- **Corner Style:** 6px.
- **Background:** paper (sheet-dark in dark) with a 1px rule border, elevation 0.
- **Task row:** a paper sheet on the side-field lane; the border turns ink on hover and becomes the 2px focus ring on keyboard focus. While dragged it leaves an empty hairline outline of the same size.
- **Live run panel:** side-field, 6px, 16px padding, a 2px ink progress line on a rule track, then mono run events separated by hairlines.

### Inputs / Fields
- **Style:** filled paper, 1px rule border, 6px radius, 12px padding, dense. The floating label renders at 12px in muted semibold.
- **Focus:** the border becomes a 2px ink ring.
- **Error / Disabled:** a danger border (2px when focused); disabled borders fade to 55%.
- **In-place fields:** the task title and brief are borderless at rest on the paper ground and show the focus ring only when edited.

### Navigation
- **App bar:** 56px, paper, flat, a hairline underneath, a back chevron and a title-large title, followed on the task page by a muted mono "· owner/repo". Icon buttons are 40px in ink-secondary.
- **Routes:** a 200ms ease-out fade; none when the OS asks for reduced motion.

### Spec View (signature)
The header block, then the spec title, Summary, Requirements, Acceptance criteria, Open questions and a numbered Suggested approach as plain hairline-separated rows (bullets, or numbers for the approach), and finally "Evidence in the repository": each entry is `[En]`, `path:start-end` and a mark in mono, with the agent's note beneath. A verified mark is green; an unverified one is muted with a dashed underline and a tooltip that explains it. Sections are unnumbered.

### Activity Rail (signature)
A 360px side-field column, newest event first, on a hairline timeline. The newest dot is solid ink; earlier dots are hollow. Each event has a body line and a mono timestamp.

## Do's and Don'ts

### Do:
- **Do** open every screen that has a subject with the HeaderBlock: mono lines between a 2px ink rule and a 1px ink rule.
- **Do** keep one normative-red fill per screen, on the act the screen exists for; give every other action ink, an outline or plain text.
- **Do** set paths, commits, line ranges, ids, dates and counts in Source Code Pro with tabular figures.
- **Do** separate rows with 1px rule-colour hairlines instead of boxing them.
- **Do** use the side field for things that sit beside the page (rail, lanes, run panel) and paper for things on it.
- **Do** read colours and faces through the theme tokens; no literal Color or font family outside the theme file.

### Don't:
- **Don't** colour a keyword the agent did not write, or use the normative red for decoration, links or emphasis.
- **Don't** use green for anything except verified, approved or passing.
- **Don't** cast a shadow at rest or nest a card inside a card.
- **Don't** add section numbers, uppercase labels or tracked type; small caps belong only to normative keywords.
- **Don't** bring back the indigo-accented grey tracker look or the warm-paper ledger this replaced.
