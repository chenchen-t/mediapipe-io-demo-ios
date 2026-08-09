# MediaPipe IO Demo — iOS

An iOS SwiftUI app demonstrating MediaPipe's on-device GenAI tasks across a smart-notepad concept
spanning four sections — Chats, Archive, Email, and Stickers. Built on the real
`MediaPipeTasksText` and `MediaPipeTasksVision` CocoaPods, not placeholders: **Text Embedder**
(EmbeddingGemma-300m) powers semantic search everywhere, **Interactive Segmenter** powers the
Stickers editor, and **Text Summarizer** / **Text Proofreader** power the Summarize and Proofread
actions in Chats/Archive/Email.


## Demo

Recorded on the iOS Simulator via a real XCUITest driving each flow end to end (see
`MediaPipeIODemoUITests/DemoUITests.swift`) — not staged screenshots. Archive/Email clips are
sped up to keep them short; the model calls themselves run at real speed.

| Semantic search over chat history | Summarize a document | Proofread an email | Generate a sticker |
| --- | --- | --- | --- |
| ![Tapping a suggestion chip to semantically search chat threads, ranked by similarity](docs/media/chats_search.gif) | ![Summarizing a PDF page in Archive](docs/media/archive_summarize.gif) | ![Proofreading an email with an inline diff](docs/media/email_proofread.gif) | ![Drawing a stroke to cut out a sticker](docs/media/sticker_generator.gif) |

## Setup

```
sh RunScripts/download_models.sh   # fetches the 4 model bundles (~450MB total)
xcodegen generate                  # generates MediaPipeIODemo.xcodeproj from project.yml
pod install                        # installs MediaPipeTasksText, produces the .xcworkspace
open MediaPipeIODemo.xcworkspace
```

`download_models.sh` fetches all four models — `summarization_quant_200m_2modes.litertlm` (Text
Summarizer), `proofread_quant_200m.litertlm` (Text Proofreader), `embedding_gemma.task` (Text
Embedder), and `interactive_segmentation.task` (Interactive Segmenter) — into
`MediaPipeIODemo/Resources/Models/`.

Then build & run the `MediaPipeIODemo` scheme. Requires Xcode 16+, iOS 17 deployment target.
`xcodegen` and `cocoapods` are both installable via Homebrew (`brew install xcodegen cocoapods`).

**Re-run `pod install` after every `xcodegen generate`** — regenerating the project from
`project.yml` doesn't preserve CocoaPods' integration, so the two steps have to happen in that
order every time the project is regenerated.

## What each section does

- **Chats** — a message-thread inbox. The top-level search bar does semantic search across all
  threads; open a thread and its own search bar searches within just that conversation. A
  "History Summarizer" panel (TL;DR / Keypoints) summarizes the whole thread on demand. Each row
  and message bubble shows an embedded/not-embedded status badge, and there's a "Re-embed" action
  (per-thread, and "Re-embed all" on the list) with a live progress bar showing count and
  items/sec.
