# OpenWeights iOS benchmark and test checklist

Status snapshot: 2026-10-07. Saved for parking and later resumption.

The A1-A3 goal is paused. All phone tests remain on hold. Saving this checklist does not authorize test execution, another paid Firebase job, publication, or distribution. Preserve the existing evidence and do not restart completed checks without a specific reason.

This checklist records the benchmark measurements and individual product acceptance behaviors discussed with JC. It is not an assertion-by-assertion inventory of every internal automated test. A passing check applies to its tested model, build, and environment, not automatically to every model or the latest app build.

## Status definitions

- **Passed:** demonstrated in the tested model/build and environment.
- **Partial:** some required cases passed, but coverage is incomplete.
- **Failed:** a required behavior was tested and did not meet acceptance.
- **Not run:** explicitly prepared but not executed.
- **Unverified:** insufficient evidence to call it complete.

Implementation, compilation, selected test passes, and full feature acceptance are separate stages. None of the complete P1-P21 feature groups is closed.

## A2 Performance and conversation benchmarks

### Individual measurements

These measurements are implemented and have produced results. Their full three-device, five-repetition coverage remains incomplete.

| Check | In plain language | Status |
|---|---|---|
| B1 Model loading | How long the phone takes to get a model ready before you can chat. | Measured, full coverage pending |
| B2 First response delay | How long you wait before the first piece of a reply appears. | Measured, full coverage pending |
| B3 Reply speed | How quickly the rest of the reply arrives. Very short answers are flagged because their speed estimates are unstable. | Measured, full coverage pending |
| B4 Total request time | How long the entire reply takes. | Measured, full coverage pending |
| B5 Growing conversation cost | Whether replies become slower as more conversation history must be processed. | Measured, full coverage pending |
| B6 Cache reuse | Whether the engine reuses previously processed conversation text instead of processing everything again. | Measured for supported setups, replication pending |
| B7 Cache comparison | Run the same recorded conversation with reuse enabled and with a fresh reset, then compare behavior and cost. | Implemented and exercised, replication pending |
| B8 Memory use | How much app memory the setup uses while loading and answering. | Measured, full coverage pending |
| B9 Temperature conditions | Record whether the phone is cool or already warm, and whether that changes during a run. | Recorded, full coverage pending |
| B10 Stop response | How quickly generation stops after cancellation. | Exercised, full coverage pending |
| B11 Recovery after Stop | Whether the next request works after cancelling a reply. | Exercised, full coverage pending |
| B12 Fact recall | Whether the model remembers the facts supplied earlier in the conversation. | Scored, some answers fail |
| B13 Requested formatting | Whether it follows instructions such as answer with one number or return this JSON. | Scored separately from factual correctness, some answers fail |
| B14 Completion and failures | Count successful requests alongside download, loading, generation, timeout, and other failures. | Implemented, complete study denominator pending |
| B15 Repeatability | Whether five independent runs give reasonably consistent results. | 9 of 63 combinations complete |

Battery energy and actual Neural Engine placement are not measured. Existing results cannot support those claims. Different model exports and quantizations also prevent a runtime-only superiority claim.

### Conversation scenarios

| Scenario | What it tests individually | Status |
|---|---|---|
| S1 Stable facts | Give the model facts, grow the conversation over six turns, then check that the original facts remain correct. | Fully repeated locally across all seven configurations, cloud coverage incomplete |
| S2 Corrected facts | Change previously supplied facts and check that the model uses the new values instead of the old ones. | Partially repeated locally, cloud coverage incomplete |
| S3 Interruption and recovery | Cancel an auxiliary reply, restore the recorded conversation, and check that generation and fact recall still work. | Partially repeated locally, cloud coverage incomplete |

These are controlled synthetic conversations using pinned Qwen3-0.6B artifacts, not a broad general-intelligence dataset. The protocol uses six turns, a 2,048-token context, a maximum of 64 output tokens, and greedy decoding.

### Remaining repetitions

Each entry is S1 / S2 / S3 completed matching primary blocks. Each number must reach five. The matrix covers seven configurations, three devices, and three scenarios: 63 cells and 315 required runtime/scenario/device block contributions. The ledger credits 96 contributions at this snapshot. The remaining 219 contributions are not 219 separate jobs because baseline jobs batch multiple configurations.

