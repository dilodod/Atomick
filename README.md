# Atomick AutoFarm

Brookhaven Halloween 2026 Candy Corn helper for the Real Roblox executor.

## Features

- Compact, draggable mini widget with animated progress, START/STOP, and OPEN controls
- Rayfield Gen2 full menu with ember theme, progress, logs, themes, and protection settings
- Nearest-next routing; rechecks server-replicated progress before each move
- Short confirmation window and one retry for each collection attempt
- Skips already-collected candy and unsupported locations below the map
- Optional auto-respawn activates the visible in-game respawn button and waits for new candy before continuing
- Anti-sit and recovery from falls; optional character freeze
- Local route reset rescans only remaining candy and never clears event progress
- Telegram button copies `https://t.me/AT3M3`
- Source label `SOURCE · AT3M3`
- RightShift hides/shows the full menu; RightControl starts/stops collection

## Run

Load `Brookhaven_Halloween_AutoCandy.luau` in Real while Brookhaven is running. The UI downloads Rayfield Gen2 from its upstream URL when it starts.

The collector relies on the game's proximity component and confirms collection from replicated event data. Auto-respawn uses the visible event button and waits for replicated candy state to change; it does not call the hunt-reset remote directly. A candy location below the map without a safe floor is skipped to avoid trapping the character in the void.

