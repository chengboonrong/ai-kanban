---
version: 1
slug: "apps-flutter-app-lib-features-tasks-task-page-dart"
primary_target: "apps/flutter_app/lib/features/tasks/task_page.dart"
related_targets: ["apps/flutter_app/lib/features/boards/board_page.dart","apps/flutter_app/lib/features/boards/home_page.dart","apps/flutter_app/lib/features/auth/login_page.dart","apps/flutter_app/lib/features/agents/workers.dart"]
---

# AI Kanban app (whole Flutter app)

Scope: every app screen (sign-in, workspaces, board, task with refinement and GitHub, workers). Mode: Operate. Replacement world for the Internet-Draft theme (commit 0b0bb9d), which the user found too full of text.

Audience and job: a solo developer first (small team next) who captures short tasks, often on a phone, then reviews at a desk what the agent found. The task that matters most is reviewing a spec's evidence and approving it into one GitHub issue.

User answers (2026-11-19): replace the world fully; animated icons replace text labels and metadata and animate only where something is live (run streaming, worker online/busy, verifying, CI, waiting), still elsewhere; spec prose stays readable text with icons, chips and visuals around it; icons come from an open-source set (at most one new package).

Constraints: keep every string, route, handler, key and test finder; do not edit tests. Light and dark both ship (system setting). Native controls only. Respect reduced motion: loops stop, one-shots jump to their end.

## Direction contract

THESIS: Every worker and run is a small instrument. State lives in colour-coded round keys and in a black screen strip where line-art glyphs animate while something is happening; words drop to tiny lowercase labels. Refuses the dark issue tracker with an indigo accent, and the text-heavy standards document it replaces.

OWN-WORLD: Light anodized shell #E6E6E3 with a #DADAD6 side field and #CFCFCB seams; ink #1C1C1E; black screen #111214 with #E9E9E6 glyphs. Keys: orange #FF5A1F reserved for live or awaiting-you (the run, Approve), blue #2F6BFF for evidence and reading, green #18C36B for online/verified/pass, grey #9AA0A6 for idle. Dark edition: graphite shell, same keys. Manrope for UI and prose (800 for titles), JetBrains Mono only for data (commits, paths, counts). Pill buttons and round keys, 14px screen radius, no shadows.

STORY: The visitor sees the run's state as moving glyphs before reading a word, follows the lifecycle strip to "spec ready", reads plain prose with MUST/SHOULD as dark key-caps, checks evidence dots, and presses the orange Approve key knowing it files one GitHub issue.

FIRST VIEWPORT: Task page, desktop: 56px bar with a round back key, board name and mono repo, a green worker key at right. Spec column (900px): 30px/800 title, muted brief, then the black screen strip of four cells (run with spinning arc, readiness dial, evidence count, refiner on worker), then the lifecycle strip (queued, claimed, reading, spec ready, approved) at one glyph scale on one baseline, then sections headed by small colour keys, evidence rows with status dots. Bar pinned below: orange pill Approve spec, outline Refine again. Right 360px side field: activity as rows of coloured rounded-square glyph keys.

FORM: Pocket synthesizer and sampler product graphics, position 3 on the ordered list. seed:f4ea8bf355756e09. Raises: lifecycle strip at one fixed glyph scale (from Botanical Folio); run details revealed on card focus, the rest quiet (from Streaming Wall); orange reserved for what is live or awaiting you (from Orienteering Map); one motion grammar, 400ms with one small overshoot (from Zoo Guide Map).

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Unresolved

- Animated icon set choice (research running).
- Board retry on load error, empty board and empty column prompts (carried over).