| Configuration | Local iPhone 16 | Firebase iPhone 16 Pro | Firebase SE 3 |
|---|---:|---:|---:|
| llama.cpp CPU | 5 / 4 / 4 | 1 / 0 / 0 | 0 / 0 / 0 |
| ExecuTorch XNNPACK | 5 / 4 / 4 | 1 / 0 / 0 | 0 / 0 / 0 |
| llama.cpp full Metal | 5 / 4 / 4 | 1 / 0 / 0 | 0 / 0 / 0 |
| Standalone MLX | 5 / 4 / 4 | 1 / 0 / 0 | 0 / 0 / 0 |
| llama.cpp partial Metal | 5 / 4 / 4 | 1 / 0 / 0 | 0 / 0 / 0 |
| ExecuTorch Core ML | 5 / 2 / 0 | 4 / 0 / 0 | 0 / 0 / 0 |
| ExecuTorch MLX | 5 / 5 / 5 | 0 / 0 / 0 | 0 / 0 / 0 |

The earlier 19-cell completion count pooled different benchmark builds. Ten local baseline S2/S3 cells have four blocks from one build and one from an earlier build. Correct build separation leaves nine fully replicated cells. Historical measurements remain retained.

The latest submitted SE S1 block 3 job, matrix-3g4oz19yc7jiy, finished FINISHED/INCONCLUSIVE with execution ERROR and Internal System Error 3 after three automatic infrastructure-error attempts. Its status was read during the checklist discussion. It adds no completed block. Detailed terminal evidence collection remains pending, and older continuation files may still describe it as running. Inspect the existing job before any later action. Do not resubmit it.

### Benchmark trustworthiness checks

| Check | What it tests | Status |
|---|---|---|
| B16 Correct model download | Download the pinned model and verify its expected size and checksum. | Passed in successful acquisition and compatibility runs |
| B17 Corrupt model rejection | Deliberately give the verifier incorrect bytes, size, or checksum and ensure it refuses the model. | Passed |
| B18 Download retry | Retry temporary network failures without accepting a broken download. | Passed in scoped controls, a real earlier SE acquisition failed |
| B19 Permanent failure handling | Stop retrying when a TLS, HTTP, integrity, or persistent transport failure should end the attempt. | Scoped checks exist, execution evidence is not established here for every individual branch |
| B20 Cancel during download or retry | Stop a transfer or retry delay without committing an unwanted model. | Scoped checks exist, coverage remains limited |
| B21 Smoke inference | Load a model, generate actual output, cancel, and recover on the target device. | Local seven-configuration validation passed, SE five-configuration compatibility passed |
| B22 Answer grading | Ensure correct answers pass and wrong, incomplete, or wrongly formatted answers are scored correctly. | Passed scoped controls, grading revisions retained |
| B23 Matching-run accounting | Refuse to combine different builds, model artifacts, or OS cohorts as five identical repetitions. | Corrected and verified, completion is nine rather than the earlier 19 |
| B24 Failure preservation | Keep failed and partial runs instead of overwriting them with successful retries. | Implemented and exercised |
| B25 Reproducible report | Recreate tables, figures, and report text from retained measurements. | Passed for the current draft, final study and report incomplete |

## A3 App behavior tests

### P1 Finding a model

| Check | What it tests | Status |
|---|---|---|
| P1.1 Search | Search Hugging Face and show actual model results. | Passed selected live and native checks |
| P1.2 Filters | Apply supported runtime, size, publisher, and other filters without mislabeling results. | Passed scoped checks |
| P1.3 More results | Load additional search pages without looping, duplicating, or losing the search. | Passed controller checks |
| P1.4 Error and retry | Show a failed provider or repository lookup and allow recovery. | Passed selected checks |
| P1.5 Pinned selection | Select exact model files and revisions before downloading. | Passed selected GGUF, MLX, and compiled-model flows |
| P1.6 Recommendations | Recommend a suitable default model for the iPhone. | Unverified |
| P1.7 Restricted models | Use valid credentials to discover and download gated models. | Unverified |
| P1.8 Discovery to chat | Find a model, download it, load it, and get acceptable replies. | Partial, some models load successfully but fail strict reply checks |

### P2 Downloading a model

