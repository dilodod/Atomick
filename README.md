# Atomick Hub

Brookhaven Halloween 2026 Candy Corn helper for the Real Roblox executor.

## Features

- Rayfield Gen2 themed menu
- Candy progress display and collection log
- Skips candy already marked as collected by the game
- Anti-sit and recovery after falling below the map
- Optional character freeze
- Telegram button copies `https://t.me/AT3M3`
- Hide/show with RightShift; start/stop collection with RightControl

## Run

Load `Brookhaven_Halloween_AutoCandy.luau` in Real while Brookhaven is running. The UI downloads Rayfield Gen2 from its upstream URL when it starts.

The collector uses the game's proximity component and checks server-replicated progress; it does not directly invoke the candy collection RemoteFunction.

