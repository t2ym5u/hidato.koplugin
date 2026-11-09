-- Difficulty guarantees for Hidato (see docs/dev/TESTING.md, "Difficulty
-- specs"). Puzzles are graded by logic.lua's tiers: 1 = reach + singles,
-- 2 = neighbours, 3 = short segments, never trial. Easy: tier 1 with at
-- least EASY_GIVEN_RATIO of the clues; Medium: needs tier 2; Hard: tier 2
-- and 3, the fewest clues (a subset of Medium's).
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("Hidato difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    describe("counter", function()
        it("generates uniquely solvable puzzles quickly at every size and difficulty", function()
            for _, n in ipairs({ 5, 6 }) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local worst = 0
                    for seed = 1, 8 do
                        math.randomseed(seed * 7919 + n)
                        local t0 = os.clock()
                        local b = Board:new{ n = n, difficulty = diff }
                        worst = math.max(worst, os.clock() - t0)
                        local count, exhausted = Board._countCompletions(b.puzzle, b.given, n, 2, 10000000)
                        assert.is_false(exhausted)
                        assert.are.equal(1, count, ("n=%d %s seed %d"):format(n, diff, seed))
                    end
                    -- generous: ~0.05 s on a desktop
                    assert.is_true(worst < 2.0, ("n=%d %s took %.2f s"):format(n, diff, worst))
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

        local SEEDS = 30

        local function shown(b)
            local grid, count = {}, 0
            for r = 1, b.n do
                grid[r] = {}
                for c = 1, b.n do
                    grid[r][c] = b.given[r][c] and b.puzzle[r][c] or 0
                    if grid[r][c] ~= 0 then count = count + 1 end
                end
            end
            return grid, count
        end

        local function gen(n, diff, seed)
            math.randomseed(seed)
            local b = Board:new{ n = n, empty = true }
            b:generate(diff)
            return b
        end

        it("every level is solved by logic alone, with the level's rules", function()
            for _, n in ipairs({ 5, 6 }) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local tier = ({ easy = 1, medium = 2, hard = 3 })[diff]
                    for seed = 1, SEEDS do
                        local b = gen(n, diff, seed)
                        local grid = shown(b)
                        local where = ("n=%d %s seed %d"):format(n, diff, seed)
                        local ok, vals = Logic.solve(grid, n, tier)
                        assert.is_true(ok, where)
                        for r = 1, n do
                            for c = 1, n do
                                assert.are.equal(b.solution[r][c], vals[(r - 1) * n + c], where)
                            end
                        end
                        -- Medium and Hard really need more than reach + singles.
                        if diff ~= "easy" then
                            assert.is_false((Logic.solve(grid, n, 1)), where)
                        end
                    end
                end
            end
        end)

        it("Medium and Hard differ, Hard showing a subset of Medium's clues", function()
            for _, n in ipairs({ 5, 6 }) do
                local sums = { easy = 0, medium = 0, hard = 0 }
                for seed = 1, SEEDS do
                    local e, m, h = gen(n, "easy", seed), gen(n, "medium", seed), gen(n, "hard", seed)
                    local _, ce = shown(e)
                    local _, cm = shown(m)
                    local _, ch = shown(h)
                    sums.easy, sums.medium, sums.hard = sums.easy + ce, sums.medium + cm, sums.hard + ch
                    assert.is_true(ch < cm, ("n=%d seed %d: Hard %d clues, Medium %d"):format(n, seed, ch, cm))
                    for r = 1, n do
                        for c = 1, n do
                            if h.given[r][c] then assert.is_true(m.given[r][c]) end
                        end
                    end
                end
                assert.is_true(sums.easy > sums.medium and sums.medium > sums.hard,
                    ("n=%d clue totals %d / %d / %d"):format(n, sums.easy, sums.medium, sums.hard))
            end
        end)

        it("the same seed gives the same puzzle", function()
            for _, n in ipairs({ 5, 6 }) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    for seed = 1, 5 do
                        local a, b = gen(n, diff, seed), gen(n, diff, seed)
                        assert.are.same(a.solution, b.solution)
                        assert.are.same(a.given, b.given)
                    end
                end
            end
        end)

        it("generates quickly at every size and level", function()
            for _, n in ipairs({ 5, 6 }) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local worst = 0
                    for seed = 1, SEEDS do
                        math.randomseed(seed)
                        local b = Board:new{ n = n, empty = true }
                        local t0 = os.clock()
                        b:generate(diff)
                        worst = math.max(worst, os.clock() - t0)
                    end
                    -- generous: ~0.03 s worst on a desktop
                    assert.is_true(worst < 0.5, ("n=%d %s took %.3f s"):format(n, diff, worst))
                end
            end
        end)

        -- Placements needing the neighbour or segment rule (logic.lua's
        -- stats, solved at tier 3): none on Easy, more on Hard than Medium.
        it("harder levels need more neighbour/segment work on averages over seeds", function()
            local AVG_SEEDS = 8
            for _, n in ipairs({ 5, 6 }) do
                local avg = {}
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local sum = 0
                    for seed = 1, AVG_SEEDS do
                        local b = gen(n, diff, 500 + seed)
                        local ok, _, stats = Logic.solve((shown(b)), n, 3)
                        assert.is_true(ok)
                        sum = sum + (stats.neighbour or 0) + (stats.segment or 0)
                    end
                    avg[diff] = sum / AVG_SEEDS
                end
                assert.are.equal(0, avg.easy)
                assert.is_true(avg.easy < avg.medium and avg.medium < avg.hard,
                    ("n=%d: %.1f / %.1f / %.1f"):format(n, avg.easy, avg.medium, avg.hard))
            end
        end)

        -- Generation is bounded by DIG_ATTEMPTS and node budgets, never by
        -- time: with a clock that jumps 1000 s at every read, a seed still
        -- gives the same puzzle.
        it("generation never reads the clock", function()
            local oc, ot = os.clock, os.time
            for _, n in ipairs({ 4, 5 }) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local a = gen(n, diff, 61 + n)
                    local t = 0
                    os.clock = function() t = t + 1000; return t end
                    os.time = function(x) if x then return ot(x) end; t = t + 1000; return t end
                    local ok, b = pcall(gen, n, diff, 61 + n)
                    os.clock, os.time = oc, ot
                    assert.is_true(ok, tostring(b))
                    assert.are.same(a.solution, b.solution)
                    assert.are.same(a.given, b.given)
                end
            end
            for _, f in ipairs({ "board.lua", "logic.lua" }) do
                local src = assert(io.open(DIR .. f)):read("*a")
                assert.is_nil(src:find("os%.clock"), f)
                assert.is_nil(src:find("os%.time"), f)
            end
        end)
    end)
end)
