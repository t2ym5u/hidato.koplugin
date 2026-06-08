# Hidato

> **Status: stub — not yet implemented**

## Description

Fill a grid with consecutive numbers 1–N. Each successive number must be placed in an adjacent cell (incl. diagonals).

## Files to create

- `board.lua` — game logic, puzzle generator, serialize/load
- `board_widget.lua` — grid rendering and tap gestures
- `screen.lua` — full-screen layout (buttons + board)
- `main.lua` — PluginBase entry point

## Notes

Number placement puzzle — use GridWidgetBase from game-common.
