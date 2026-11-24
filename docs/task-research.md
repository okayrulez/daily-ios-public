# Daily tasks and web research

The Daily button now classifies explicit user requests before ordinary journal analysis. Normal diary input retains the original pipeline. Task requests can ask up to five necessary clarification questions, then continue from saved answers on the next press. Writing/planning requests produce a complete reply; research requests enable hosted Responses web_search. Completed unchanged tasks reuse the saved result. Edit the request to request a new research pass. Blocked tasks can be retried.

The phone still orchestrates requests using the selected model and the user's ChatGPT OAuth session. No PC process, API key or external browser service is introduced. Web search is subject to model/account/workspace availability. This is not an Instagram authenticated browser: private, login-only or unindexed content may be inaccessible. A partial report must describe its limits; blocked access must not become invented findings. Posting, payments, local shell, arbitrary apps and account automation are not exposed.

Official references checked 2026-10-05:
- https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- https://developers.openai.com/api/docs/guides/tools-web-search

## Data and reliability

Task state lives in the journal's optional daily_task field. Full new reports are archived in individual note:dailyx/tasks/<journal-hash>/<job-id>.md records; journal history retains their references, round numbers and short previews. The current full task remains in daily_task for continuation. Earlier reports are fetched on demand after an authenticated owner check. Questions keep the existing question/history format. Output is committed using the existing owner/session gates, source and memory hash transaction, receipt and durable outbox. Task inference checkpoints are keyed by account, model, source, memory and prompt configuration. Failed/incomplete streams never commit; operations are preflighted against memory before inference output is cached.

Each research stage may return in_progress plus nextQueries. Its sources, report and map changes commit before the next stage begins. Each user press runs at most eight stages; an unfinished task then waits for another press. Backgrounding, cancellation or quota failure preserves earlier committed stages. Exact repeated findings stop automatic continuation. Stage numbers remain monotonic after blocked retries. There is no twenty-finding total cap: each stage supports up to sixty findings within the transport size budget. Existing 16 MB memory and Firestore transaction limits still apply.

## Firebase state and app operations

All fresh analysis commits now upload the full portable memory as immutable chunks and atomically switch the Firebase memory manifest to cloud storage. An existing device-only archive migrates on its next successful analysis from the phone containing that archive. Old outbox results remain recoverable. The authoritative agenda and graph preferences live inside that cloud memory, with a derived note:companion/agenda.json projection for the agenda screen and push worker. Editing that projection alone is not a supported way to change the canonical agenda.

The manage route executes structured app operations: agenda create/update/cancel/restore (whole series or named dates), map rename/move/correct/retract/restore/link/unlink. Operations must cite literal current user text or answers, use existing target IDs, and pass schema/target/occurrence validation before anything is committed. Whole-batch failure leaves the prior state intact. Map corrections and original source evidence are retained. Preferences survive later journal graph regeneration.

Agenda recurrence supports once/daily/weekly/monthly schedules, intervals, end dates, excluded dates and optional explicit reminders in Europe/Istanbul. Missing times produce all-day events without invented reminder times. The agenda shows the next ninety days; recurrence rules remain durable beyond that window. The push worker derives reminders from current Firebase rules and rechecks cancellation in its delivery transaction. Its heartbeat advertises agenda-v1. Until that worker is updated, the iPhone schedules available agenda reminders locally even when legacy remote notifications are enabled. Existing consent, quiet hours and daily notification limits apply.

Firebase stores state; it does not itself run a ChatGPT session. The current executor remains the foreground phone. A future background model worker needs a real runtime (Hostinger VPS, Cloud Run or Cloud Functions), supported provider authentication, owner-scoped job claims and the same validation/CAS rules. Firebase Hosting alone is not that executor. The existing push worker only delivers notifications; this change does not turn it into a model runner or deploy a server service.

Web findings require a completed web_search_call and provider url_citation annotations. Model-returned finding URLs must match these annotations. This proves source attribution, not the truth of every model conclusion. External research is labelled as AI research in the map and stored as a research source, never as a personal user quote. Research nodes are excluded from personal cross-map synthesis. Existing older apps may not import a memory backup containing the new research source kind.

## Remote instructions

Keep dailyXConfig/analysisPrompts unchanged for existing clients. New clients additionally read dailyXConfig/taskPrompts once per fresh run:
- schemaVersion: 1
- revision: short version label
- enabled: true (false restores bundled task guidance)
- instructions.routeTask and instructions.executeTask: strings, max 20 KB each

Seed template: config/task-prompts.json. Only administrators write this document; signed-in app clients may get it. Remote text changes behavior while the bundled tool/evidence/output constraints remain appended. It cannot add unimplemented tools or make unsupported provider tools available. Network/invalid configuration failures stop the run instead of silently using stale instructions.

## Validation

Run npm run verify for TypeScript, the actual iOS JavaScript bundle and task/diary regression tests. Run Firebase emulator tests for both standalone and shared production rules. New native tests cover research stream completion/citations, opt-in tools, reply rendering and remote prompt merging. Swift/Xcode and actual subscription web search require Codemagic/device validation; Windows cannot execute those tests.
