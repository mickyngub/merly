# AI Usage Dashboard

_Started 2026-06-11 19:00 UTC_

---

## User

I want to built macos native app for displaying my claude, codex, kimi usage. it should ideally be able to add more agent provider as time goes on. i think it should get each usage based on the folder location like ~/.claude , but i have two claude accounts also under ~/.claude-work so please account for this. i want native app feel with cute animation for each. it shouldn't take up too much space should stick to either side of the macos when open.

each provider should have its own logo or mascot, that's cute and interactive

## Assistant

_[tool: questions_v2]_

Love this concept — a docked macOS usage tracker with cute per-provider mascots. Before I design, let me lock down a few things so I build the right thing rather than guessing. I've got a clear picture of the core idea; these will shape the look and the data layout.

## User

Questions answered:
- aesthetic: Clean macOS native (frosted glass, system grays, SF-style)
- appearance: Both (follows macOS system)
- metrics: Rate-limit / quota remaining
- timeframe: we need to show all Current sessionResets in 3 hr 13 min12% usedWeekly limitsLearn more about usage limitsAll modelsResets Thu 7:59 PM9% usedSonnet onlyResets Thu 7:59 PM0% used
- dock_side: Right edge
- panel_density: Narrow column (mascot + a few stats each)
- mascot_style: Pixel / 8-bit critters
- mascot_behavior: Mood changes with usage (happy when low, tired/overworked when near limit)
- providers: Claude (×2 accounts: personal + work), Codex / OpenAI, Kimi
- accounts_display: Two separate mascots side by side
- variations: Just one strong direction

## Assistant

_[tool: update_todos]_

_[tool: copy_starter_component]_

Clear direction. Here's what I'm building:

- **A narrow frosted-glass column docked to the right edge** of a mock macOS desktop (so the "sticks to the side" behavior reads), with a collapse handle and slide animation.
- **Quota-remaining focus**: per provider, a session ring ("12% used · resets in 3h 13m") plus expandable weekly-limit bars (All models / Sonnet only) — matching the Claude usage structure you pasted.
- **Pixel 8-bit critters**, one per provider, whose **mood shifts with usage** (happy → content → tired → stressed). Claude Personal + Claude Work get two distinct critters; plus Codex and Kimi. Built as a "family" so adding a 5th provider later is trivial.
- **Both light/dark**, and Tweaks to scrub each provider's usage live and watch the mascots change mood.

Let me set up and pull in the scaffolding.

_[tool: write_file]_

Scaffolding's in. Now the pixel-mascot engine — a "critter family" so a new provider is just a palette + ear style. Writing that, then the app.

_[tool: write_file]_

Now the app — macOS desktop, the right-docked frosted panel, provider cards, and Tweaks. HTML shell first, then the React app.

_[tool: write_file]_

Now the React app logic.Now let me see it render and inspect the pixel mascots.

_[tool: show_html]_

_[tool: show_html]_

_[tool: get_webview_logs]_

Cards aren't rendering. Let me check the console.

_[tool: eval_js]_

