---
version: 1
slug: "apps-flutter-app-lib-features-tasks-task-page-dart"
primary_target: "apps/flutter_app/lib/features/tasks/task_page.dart"
related_targets: ["apps/flutter_app/lib/features/boards/board_page.dart","apps/flutter_app/lib/features/boards/home_page.dart","apps/flutter_app/lib/features/auth/login_page.dart","apps/flutter_app/lib/features/agents/workers.dart"]
---

# AI Kanban app (whole Flutter app)

Scope: every app screen (sign-in, workspaces, board, task with refinement and GitHub, workers). Mode: Operate. Replacement world for the earlier Furrow ruled-ledger theme.

Audience and job: a solo developer first (small team next) who captures short tasks, often on a phone, then reviews at a desk what the agent found. The task that matters most is reviewing a spec's evidence and approving it into one GitHub issue.

Constraints: keep every string, route, handler, key and test finder; do not edit tests. Light and dark both ship (system setting). Native controls only.

## Direction contract

THESIS: The spec is a standards document. Each screen reads like an Internet-Draft put to work: a header block that states what this is and at which commit, plain numbered references to the code, and one normative colour for the one act that matters. Refuses the grey issue tracker with an indigo accent, and the warm-paper ledger it replaces.

OWN-WORLD: White paper (#FFFFFF), ink #1A1A1A, warm grey rules #E9E7E3 and a #FAF9F7 side field; normative red #9A2A1F reserved for the primary action, the literal MUST/SHOULD/MAY words the agent wrote, and failures that need you; quiet green only for verified/approved/CI pass. Source Sans 3 for UI and prose, Source Code Pro for header blocks, paths, line ranges, commits and run lines. Square-ish 6px controls, hairline rules, no shadows, no cards in cards.

STORY: The visitor sees at a glance what the spec is, which repository and commit it stands on, how ready it is, and what the agent read; checks the [E1]-style evidence references; approves with one red button, knowing it files one GitHub issue.

FIRST VIEWPORT: Task page, desktop: a 56px app bar with back and "board · owner/repo" (Workers stays where the product puts it: home, and the waiting-run line); left a spec column (~900px measure) with the title and column tag, the brief, then the mono header block between a 2px ink rule and a 1px ink rule (left: Repository and the tested run line "Version N · commit · refiner on worker"; right: Status, Readiness N%), then Summary, Requirements, Acceptance criteria, Open questions, Approach, Evidence as an [E1] reference list with verified/unverified marks; a bar pinned under the column carries Approve spec (red, primary) and Refine again; a 360px #FAF9F7 activity rail on the right, newest first, with a solid ink dot on the latest event. Board, home and workers share the bar, the rules and the header-block move (the board's header block names the repository and refinement counts).

FORM: Internet-Draft / IETF RFC standards document, position 1 on the ordered list (chosen as IMPECCABLE'S PICK over the assigned Munich '72 programme). seed:9edb3df007981102. Translations from the sketch: criteria carry no [E] citations (the data does not link them); normative keywords are highlighted only where the agent wrote them; no section numbers.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Unresolved

- Board retry on load error, empty board and empty column prompts (carried over from the last review).