| Check | What it tests | Status |
|---|---|---|
| P2.1 Full download | Receive every file and verify the final bytes. | Passed selected real downloads |
| P2.2 Pause | Stop at a stable checkpoint without changing it afterward. | Passed |
| P2.3 Resume | Continue from the saved position without duplicated or missing bytes. | Passed |
| P2.4 Leave the app | Complete a transfer after you go to the Home Screen. | Passed selected real-phone flow |
| P2.5 Controlled process exit | Recover the original background transfer after the app deliberately exits and restarts. | Passed |
| P2.6 Execution time expires | Let a real temporary iOS execution grant expire and still finish the background transfer safely. | Passed selected case |
| P2.7 Natural iOS termination | Recover when iOS independently kills the app under memory pressure. | Unverified |
| P2.8 Expiry during final copying | Avoid corruption if available execution time ends while accepted data is being copied into place. | Unverified |
| P2.9 Later interruption | Interrupt at additional transfer stages and recover correctly. | Incomplete |

### P3 Importing and managing models

| Check | What it tests | Status |
|---|---|---|
| P3.1 Owned import | Copy a model into app storage so it still works after the original is removed. | Passed selected formats |
| P3.2 Companion files | Import the required tokenizer, configuration, and weight files together. | Passed selected MLX and PTE cases |
| P3.3 Invalid import | Reject broken, incomplete, incompatible, or unsafe file selections. | Passed scoped controls |
| P3.4 Reopen library | Restore installed-model information after reopening. | Passed selected checks |
| P3.5 Delete model | Remove the intended model without damaging other entries. | Passed selected checks |
| P3.6 External Files providers | Import through actual iCloud or third-party Files providers and their permissions. | Unverified |
| P3.7 Files picker interaction | Complete import through the visible picker and normal touch flow. | Unverified |

### P4 Loading the correct engine

| Check | What it tests | Status |
|---|---|---|
| P4.1 GGUF CPU and Metal | Route a GGUF model to CPU or GPU and generate real replies. | Passed selected models |
| P4.2 Standalone MLX | Load supported MLX model folders and generate replies. | Passed selected models |
| P4.3 Compiled-model routing | Choose the appropriate runner for a supported PTE export and family. | Partial |
| P4.4 Delegate execution | Run the rebuilt Core ML and ExecuTorch MLX benchmark binaries. | Passed local validation, full product coverage remains partial |
| P4.5 Unsupported combinations | Refuse a model and backend combination that cannot work. | Passed scoped admission checks |
| P4.6 Contextual correctness | Answer correctly when earlier conversation context is present. | Failed in retained cases, including history-dependent arithmetic |
| P4.7 Broader compatibility | Verify additional model families and supported older iOS versions. | Incomplete |

### P5 Streaming and Stop

| Check | What it tests | Status |
|---|---|---|
| P5.1 Streaming | Show a reply progressively instead of waiting for the entire answer. | Passed selected native flows |
| P5.2 Stop | Cancel an active reply. | Passed selected adapters |
| P5.3 Next reply | Generate normally after cancellation. | Passed selected flows |
| P5.4 App inactivity | Handle leaving the foreground while generation is active. | Partial, scripted and controlled checks pass |
| P5.5 Adapter coverage | Repeat cancellation and lifecycle checks for every product runner. | Incomplete |

### P6 Conversation cache and shortening long histories

| Check | What it tests | Status |
|---|---|---|
| P6.1 Cache reuse | Reuse earlier processing when the conversation prefix is unchanged. | Passed scoped checks, initial llama.cpp defect fixed |
| P6.2 Edited-history reset | Discard inappropriate cached state when earlier messages change. | Passed scoped checks |
| P6.3 Warm versus fresh | Get consistent behavior with preprocessed history and a fresh start. | Passed selected model checks |
| P6.4 Context admission | Refuse requests that do not fit the model's allowed context. | Passed selected checks |
| P6.5 Summary and reopen | Shorten an old history while keeping the full transcript and restoring the summary correctly. | Passed selected criteria |
| P6.6 Summary faithfulness | Ensure the summary preserves facts without inventing events or claims. | Failed retained cases |
| P6.7 Stop during shortening | Cancel shortening without losing the original conversation, then allow resend. | Passed selected flow, broader coverage incomplete |

### P7 Conversation management

