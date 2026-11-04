local grid_utils = require("grid_utils")
local Hint      = require("hint")

local emptyGrid     = grid_utils.emptyGrid
local emptyBoolGrid = grid_utils.emptyBoolGrid
local copyGrid      = grid_utils.copyGrid

local DEFAULT_N          = 5
local DEFAULT_DIFFICULTY = "easy"

-- Fraction of non-endpoint cells revealed as clues
local GIVEN_RATIOS = { easy = 0.40, medium = 0.25, hard = 0.15 }

-- 8-directional adjacency (king moves)
local DIRS = {
    { -1, -1 }, { -1, 0 }, { -1, 1 },
    {  0, -1 },            {  0, 1 },
    {  1, -1 }, {  1, 0 }, {  1, 1 },
}

-- Counts Hamiltonian-path completions (up to `limit`) consistent with the
-- given fixed cells, placing numbers 1..n*n in path order (each must land on
-- a king-move-adjacent unoccupied cell, or the pre-fixed cell if given).
-- Returns (solutions_found, exhausted); exhausted=true means node_budget was
-- hit before the search concluded, so the count isn't proof. Mirrors
-- sudokukiller.koplugin/board.lua's countCageSolutions.
local NODE_BUDGET_UNIQUENESS = 200000

local function countCompletions(puzzle, given, n, limit, node_budget)
    local total = n * n
    -- Where each given number sits, and for every k the smallest given
    -- number >= k: number k on (r, c) can only lead to a solution when the
    -- next given number g can still be reached in g - k king moves, i.e.
    -- the Chebyshev distance from (r, c) to g's cell is at most g - k. That
    -- prune only drops dead branches, so counts are unchanged; it is what
    -- keeps a 6x6 Hard dig fast (the unpruned walk wandered off and came
    -- back far too late, ~1 s per puzzle on a desktop, ~25 s on a Kobo).
    local given_r, given_c = {}, {}
    for r = 1, n do
        for c = 1, n do
            if given[r][c] then
                given_r[puzzle[r][c]] = r
                given_c[puzzle[r][c]] = c
            end
        end
    end
    local next_given = {}
    for k = total + 1, 1, -1 do
        next_given[k] = given_r[k] and k or next_given[k + 1]
    end
    local occupied = {}
    for r = 1, n do occupied[r] = {} end
    local path_r, path_c = {}, {}
    -- A free cell needs two ways in and out (one if it can be the last
    -- number, i.e. when n*n isn't given).
    local min_exits = given_r[total] and 2 or 1

    -- Gaps between consecutive given numbers: gap j runs from the j-th
    -- given number to the (j+1)-th. A free cell x can only hold a number of
    -- gap j when dist(start of j, x) + dist(x, end of j) fits the gap's
    -- length; last_gap[x] is the latest gap x fits. Once the path is past
    -- that gap x can never be filled, and the free cells that only fit the
    -- current gap must fit in its remaining slots. (Only when both 1 and
    -- n*n are given, which generate() always keeps.)
    local function dist(r1, c1, r2, c2)
        local dr, dc = r1 - r2, c1 - c2
        if dr < 0 then dr = -dr end
        if dc < 0 then dc = -dc end
        return dr > dc and dr or dc
    end
    local gap_of, gap_end, gap_cells, check_from = {}, {}, nil, nil
    if given_r[1] and given_r[total] then
        local seq = {}
        for k = 1, total do
            if given_r[k] then seq[#seq + 1] = k end
        end
        local j = 0
        for k = 1, total do
            if given_r[k] then j = j + 1 end
            gap_of[k] = j            -- a free number k lies in gap j
        end
        gap_cells = {}               -- gap_cells[j]: free cells whose last gap is j
        for i = 0, #seq do gap_cells[i] = {} end
        for i = 1, #seq - 1 do gap_end[i] = seq[i + 1] end
        -- A gap with no free number can't hold any cell (two king steps at
        -- least), so on entering gap j only the gaps back to the previous
        -- one with free numbers need checking: check_from[j].
        check_from = {}
        local last_open = 1
        for i = 1, #seq - 1 do
            check_from[i] = last_open
            if seq[i + 1] - seq[i] > 1 then last_open = i end
        end
        for r = 1, n do
            for c = 1, n do
                if not given[r][c] then
                    local best = 0
                    for i = 1, #seq - 1 do
                        local a, b = seq[i], seq[i + 1]
                        if dist(given_r[a], given_c[a], r, c) + dist(r, c, given_r[b], given_c[b]) <= b - a then
                            best = i
                        end
                    end
                    local list = gap_cells[best]
                    list[#list + 1] = r
                    list[#list + 1] = c
                end
            end
        end
    end

    -- Free number num goes next, after (pr, pc), in gap j. On entering the
    -- gap, every cell whose last gap is behind must be filled already; and
    -- the free cells that only fit gap j must fit in what is left of it.
    local function gapsBlocked(num, pr, pc)
        local j = gap_of[num]
        if given_r[num - 1] then
            for i = check_from[j], j - 1 do
                local list = gap_cells[i]
                for t = 1, #list, 2 do
                    if not occupied[list[t]][list[t + 1]] then return true end
                end
            end
        end
        local g = gap_end[j]
        local gr, gc = given_r[g], given_c[g]
        local slots = g - num
        local need = 0
        local list = gap_cells[j]
        for t = 1, #list, 2 do
            local r, c = list[t], list[t + 1]
            if not occupied[r][c] then
                if dist(pr, pc, r, c) + dist(r, c, gr, gc) > slots + 1 then return true end
                need = need + 1
                if need > slots then return true end
            end
        end
        return false
    end

    -- A free cell that fits no gap at all: no solution.
    if gap_cells and #gap_cells[0] > 0 then return 0, false end

    local solutions, nodes, exhausted = 0, 0, false

    -- Once number k is placed, the cell holding k - 1 is closed off for good:
    -- any free cell next to it that is left with fewer than min_exits
    -- unoccupied neighbours (the head counts as one) can never be filled.
    local function strandsNeighbour(k)
        local qr, qc = path_r[k - 1], path_c[k - 1]
        if not qr then return false end
        local hr, hc = path_r[k], path_c[k]
        for _, d in ipairs(DIRS) do
            local xr, xc = qr + d[1], qc + d[2]
            if xr >= 1 and xr <= n and xc >= 1 and xc <= n
                    and not occupied[xr][xc] and not given[xr][xc] then
                local exits = 0
                for _, e in ipairs(DIRS) do
                    local yr, yc = xr + e[1], xc + e[2]
                    if yr >= 1 and yr <= n and yc >= 1 and yc <= n
                            and (not occupied[yr][yc] or (yr == hr and yc == hc)) then
                        exits = exits + 1
                        if exits >= min_exits then break end
                    end
                end
                if exits < min_exits then return true end
            end
        end
        return false
    end

    local function reachable(r, c, num)
        local g = next_given[num + 1]
        if not g then return true end
        local dr, dc = r - given_r[g], c - given_c[g]
        if dr < 0 then dr = -dr end
        if dc < 0 then dc = -dc end
        return (dr > dc and dr or dc) <= g - num
    end

    -- Many orderings of the same cells reach the same position: memoise
    -- the (capped) completion count per (occupied cells, head). The prunes
    -- above only ever cut positions with no completion at all, so a memo
    -- entry is the same whichever way the position was reached. Keys are
    -- exact doubles while n*n + 6 bits fit in 53, i.e. up to 6x6 (the
    -- largest size offered); bigger boards just search without it.
    local memo = total <= 36 and {} or nil
    local bit_of = {}
    for r = 1, n do
        bit_of[r] = {}
        for c = 1, n do bit_of[r][c] = 2 ^ ((r - 1) * n + (c - 1)) end
    end
    local mask = 0

    -- Returns the number of completions from here, capped at `limit`.
    local function search(num, pr, pc)
        if exhausted then return 0 end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return 0 end
        if num > total then return 1 end
        local key
        if memo and num > 1 then
            key = mask * 64 + (pr - 1) * n + pc
            local m = memo[key]
            if m then return m end
        end

        local count = 0
        local gr = given_r[num]
        if gr then
            local gc = given_c[num]
            -- A given cell is never taken by another number (free numbers
            -- skip given cells), so only adjacency to num - 1 matters.
            if num == 1 or (math.abs(gr - pr) <= 1 and math.abs(gc - pc) <= 1) then
                occupied[gr][gc] = true
                path_r[num], path_c[num] = gr, gc
                mask = mask + bit_of[gr][gc]
                if not (num > 1 and strandsNeighbour(num)) then
                    count = search(num + 1, gr, gc)
                end
                mask = mask - bit_of[gr][gc]
                occupied[gr][gc] = nil
            end
        elseif not (gap_cells and gapsBlocked(num, pr, pc)) then
            for t = 1, (num == 1 and n * n or #DIRS) do
                local nr, nc
                if num == 1 then
                    nr, nc = math.floor((t - 1) / n) + 1, (t - 1) % n + 1
                else
                    nr, nc = pr + DIRS[t][1], pc + DIRS[t][2]
                end
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                        and not occupied[nr][nc] and not given[nr][nc]
                        and reachable(nr, nc, num) then
                    occupied[nr][nc] = true
                    path_r[num], path_c[num] = nr, nc
                    mask = mask + bit_of[nr][nc]
                    if not (num > 1 and strandsNeighbour(num)) then
                        count = count + search(num + 1, nr, nc)
                    end
                    mask = mask - bit_of[nr][nc]
                    occupied[nr][nc] = nil
                    if count >= limit or exhausted then break end
                end
            end
        end
        if count > limit then count = limit end
        if key and not exhausted then memo[key] = count end
        return count
    end

    solutions = search(1)
    return solutions, exhausted
end

-- ---------------------------------------------------------------------------
-- Hamiltonian path generation via DFS
-- ---------------------------------------------------------------------------

-- Node budget per start attempt: Warnsdorff ordering usually finds a path in
-- a few hundred/thousand calls, but on an unlucky start it can backtrack
-- catastrophically (observed hanging for 15+ seconds on a single n=5 start
-- with no bound at all). Capping calls per start keeps worst-case latency
-- bounded while still trying the next random start on budget exhaustion.
local NODE_BUDGET_PER_START = 20000

local function generatePath(n)
    local total   = n * n
    local visited = emptyBoolGrid(n)
    local path    = {}   -- path[k] = {r, c}  (1-indexed, k=1..total)
    local pos     = emptyGrid(n)  -- pos[r][c] = value placed there (or 0)
    local nodes   = 0

    local function dfs(r, c, step)
        nodes = nodes + 1
        if nodes > NODE_BUDGET_PER_START then return false end
        visited[r][c] = true
        pos[r][c]     = step
        path[step]    = { r, c }

        -- step == total means this call just placed the last cell — done.
        -- (The old "step > total" check here was unreachable: there is no
        -- total+1-th cell to recurse into, so a full grid always fell
        -- through to the neighbour search below, found no moves, and
        -- backtracked — the search could *never* succeed, silently forcing
        -- every generate() to exhaust its full search space and fall back.)
        if step == total then return true end

        -- Collect unvisited neighbours and sort by Warnsdorff heuristic
        -- (fewest onward moves first) to speed up backtracking
        local moves = {}
        for _, d in ipairs(DIRS) do
            local nr, nc = r + d[1], c + d[2]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n and not visited[nr][nc] then
                -- Count that neighbour's own free neighbours
                local fwd = 0
                for _, d2 in ipairs(DIRS) do
                    local nr2, nc2 = nr + d2[1], nc + d2[2]
                    if nr2 >= 1 and nr2 <= n and nc2 >= 1 and nc2 <= n
                            and not visited[nr2][nc2] and not (nr2 == r and nc2 == c) then
                        fwd = fwd + 1
                    end
                end
                moves[#moves + 1] = { nr, nc, fwd }
            end
        end
        table.sort(moves, function(a, b) return a[3] < b[3] end)

        for _, mv in ipairs(moves) do
            if dfs(mv[1], mv[2], step + 1) then return true end
        end

        -- Backtrack
        visited[r][c] = false
        pos[r][c]     = 0
        path[step]    = nil
        return false
    end

    -- Try up to 50 random starting cells
    local starts = {}
    for r = 1, n do
        for c = 1, n do
            starts[#starts + 1] = { r, c }
        end
    end
    -- Simple Fisher-Yates shuffle for starts
    for i = #starts, 2, -1 do
        local j = math.random(i)
        starts[i], starts[j] = starts[j], starts[i]
    end

    for attempt = 1, math.min(50, #starts) do
        local sr, sc = starts[attempt][1], starts[attempt][2]
        if dfs(sr, sc, 1) then
            return pos, path
        end
        -- Reset for next attempt
        visited = emptyBoolGrid(n)
        pos     = emptyGrid(n)
        path    = {}
        nodes   = 0
    end

    -- Fallback: boustrophedon ("snake") order. Straight row-major order is
    -- NOT a valid king-move path (the jump from column n back to column 1
    -- between rows isn't adjacent); snake order keeps every step to an
    -- orthogonal king move, so it's always a genuinely valid Hamiltonian path.
    pos  = emptyGrid(n)
    path = {}
    local v = 0
    for r = 1, n do
        if r % 2 == 1 then
            for c = 1, n do
                v = v + 1
                pos[r][c] = v
                path[v]   = { r, c }
            end
        else
            for c = n, 1, -1 do
                v = v + 1
                pos[r][c] = v
                path[v]   = { r, c }
            end
        end
    end
    return pos, path
end

-- ---------------------------------------------------------------------------
-- HidatoBoard
-- ---------------------------------------------------------------------------

local HidatoBoard = {}
HidatoBoard.__index = HidatoBoard

function HidatoBoard:new(opts)
    opts = opts or {}
    local obj = setmetatable({
        n           = opts.n or DEFAULT_N,
        difficulty  = opts.difficulty or DEFAULT_DIFFICULTY,
        solution    = nil,
        puzzle      = nil,
        user        = nil,
        given       = nil,
        wrong_marks = nil,
        sel_r       = nil,
        sel_c       = nil,
    }, self)
    -- opts.empty: the caller loads a save or generates right after (with
    -- the progress bar), so skip the throwaway puzzle.
    if not opts.empty then obj:generate(obj.difficulty) end
    return obj
end

-- ---------------------------------------------------------------------------
-- Generate
-- ---------------------------------------------------------------------------

-- on_progress (optional): called with a 0..1 fraction while digging.
function HidatoBoard:generate(difficulty, on_progress)
    self.difficulty = difficulty or self.difficulty
    local n         = self.n
    local total     = n * n

    -- 1. Build a random Hamiltonian path
    local sol, path = generatePath(n)
    self.solution = sol

    -- 2. Select clues to reveal: dig one at a time (like sudoku-common's
    -- hole-digging), starting fully revealed and verifying with
    -- countCompletions after each tentative hide, putting the cell back if
    -- that broke uniqueness. Unlike the old "shuffle positions, keep top
    -- ratio%" approach (which never checked whether the remaining clues
    -- still pin down a single path), this guarantees every generated
    -- puzzle has exactly one solution. Endpoints (1 and n*n) always stay
    -- given -- removing either is never attempted.
    local given_ratio = GIVEN_RATIOS[self.difficulty] or 0.25
    local puzzle = emptyGrid(n)
    local given  = emptyBoolGrid(n)
    for k = 1, total do
        local r, c = path[k][1], path[k][2]
        puzzle[r][c] = k
        given[r][c]  = true
    end

    local intermediate = {}
    for k = 2, total - 1 do
        intermediate[#intermediate + 1] = k
    end
    for i = #intermediate, 2, -1 do
        local j = math.random(i)
        intermediate[i], intermediate[j] = intermediate[j], intermediate[i]
    end

    local num_extra   = math.floor((total - 2) * given_ratio)
    local target_hide = (total - 2) - num_extra
    local hidden      = 0
    for i, k in ipairs(intermediate) do
        if hidden >= target_hide then break end
        if on_progress then on_progress(i / #intermediate) end
        local r, c = path[k][1], path[k][2]
        local saved = puzzle[r][c]
        puzzle[r][c] = 0
        given[r][c]  = false
        local solutions, exhausted = countCompletions(puzzle, given, n, 2, NODE_BUDGET_UNIQUENESS)
        if not exhausted and solutions == 1 then
            hidden = hidden + 1
        else
            puzzle[r][c] = saved
            given[r][c]  = true
        end
    end

    self.puzzle      = puzzle
    self.given       = given
    self.user        = emptyGrid(n)
    self.wrong_marks = emptyBoolGrid(n)
    self.sel_r       = nil
    self.sel_c       = nil
end

-- ---------------------------------------------------------------------------
-- Cell access
-- ---------------------------------------------------------------------------

function HidatoBoard:isGiven(r, c)
    return self.given[r] and self.given[r][c] == true
end

function HidatoBoard:getWorkingValue(r, c)
    if self:isGiven(r, c) then
        return self.puzzle[r][c]
    end
    return self.user[r][c]
end

function HidatoBoard:getDisplayValue(r, c)
    return self:getWorkingValue(r, c)
end

function HidatoBoard:selectCell(r, c)
    self.sel_r = r
    self.sel_c = c
end

function HidatoBoard:setCell(r, c, v)
    if self:isGiven(r, c) then return false, "given" end
    local total = self.n * self.n
    if v < 1 or v > total then return false, "range" end
    self.user[r][c]        = v
    self.wrong_marks[r][c] = false
    return true
end

function HidatoBoard:clearCell(r, c)
    if self:isGiven(r, c) then return false, "given" end
    self.user[r][c]        = 0
    self.wrong_marks[r][c] = false
    return true
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

function HidatoBoard:checkConflicts()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            local v = self:getWorkingValue(r, c)
            self.wrong_marks[r][c] = (v ~= 0 and v ~= self.solution[r][c])
        end
    end
end

function HidatoBoard:isSolved()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            if self:getWorkingValue(r, c) ~= self.solution[r][c] then
                return false
            end
        end
    end
    return true
end

function HidatoBoard:getRemainingCells()
    local n   = self.n
    local cnt = 0
    for r = 1, n do
        for c = 1, n do
            if self:getWorkingValue(r, c) == 0 then cnt = cnt + 1 end
        end
    end
    return cnt
end

-- ---------------------------------------------------------------------------
-- Serialization
-- ---------------------------------------------------------------------------

Hint.install(HidatoBoard, {
    getUser     = function(b, r, c) return b.user[r][c] end,
    getSolution = function(b, r, c) return b.solution[r][c] end,
    isGiven     = function(b, r, c) return b:isGiven(r, c) end,
    setCell     = function(b, r, c, v) return b:setCell(r, c, v) end,
    clearCell   = function(b, r, c) return b:clearCell(r, c) end,
})

function HidatoBoard:serialize()
    local n = self.n
    local given_out = emptyBoolGrid(n)
    for r = 1, n do
        for c = 1, n do
            given_out[r][c] = self.given[r][c] and 1 or 0
        end
    end
    local wrong_out = emptyBoolGrid(n)
    for r = 1, n do
        for c = 1, n do
            wrong_out[r][c] = self.wrong_marks[r][c] and 1 or 0
        end
    end
    return {
        n           = n,
        difficulty  = self.difficulty,
        solution    = copyGrid(self.solution, n),
        puzzle      = copyGrid(self.puzzle, n),
        user        = copyGrid(self.user, n),
        given       = given_out,
        wrong_marks = wrong_out,
    }
end

function HidatoBoard:load(data)
    if type(data) ~= "table" or not data.solution then return false end
    local n = data.n or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFFICULTY
    self.solution   = copyGrid(data.solution, n)
    self.puzzle     = copyGrid(data.puzzle or {}, n)
    self.user       = copyGrid(data.user or {}, n)

    self.given = emptyBoolGrid(n)
    if data.given then
        for r = 1, n do
            for c = 1, n do
                local v = data.given[r] and data.given[r][c]
                self.given[r][c] = (v == true or v == 1)
            end
        end
    end

    self.wrong_marks = emptyBoolGrid(n)
    if data.wrong_marks then
        for r = 1, n do
            for c = 1, n do
                local v = data.wrong_marks[r] and data.wrong_marks[r][c]
                self.wrong_marks[r][c] = (v == true or v == 1)
            end
        end
    end

    self.sel_r = nil
    self.sel_c = nil
    return true
end

HidatoBoard.DIRS = DIRS

-- for the specs
HidatoBoard._countCompletions = countCompletions

return HidatoBoard