- **Archive** — a grid of PDF documents. At first launch, each bundled PDF's first two pages are
  text-extracted (via PDFKit's real text layer, not OCR) and embedded, powering archive-wide
  search. Open a document, switch to "Select Page" mode and tap any page to select it, then
  summarize just that page (or drag-select a specific passage in "Select" mode instead). Tap
  **Import** to pull in a PDF from anywhere the Files app can reach — including
  a Mac's Desktop, if iCloud Drive desktop sync is on — which gets copied into the app's own
  storage and indexed the same way bundled documents are.
- **Email** — an inbox with the same semantic search pattern. Each email supports Summarize
  (TL;DR / Keypoints / Raw Text) and Proofread — the sample emails contain real grammar mistakes
  on purpose, so Proofread has something to fix; the result renders as an inline diff.
- **Stickers** — take a photo or pick one from the library, then draw positive (keep) and negative
  (discard) strokes; each completed stroke re-runs `InteractiveSegmenter` and updates a live mask
  preview. Save trims the result to the positive region's bounding box and writes a transparent-
  background PNG to a cached gallery. Uses the GPU delegate on real devices; falls back to CPU in
  Simulator, where MediaPipe's GPU/Metal texture-cache path isn't reliable.

## Architecture

```
MediaPipeIODemo/
  App/            AppContainer (composition root) + the @main App entry point
  Models/         SwiftData @Model types: ChatThread, ChatMessage, EmailItem, ArchiveDocument,
                  EmbeddingRecord, Sticker
  ML/             TextSummarizerEngine / TextProofreaderEngine / TextEmbedderEngine /
                  InteractiveSegmenterEngine protocols + their real MediaPipeTasksText- and
                  MediaPipeTasksVision-backed actor implementations
  Search/         EmbeddingScope, SemanticSearchService (actor), VectorIndex (cosine similarity)
  Data/
    Local         (SwiftData handles persistence directly via the Models — no separate DAO layer)
    Storage/      PdfTextExtractor + PdfPageRenderer (PDFKit), DocumentImporter, DocumentLocator,
                  StickerCutout (mask compositing/trim), StickerLocator
    Repository/   ChatRepository, EmailRepository, ArchiveRepository, StickerRepository — one per
                  section, @MainActor
    Seed/         DemoDataSeeder — sample chats/emails/PDFs + the "initialization stage" scan
  UI/
    Chats/        List + thread detail screens (chat bubbles with tails, timestamps, grouping)
    Archive/      Grid + document viewer screens
    Email/        List + detail screens
    Sticker/      Gallery + editor screens (camera/photo input, stroke drawing, mask preview)
    Components/   SemanticSearchBar, SummarizerPanel, ProofreaderPanel, WordDiff, EmbeddingStatus
    Navigation/   RootTabView
  Util/           Date/time formatting
  Resources/      SampleArchive/*.pdf, Models/*.litertlm|*.task (gitignored), Assets.xcassets
MediaPipeIODemoTests/
  WordDiffTests.swift, VectorIndexTests.swift — pure-Swift logic, no MediaPipe dependency
MediaPipeIODemoUITests/
  DemoUITests.swift — drives the four flows shown in the README's demo clips above
```

### The semantic search model

One SwiftData table (`EmbeddingRecord`) backs global search in all three sections *and* local,
in-thread chat search — `EmbeddingScope` tags what a vector is *of*, and `SemanticSearchService`
filters by scope (and, for chat messages, by parent thread) before ranking by cosine similarity.
`indexIfNeeded` is idempotent, so `DemoDataSeeder` calling it on every launch only does real work
once.

`SemanticSearchService` is an `actor` around its own background `ModelContext` — SwiftData
contexts aren't safe to use off the queue they were created on, so the context is built lazily on
first real access *from inside the actor*, not eagerly in `init` (which runs on whichever actor
constructs the service — the main actor, via `AppContainer`). Building it eagerly would bind it to
the main queue and then get used off that queue here, which is exactly what SwiftData's runtime
"Unbinding from the main queue" warning flags — this was a real bug caught and fixed during
initial device testing (see `Search/SemanticSearchService.swift`'s doc comment for detail).

### Composition root

`AppContainer` wires everything by hand (no DI framework) — `@Observable`, injected into the
SwiftUI environment once in `MediaPipeIODemoApp`. Repositories hold the app's main `ModelContext`
(the same one `@Query` uses in views) and must stay `@MainActor`; the search/embedding path is the
one thing that hops onto its own actor for background work.

## Tests

```
xcodebuild -workspace MediaPipeIODemo.xcworkspace -scheme MediaPipeIODemo \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

`MediaPipeIODemoTests/` covers `WordDiff` (the LCS diff behind the Proofreader's view) and
`VectorIndex` (the cosine-similarity ranking every search feature depends on). These are compiled
directly into the test target rather than reached via `@testable import MediaPipeIODemo` —
`@testable import` would pull in the whole app module's `MediaPipeTasksText` dependency, and
linking that pod a second time into the test bundle crashes at launch (MediaPipe's native
calculators aren't safe to register twice in one process). Both files are pure Swift with no
MediaPipe dependency, so compiling them into both targets sidesteps the whole problem — see
`project.yml`'s `MediaPipeIODemoTests` target for detail.

`MediaPipeIODemoUITests/DemoUITests.swift` drives the four flows in the Demo section above through
real taps/drags via XCUITest, against the app's actual accessibility tree (not staged) — that's
what the GIFs were recorded from. Re-run one and re-record it (fresh install first, so status
counters/embedded badges start from zero):

```
xcrun simctl uninstall booted com.google.mediapipe.examples.iodemo
xcrun simctl io booted recordVideo --codec=h264 out.mov &
xcodebuild -workspace MediaPipeIODemo.xcworkspace -scheme MediaPipeIODemo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test -only-testing:MediaPipeIODemoUITests/DemoUITests/testDemoArchiveSummarize
kill -INT %1   # stop the recording once the test finishes
```

The Sticker flow additionally needs a photo in the Simulator's library first (`xcrun simctl
addmedia booted <path-to-image>`) — the test picks whichever photo is newest. `testDemoChatsSearch`
needs the chats already embedded — run `testDemoChatsEmbedding` once first (unrecorded, against the
same installed app) or it'll search against nothing and show "No matches found."