| Check | What it tests | Status |
|---|---|---|
| P7.1 Reopen | Restore the intended conversation and its messages. | Passed selected checks |
| P7.2 Rename | Change the title without overwriting newer replies. | Passed, stale-data defect fixed |
| P7.3 Pin and archive | Persist filing changes and show the right conversation lists. | Passed scoped checks |
| P7.4 Delete | Delete the selected conversation durably. | Passed scoped checks |
| P7.5 Real controls | Use the actual menus, alerts, and gestures for these actions. | Unverified |

### P8 Conversation editing

| Check | What it tests | Status |
|---|---|---|
| P8.1 Regenerate | Replace or retry a reply while preserving the correct history. | Passed selected GGUF controller flow |
| P8.2 Edit and resend | Change an earlier message and generate from the revised history. | Passed selected flow |
| P8.3 Branch | Create an independent conversation branch without modifying the original. | Passed scoped checks |
| P8.4 Complete editing UI | Perform these actions through normal on-screen navigation. | Unverified |

### P9 Attachments

| Check | What it tests | Status |
|---|---|---|
| P9.1 Document text | Read a document, respect text limits, and disclose shortening. | Passed selected checks |
| P9.2 Owned attachment | Keep attachment bytes usable after the original file disappears. | Passed scoped checks |
| P9.3 Image preparation | Normalize an image into the expected model input. | Passed selected checks |
| P9.4 Image conversation | Use an image across history, branching, and cancellation. | Partial |
| P9.5 Audio preparation | Convert audio into the expected input format. | Passed selected checks |
| P9.6 Audio conversation | Use audio across several turns, reopen, Stop, and recover. | Partial, failures and narrower successful controls retained |
| P9.7 Video frames | Extract bounded video frames for model input. | Passed selected preparation checks |
| P9.8 Attachment restoration | Restore history and owned media after a controlled process kill. | Passed selected cases |
| P9.9 Media summary | Describe earlier media accurately after history shortening. | Failed retained faithfulness cases |
| P9.10 System sources | Select real files or photos, capture camera media, and use QuickLook. | Unverified |
| P9.11 Wider media support | Handle broader codecs and model families. | Incomplete |

### P10 Reading copying sharing and speech

| Check | What it tests | Status |
|---|---|---|
| P10.1 Markdown | Display headings, lists, code, and tables without losing text. | Passed scoped checks |
| P10.2 Highlighting | Color code while preserving its exact content and readable contrast. | Passed selected checks |
| P10.3 Copy | Put the correct text, Markdown, or code onto the clipboard. | Passed helper checks |
| P10.4 Remote-image behavior | Avoid silently downloading embedded images while rendering a reply. | Passed controlled checks |
| P10.5 Read aloud | Start, stop, retry, and complete spoken replies. | Passed selected checks |
| P10.6 Share menu and link flows | Use actual menus, links, and the iOS share sheet. | Unverified |
| P10.7 Speech interruption | Recover from real OS audio interruptions and verify spoken output. | Unverified |

### P11 Tools and approvals

| Check | What it tests | Status |
|---|---|---|
| P11.1 Tool switches | A disabled tool cannot execute. | Passed scoped checks |
| P11.2 Parse a tool request | Recognize valid model tool calls without executing examples or malformed output. | Passed scoped checks, parsing defects fixed |
| P11.3 Exact approval | Approval authorizes only the displayed operation and arguments. | Passed selected checks |
| P11.4 Decline | Rejecting a call prevents its effects and is remembered appropriately. | Passed selected checks |
| P11.5 Tool modes | Auto, Ask, Plan, and session-only Yolo follow their defined rules. | Passed scoped controller checks |
| P11.6 Private-data handling | Reading private data does not silently authorize sending it to a website. | Passed controlled checks |
| P11.7 Multi-step continuation | The model uses tool results and user answers to finish its task. | Partial, smaller-model failures remain |
| P11.8 Approval UI | Complete approval flows through actual touch and accessibility controls. | Incomplete |

### P12 File tools

| Check | What it tests | Status |
|---|---|---|
| P12.1 Find files | Search the permitted folder within defined limits. | Passed scoped checks |
| P12.2 Read files | Read permitted text with safe paging and limits. | Passed selected checks |
| P12.3 Write files | Create or change the intended file under the appropriate approval rules. | Passed selected checks |
| P12.4 Delete files | Require destructive-action approval and remove only the intended target. | Passed selected checks |
| P12.5 Folder boundary | Block paths or links that escape the granted folder. | Passed controlled checks |
| P12.6 Permission loss | Handle actual OS or provider revocation safely. | Controlled checks pass, real provider behavior unverified |

