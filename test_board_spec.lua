local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("HidatoBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    -- Regression guard for the 2026-07-21 bug: dfs's success check was
    -- `step > total` (unreachable, since dfs is never called past `total`),
    -- so generation always backtracked the final placement and either hung
    -- or fell back to an invalid row-major path. These tests assert the
    -- solution is a genuine king-move Hamiltonian path -- the property that
    -- was silently violated before the fix.
    local function newBoard(n, diff)
        math.randomseed(42)
        return Board:new{ n = n or 5, difficulty = diff or "easy" }
    end

    local function isKingAdjacent(r1, c1, r2, c2)
        local dr, dc = math.abs(r1 - r2), math.abs(c1 - c2)
        return dr <= 1 and dc <= 1 and (dr + dc) > 0
    end

    describe("construction", function()
        it("creates a 5×5 board by default and auto-generates", function()
            local b = Board:new()
            assert.are.equal(5, b.n)
            assert.is_not_nil(b.solution)
        end)
    end)

    describe("generate", function()
        it("solution is a valid king-move Hamiltonian path (1..n²)", function()
            local b = newBoard(5)
            local n = b.n
            local total = n * n
            local pos = {}
            for r = 1, n do
                for c = 1, n do
                    local v = b.solution[r][c]
                    assert.is_true(v >= 1 and v <= total, ("out-of-range value %s"):format(tostring(v)))
                    assert.is_nil(pos[v], ("value %d appears twice"):format(v))
                    pos[v] = { r, c }
                end
            end
            for v = 1, total - 1 do
                local a, b2 = pos[v], pos[v + 1]
                assert.is_true(isKingAdjacent(a[1], a[2], b2[1], b2[2]),
                    ("values %d and %d are not king-adjacent"):format(v, v + 1))
            end
        end)

        it("reveals cell 1 and n² as given", function()
            local b = newBoard(5)
            local n = b.n
            local total = n * n
            local found1, foundN = false, false
            for r = 1, n do
                for c = 1, n do
                    if b.given[r][c] then
                        if b.puzzle[r][c] == 1 then found1 = true end
                        if b.puzzle[r][c] == total then foundN = true end
                    end
                end
            end
            assert.is_true(found1)
            assert.is_true(foundN)
        end)

        it("runs across all sizes/difficulties without hanging or erroring", function()
            for _, n in ipairs({ 4, 5, 6 }) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    math.randomseed(n * 100 + #diff)
                    local ok = pcall(function() Board:new{ n = n, difficulty = diff } end)
                    assert.is_true(ok, ("generate failed for n=%d diff=%s"):format(n, diff))
                end
            end
        end)
    end)

    -- 1.5.0: the completion counter prunes (next given out of reach, a
    -- cell left with no way in and out, cells that no longer fit any gap
    -- between givens) and memoises positions (6x6 Hard took up to ~1 s on
    -- a desktop). Keep the old counter here and check the two agree
    -- (generation's uniqueness and speed: test_difficulty_spec.lua).
    describe("counter", function()
        local DIRS = Board and Board.DIRS or {
            { -1, -1 }, { -1, 0 }, { -1, 1 },
            {  0, -1 },            {  0, 1 },
            {  1, -1 }, {  1, 0 }, {  1, 1 },
        }

        -- The pre-1.5.0 counter, verbatim.
        local function oldCountCompletions(puzzle, given, n, limit, node_budget)
            local total = n * n
            local cell_of_num = {}
            local num_of_cell = {}
            for r = 1, n do num_of_cell[r] = {} end

            local solutions, nodes, exhausted = 0, 0, false

            local function search(num)
                if solutions >= limit or exhausted then return end
                nodes = nodes + 1
                if nodes > node_budget then exhausted = true; return end
                if num > total then solutions = solutions + 1; return end

                local given_pos = nil
                if num == 1 then
                    for r = 1, n do
                        for c = 1, n do
                            if given[r][c] and puzzle[r][c] == 1 then given_pos = { r, c }; break end
                        end
                        if given_pos then break end
                    end
                    if given_pos then
                        cell_of_num[1] = given_pos
                        num_of_cell[given_pos[1]][given_pos[2]] = 1
                        search(2)
                        num_of_cell[given_pos[1]][given_pos[2]] = nil
                    else
                        for r = 1, n do
                            for c = 1, n do
                                if not num_of_cell[r][c] then
                                    cell_of_num[1] = { r, c }
                                    num_of_cell[r][c] = 1
                                    search(2)
                                    num_of_cell[r][c] = nil
                                    if solutions >= limit or exhausted then return end
                                end
                            end
                        end
                    end
                    return
                end

                for r = 1, n do
                    for c = 1, n do
                        if given[r][c] and puzzle[r][c] == num then given_pos = { r, c }; break end
                    end
                    if given_pos then break end
                end

                local prev = cell_of_num[num - 1]
                local candidates = {}
                for _, d in ipairs(DIRS) do
                    local nr, nc = prev[1] + d[1], prev[2] + d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n and not num_of_cell[nr][nc] then
                        candidates[#candidates + 1] = { nr, nc }
                    end
                end
                if given_pos then
                    local ok = false
                    for _, cand in ipairs(candidates) do
                        if cand[1] == given_pos[1] and cand[2] == given_pos[2] then ok = true; break end
                    end
                    if ok then
                        cell_of_num[num] = given_pos
                        num_of_cell[given_pos[1]][given_pos[2]] = num
                        search(num + 1)
                        num_of_cell[given_pos[1]][given_pos[2]] = nil
                    end
                else
                    for _, cand in ipairs(candidates) do
                        if not given[cand[1]][cand[2]] then
                            cell_of_num[num] = cand
                            num_of_cell[cand[1]][cand[2]] = num
                            search(num + 1)
                            num_of_cell[cand[1]][cand[2]] = nil
                            if solutions >= limit or exhausted then return end
                        end
                    end
                end
            end

            search(1)
            return solutions, exhausted
        end
        it("counts the same completions as the old counter on random instances", function()
            for _, n in ipairs({ 5, 6 }) do
                for seed = 1, 30 do
                    math.randomseed(seed * 31337 + n)
                    local b = Board:new{ n = n, difficulty = "easy" }
                    local puzzle, given = {}, {}
                    local ratio = math.random() * 0.6 + 0.2
                    for r = 1, n do
                        puzzle[r], given[r] = {}, {}
                        for c = 1, n do
                            local v = b.solution[r][c]
                            local keep = v == 1 or v == n * n or math.random() < ratio
                            puzzle[r][c] = keep and v or 0
                            given[r][c] = keep
                        end
                    end
                    local so, eo = oldCountCompletions(puzzle, given, n, 2, 400000)
                    local sn, en = Board._countCompletions(puzzle, given, n, 2, 4000000)
                    if not eo then
                        assert.is_false(en)
                        assert.are.equal(so, sn, ("n=%d seed %d"):format(n, seed))
                    end
                end
            end
        end)
    end)

    -- 1.6.0: clues are removed only while logic.lua (no trial, no
    -- search) can still fill the grid, and the levels are graded by the
    -- rules it needs. Before, Medium and Hard dug to the same minimal
    -- (unique but often guess-only) puzzle on every seed.
    describe("logic grading", function()
        local Logic
        setup(function()
            Logic = dofile(DIR .. "logic.lua")
        end)

        it("only fills a grid when its solution is unique, and fills it right", function()
            local solved = 0
            for seed = 1, 400 do
                local n = 4 + seed % 3
                math.randomseed(seed * 7 + 3)
                local b = Board:new{ n = n, difficulty = "easy" }
                local ratio = math.random() * 0.5 + 0.15
                local puzzle, given = {}, {}
                for r = 1, n do
                    puzzle[r], given[r] = {}, {}
                    for c = 1, n do
                        local v = b.solution[r][c]
                        local keep = v == 1 or v == n * n or math.random() < ratio
                        puzzle[r][c] = keep and v or 0
                        given[r][c] = keep
                    end
                end
                local ok, vals = Logic.solve(puzzle, n, 3)
                if ok then
                    solved = solved + 1
                    local count, exhausted = Board._countCompletions(puzzle, given, n, 2, 4000000)
                    assert.is_false(exhausted)
                    assert.are.equal(1, count, ("n=%d seed %d"):format(n, seed))
                    for r = 1, n do
                        for c = 1, n do
                            assert.are.equal(b.solution[r][c], vals[(r - 1) * n + c])
                        end
                    end
                end
            end
            assert.is_true(solved > 20)
        end)
    end)

    describe("setCell / clearCell / isSolved", function()
        it("filling every cell with the solution values solves the board", function()
            local b = newBoard(5)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    if not b:isGiven(r, c) then
                        b:setCell(r, c, b.solution[r][c])
                    end
                end
            end
            assert.is_true(b:isSolved())
        end)

        it("checkConflicts flags a wrong value", function()
            local b = newBoard(5)
            local n = b.n
            local r, c
            for rr = 1, n do
                for cc = 1, n do
                    if not b:isGiven(rr, cc) then r, c = rr, cc; goto done end
                end
            end
            ::done::
            assert.is_not_nil(r)
            local wrong_value = (b.solution[r][c] % (n * n)) + 1
            b:setCell(r, c, wrong_value)
            b:checkConflicts()
            assert.is_true(b.wrong_marks[r][c])
        end)
    end)

    describe("serialize / load", function()
        it("round-trips puzzle, given and user state", function()
            local b = newBoard(5)
            local n = b.n
            local r, c
            for rr = 1, n do
                for cc = 1, n do
                    if not b:isGiven(rr, cc) then r, c = rr, cc; goto done end
                end
            end
            ::done::
            b:setCell(r, c, b.solution[r][c])

            local data = b:serialize()
            local b2   = Board:new{ n = n }
            local ok   = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            assert.are.equal(b.solution[r][c], b2:getWorkingValue(r, c))
        end)

        it("loads a save from before 1.6.0", function()
            -- 1.5.x format: given/wrong_marks as 1/0, same fields as now.
            local data = {
                n = 5, difficulty = "hard",
                solution = {
                    { 1, 2, 3, 4, 5 }, { 10, 9, 8, 7, 6 }, { 11, 12, 13, 14, 15 },
                    { 20, 19, 18, 17, 16 }, { 21, 22, 23, 24, 25 },
                },
                puzzle = {
                    { 1, 0, 0, 0, 5 }, { 0, 0, 8, 0, 0 }, { 0, 0, 0, 0, 15 },
                    { 0, 19, 0, 0, 0 }, { 21, 0, 0, 0, 25 },
                },
                user = {
                    { 0, 2, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 },
                    { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 },
                },
                given = {
                    { 1, 0, 0, 0, 1 }, { 0, 0, 1, 0, 0 }, { 0, 0, 0, 0, 1 },
                    { 0, 1, 0, 0, 0 }, { 1, 0, 0, 0, 1 },
                },
                wrong_marks = {
                    { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 },
                    { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 },
                },
            }
            local b = Board:new{ n = 5, empty = true }
            assert.is_true(b:load(data))
            assert.are.equal("hard", b.difficulty)
            assert.is_true(b:isGiven(2, 3))
            assert.are.equal(8, b:getWorkingValue(2, 3))
            assert.are.equal(2, b:getWorkingValue(1, 2))
            assert.are.equal(25 - 8, b:getRemainingCells())
            assert.is_false(b:isSolved())
        end)

        it("load returns false for invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)
end)
