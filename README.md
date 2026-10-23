# Atomick AutoFarm

Brookhaven Halloween 2026 Candy Corn helper for the Real Roblox executor.

## Interface

- One draggable orange bar with a subtle gradient, sized up to 360 × 56 pixels and kept inside the screen insets.
- START immediately reveals `Собрано N шт.`; STOP restores the centered `@AT3M3` channel in the right section.
- Independent press, hover and ripple feedback on the two sections, a short entrance transition, and animated count changes.
- The session counter counts confirmed pickups made by the collector. It survives STOP/START and candy-hunt resets; running the script again starts a new session.
- Already-collected candy is skipped. Repeated confirmation of the same candy is counted once until replicated data shows that candy is available again.
- Clicking the channel copies `https://t.me/AT3M3` and confirms success. If clipboard access is unavailable or fails, the bar displays `t.me/AT3M3` instead.
- Dragging begins after 6 pixels of movement and suppresses the click. Mouse and touch input are supported.
- Short failures appear in the same row; detailed collection messages are printed to the executor console.

## Collection

The collector chooses the nearest remaining candy, rechecks replicated event data before moving, and waits for confirmation with one retry. It skips unsupported locations below the map and includes anti-sit and fall recovery.

Collection relies on the game's proximity component. After exhausting the known candidates, auto-respawn invokes the game's `Halloween2026_ResetCandyCornHunt` reset remote and waits for replicated progress to change before continuing. The session total is independent of that hunt progress.

## Run

Load `Brookhaven_Halloween_AutoCandy.luau` in Real while Brookhaven is running. The interface uses native Roblox instances and TweenService; it does not download a GUI library or external assets.

The helper depends on the event's current replicated data and objects. A missing event, unavailable character, or rejected reset is reported in the bar.