### P13 Web search and pictures

| Check | What it tests | Status |
|---|---|---|
| P13.1 Web search | Return usable destinations and snippets from supported providers. | Passed selected captured and live flows |
| P13.2 Fetch a page | Retrieve and extract readable page content. | Passed selected flows |
| P13.3 Find within a page | Search beyond the displayed excerpt without losing Unicode text. | Passed scoped checks |
| P13.4 Save page text | Save approved content without silently overwriting unrelated files. | Passed scoped checks |
| P13.5 Network boundaries | Reject private or local destinations and unsafe redirects. | Passed controlled checks |
| P13.6 Large pages | Stop at a bounded prefix and clearly disclose incomplete content. | Passed selected checks |
| P13.7 Text encodings | Read supported character encodings and handle malformed bytes predictably. | Passed scoped cases, one platform policy approved |
| P13.8 Gzip decoding | Read compressed pages without unlimited memory expansion. | Passed host checks |
| P13.9 Live gzip service | Read, find, and save against an actual public HTTPS gzip endpoint. | Passed on Mac |
| P13.10 Native gzip | Repeat Unicode, size-limit, and corruption checks inside the iPhone app. | Not run, two methods prepared |
| P13.11 Live pictures and Yahoo | Verify current provider output and usable image previews. | Incomplete |
| P13.12 Wider websites and UI | Verify broader page compatibility and actual browser or link interactions. | Incomplete |

### P14 Canvas previews

| Check | What it tests | Status |
|---|---|---|
| P14.1 Website preview | Open local HTML with its scripts, styles, and assets. | Passed selected checks |
| P14.2 Document preview | Render an A4-style document. | Passed selected Safari layout checks |
| P14.3 Slides | Render a 16:9 deck at the expected size. | Passed selected Safari layout checks |
| P14.4 Live save | Update an open preview after saving its files. | Passed selected checks |
| P14.5 Preview boundaries | Prevent tested escapes and close local URLs when the preview is stopped. | Passed controlled checks |
| P14.6 Incomplete HTML warning | Warn about cut-off output and clear the warning after a complete repair. | Passed scoped checks |
| P14.7 Model creation | Have the model create a working preview through tools. | Observed, broader acceptance incomplete |
| P14.8 Feedback-driven repair | Have the model inspect current errors and repair them using that feedback. | Failed acceptance |
| P14.9 Real touch and lifecycle | Verify gestures, accessibility, external providers, and actual OS background behavior. | Unverified |

### P15 Running scripts

| Check | What it tests | Status |
|---|---|---|
| P15.1 Calculation | Execute a model-written script and return its result. | Passed selected iOS 26 flows |
| P15.2 Ask approval | Wait for approval before running the exact script. | Passed selected checks |
| P15.3 Limits and Stop | Stop runaway or cancelled work and recover afterward. | Passed selected interpreter and helper checks |
| P15.4 Isolation | Keep scripts within their permitted capabilities and test helper failure handling. | Passed controlled security checks |
| P15.5 Input privacy | Treat file-derived results as private when later tools use them. | Passed controlled checks |
| P15.6 Watch script | Execute a script during a watch and preserve normal chat state. | Passed selected flow |
| P15.7 Older iOS | Provide script parity below iOS 26, or an approved alternative. | Unresolved |
| P15.8 Providers and navigation | Verify actual external inputs and visible script controls. | Unverified |

### P16 Goals plans questions and research

| Check | What it tests | Status |
|---|---|---|
| P16.1 Plan persistence | Save steps and restore them after reopening. | Passed scoped checks |
| P16.2 Progress | Advance the intended step once, without false or duplicate completion. | Passed scoped checks |
| P16.3 User question | Persist a question, accept its answer, and resume appropriately. | Partial, selected 1.7B flow passes, smaller-model failures remain |
| P16.4 Goal execution | Complete an actual multi-step task instead of repeatedly planning or asking you to do the work. | Partial, selected arithmetic goal passes on 1.7B |
| P16.5 Research evidence | Require successful relevant searches and reads before claiming research progress. | Passed controlled checks |
| P16.6 Changed question | Discard stale evidence when a reviewed research question changes. | Passed selected checks |
| P16.7 Research report | Produce a report grounded in collected evidence. | Passed controlled-source example, live quality incomplete |
| P16.8 Process recovery | Recover pending questions and goals after real process loss and OS continuation. | Unverified |