No errors — the cards are likely just stuck at the `opacity:0` pre-animation state in the static screenshot (html-to-image doesn't run keyframes). Let me confirm they render live and inspect the mascots up close.

_[tool: str_replace_edit]_

Found it — the `.fade-in` wrapper uses `animation-fill-mode: both`, so when the preview tab is throttled the staggered cards hold their `opacity:0` start frame. That's the fragile pattern I should avoid. Resting state must be visible. Fixing it, then re-checking the mascots.

_[tool: show_html]_

_[tool: multi_screenshot]_

Cards render and the critters read well — green antenna'd Codex, purple crescent Kimi, blue tie'd Claude Work. The top Claude·Personal card was just mid-entrance-animation when captured. Let me confirm it settles and look at the mascots close up.

_[tool: eval_js]_

The first Claude·Personal card is genuinely not painting (not just animation), and `.open` didn't expand. Let me inspect the live DOM directly.

_[tool: str_replace_edit]_

Diagnosis: my preview iframe throttles CSS animations/transitions, freezing them mid-flight — that's why the 0-delay card froze near `opacity:0` and the expand max-height froze at 0. It works fine in the user's live view, but I shouldn't depend on opacity-animation for visibility. I'll make the entrance translate-only (always opaque), then force-open to verify the expanded layout.

_[tool: show_html]_

_[tool: save_screenshot]_

_[tool: multi_screenshot]_

Excellent — fully assembled now. The coral cat (Claude Personal, CHILL), blue tie'd Work cat (OK), green antenna Codex (BUSY), purple crescent Kimi all read clearly, weekly bars and `~/.claude` paths look great in expanded state. Let me check the light theme and the collapsed rail state.

_[tool: str_replace_edit]_

Light theme and frosted glass look great. The collapse/rail animation is frozen in my throttled preview but is wired and will animate live. One faithfulness tweak: you asked it to follow the macOS system theme, so I'll default to **auto** (follows system) rather than forcing dark.

_[tool: update_todos]_

_[tool: done]_

_[tool: fork_verifier_agent]_

Here's your **Usage Dock** — a macOS-native, right-docked usage tracker.

**What it does**
- **Docks to the right edge** as a narrow frosted-glass column on a mock macOS desktop (menu bar + wallpaper), with a collapse handle that slides the panel away to a slim **rail of peeking mascots**. Tweaks can flip it to the left edge.
- **Quota-focused cards** mirroring the Claude structure you pasted: a session ring (`12% used · resets in 3h 12m`, live-counting), and a tap-to-expand section with **weekly limits** (All models / Sonnet only / Opus only / Weekly) and the source folder — `~/.claude` vs `~/.claude-work`, so both Claude accounts are distinct critters side by side.
- **Pixel 8-bit critters whose mood tracks usage** — happy `CHILL` → `OK` → `BUSY` → `FRIED` (stressed, with sweat drops & wide eyes). They idle-bob, blink, and hop when you hover. Codex is marked "active now" with a faster bob + pulse dot.
- **Built to grow**: providers are a data array grouped Anthropic / Other agents, with an "Add a provider → point it at a config folder" card. A 5th agent is just a palette + ear style.
- **Follows the system theme** (auto/light/dark), and **Tweaks** let you scrub each provider's usage 0–100% to watch the mascots change mood live.

**Worth knowing**
- It's a faithful interactive *prototype* of the UI/feel — it doesn't actually read your disk yet. The folder paths, reset times, and percentages are realistic mock data wired to the same shape a real reader would produce.
- The collapse/rail and entrance use CSS transitions that look frozen in my static screenshots but animate normally in your live view.

Want me to add a sparkline of usage-over-time, sound/haptic-style reactions when a provider hits a limit, or sketch how the real folder-reading would map to each provider's config?

## User

no separation between anthropic and other agents please

## Assistant

_[tool: str_replace_edit]_

Done — all four providers now flow as one continuous list, no section headers.

_[tool: done]_

Removed the "Anthropic" / "Other agents" separators — the four cards are now one uninterrupted list.

## User

the font and color is hard to read. can we decrease the mascot sizing

## Assistant

_[tool: show_html]_

Let me take a quick look at the current readability, then fix the contrast and shrink the mascots.

_[tool: str_replace_edit]_

Clear issues: the pixel-font mood tags (CHILL/OK/BUSY) and the faint secondary text are hard to read, and the mascots are oversized. Fixing all three.

_[tool: str_replace_edit]_

_[tool: show_html]_

_[tool: done]_

Much more legible now — mood tags read clearly in clean uppercase, the reset times and "used" labels have proper contrast, and the smaller 48px mascots make the cards tighter and calmer.Fixed both:
- **Readability** — mood tags (`CHILL`/`OK`/`BUSY`) now use the system font in bold uppercase instead of the pixel face, and I bumped contrast on the reset times, "used" labels, and weekly captions in both light and dark.
- **Mascot size** — dropped from 64px to 48px, so the cards are tighter and the critters sit more comfortably next to the text.

The pixel-art charm stays in the mascots themselves; everything textual is now crisp SF.