### P17 Saved memory

| Check | What it tests | Status |
|---|---|---|
| P17.1 Save | Save only the approved fact. | Passed selected model flows |
| P17.2 Read in another chat | Retrieve saved information in a new conversation. | Partial, some models fail recall or skip the tool |
| P17.3 Update | Replace the intended fact while preserving its identity. | Passed selected 1.7B flow |
| P17.4 Forget | Delete the intended fact durably. | Passed selected checks |
| P17.5 Decline and Stop | Avoid unwanted writes after rejecting or cancelling a call. | Passed selected flows |
| P17.6 Manual editing | Edit or delete the selected record and reject stale edits. | Passed controller and native checks |
| P17.7 Editor validation | Disable Save for empty or oversized input and discard cancelled edits. | Touch test not run |
| P17.8 Permission switches | Persist separate read and write switches across navigation and restart. | Controller checks pass, ordinary-app touch test not run |
| P17.9 Broader recall | Check reliable memory use across additional model families. | Incomplete |

### P18 Watches and reminders

| Check | What it tests | Status |
|---|---|---|
| P18.1 Create and manage | Create, pause, resume, edit, and stop persistent watches. | Passed scoped checks |
| P18.2 Catch-up | Handle overdue checks when the app reopens without running an unlimited backlog. | Passed controlled checks |
| P18.3 Real model check | Run a selected watch through actual CPU inference. | Passed selected flows |
| P18.4 Fresh web check | Read the source again and distinguish unchanged information from a new finding. | Passed selected flows |
| P18.5 Inactive CPU routing | Keep an authorized CPU check alive through controlled inactivity callbacks. | Passed, routing defect fixed |
| P18.6 OS request queue | Submit, replace, and remove actual iOS background requests. | Passed |
| P18.7 OS-granted execution | Verify iOS actually launches the task and invokes expiry handling. | Unverified |
| P18.8 Notification permission | Handle the real Allow or Don't Allow prompt correctly. | Not run, fixture prepared |
| P18.9 Notification delivery | Deliver and acknowledge a result or due reminder without duplicate notices. | Not run, fixture prepared |
| P18.10 Cold-launch callback | Record and handle a background callback when the app starts cold. | Unverified |

### P19 Settings and credentials

| Check | What it tests | Status |
|---|---|---|
| P19.1 Appearance | Save light, dark, or system choice and render selected screens correctly. | Passed selected checks |
| P19.2 Credential storage | Store and update credentials safely in Keychain and avoid exposing them in output. | Passed isolated checks |
| P19.3 Rejected credential | Reject an invalid token without leaving it saved as valid. | Passed live check |
| P19.4 Valid and gated account | Use an actual valid account for restricted-model access. | Unverified |
| P19.5 Restart and navigation | Preserve settings through a full app restart and actual credential screens. | Incomplete |

### P20 Generation controls

| Check | What it tests | Status |
|---|---|---|
| P20.1 Shared settings | Carry shared generation preferences between models while keeping context and backend choices model-specific. | Passed selected checks |
| P20.2 Invalid settings | Refuse impossible or non-finite values before changing saved state or allocating a model. | Passed scoped checks |
| P20.3 Sampler controls | Verify Top K and Min P filtering actually follows its configured limits. | Passed selected controls |
| P20.4 Standing instructions | Apply changed instructions within the same conversation and after reopening. | Partial |
| P20.5 Answer length plus instructions | Follow the combined preferences in an actual model reply. | Failed retained acceptance |
| P20.6 Reasoning controls | Apply supported effort templates without implying unsupported models have that capability. | Incomplete |

### P21 Usage storage and diagnostics

| Check | What it tests | Status |
|---|---|---|
| P21.1 Usage accounting | Count generated and prompt tokens and model passes without duplication. | Passed selected checks |
| P21.2 Daily history | Preserve totals and show usage by day and backend. | Passed scoped checks |
| P21.3 Storage totals | Include installed and partial files without following unrelated links. | Passed scoped checks |
| P21.4 Timing | Record completed GPU work rather than only the time to submit it. | Corrected and verified in scoped controls |
| P21.5 Fit prediction | Check whether memory estimates reliably predict that a model will fit. | Unverified, current estimates are advisory |
| P21.6 Dashboard interaction | Verify full gestures, accessibility, broader calibration, and natural lifecycle. | Incomplete |

## A1 and cross cutting tests

| Check | What it tests | Status |
|---|---|---|
| C1 Independent builds | Build and execute without depending on the original Android checkout's active iOS files. | Passed selected product, baseline, and delegate validation |
| C2 Android regression | Ensure shared engine changes still pass Android unit checks and compile into its native library. | Passed 70 unit tests plus library build, no Android device inference claim |
| C3 Tab navigation | Reach Chat, Models, Watches, Tools, and Settings through actual taps. | Passed in benchmark-slot app, ordinary-app repeat not run |
| C4 Filter cancellation | Open and dismiss discovery filters without starting a download. | Passed in benchmark-slot app, ordinary-app repeat not run |
| C5 Home and relaunch | Return from Home and launch again after controlled termination. | Passed in benchmark-slot app, ordinary-app repeat not run |
| C6 VoiceOver | Navigate and operate complete flows with spoken accessibility controls. | Unverified |
| C7 Full screen coverage | Check all relevant content and controls under large text and appearance changes. | Partial, selected captures and contrast checks exist |
| C8 Natural lifecycle | Handle actual OS suspension and termination instead of only injected callbacks or deliberate kills. | Incomplete |
| C9 HF recovery | Upload an archive, download it again, verify it, and retain restore information before local deletion. | Passed for cataloged completed archives |
| C10 Final regression | Verify the final frozen app build after all remaining changes. | Pending |
| C11 Final study delivery | Produce the completed report, figures, failure accounting, and limitations from the full approved matrix. | Pending |

At this snapshot, available source includes 337 core test methods, 148 device-test methods, and five UI-test methods, plus controller and benchmark harness checks. Those are inventory counts, not a claim that the latest app passed every method.

## Evidence and resumption

| Reference | Purpose |
|---|---|
| [Study protocol](../../ios/Benchmark/Study/protocol-v1.json) | Scenarios, measurements, controls, and required repetitions |
| [Execution ledger](../../ios/Benchmark/Study/execution-ledger-2026-10-03.json) | Matching primary blocks and retained failures |
| [Research report](../research/ios-repeated-artifact-study.md) | Current reproducible draft, tables, figures, and limitations |
| [Parity inventory](../../ios/Product/parity.md) | Detailed P1-P21 evidence and unresolved acceptance |
| [Independent validation](../../migration/native-validation-2026-10-07.json) | Selected native product, baseline, and delegate checks |
| [Build cohort correction](../../migration/study-source-build-cohort-correction-verification-2026-10-07.json) | Why replication changed from 19 to nine cells |
| [Navigation proof](../../migration/native-ui-navigation-2026-10-07.json) | Three passing benchmark-slot touch-navigation methods |
| [Prepared ordinary UI tests](../../migration/ordinary-memory-ui-signed-preparation-2026-10-07.json) | Five signed but unexecuted ordinary-app methods |
| [Prepared native gzip tests](../../migration/gzip-signed-product-preparation-verification-2026-10-07.json) | Two signed but unexecuted native gzip methods |
| [Live Mac gzip proof](../../migration/gzip-live-host-verification-2026-10-07.json) | Five passing external HTTPS controls on Mac |
| [SE block 3 submission](../../ios/Benchmark/Results/firebase-SE3-current-study-S1-block3-submission-2026-10-07.json) | Existing submitted job identity, package, and preflight binding. Terminal status collection remains pending |
| [File artifact catalog](../../migration/artifact-catalog.json) | Recoverable packages in private HF storage |
| [Build artifact catalog](../../migration/build-artifact-catalog.json) | Recoverable inactive build directories in private HF storage |

The private artifact destination remains hf://buckets/zeraphim/openweights-ios-artifacts. Active models, toolchains, signed preparations, and small reports remain local according to the existing storage workflow.

When work resumes, keep these categories separate: remaining repetitions, unexecuted acceptance tests, and failed behaviors needing fixes. Reconcile statuses against exact build receipts before running anything. Existing phone holds and per-job paid-execution approval requirements remain in force.
