-- title:  Tank Runner
-- author: ssinyakov + Cursor
-- desc:   Ortho maze prototype (TIC-80 Lua)
-- script: lua

-- ============================================================
-- Controls (default TIC-80):
--   Left/Right: steer
--   A: shoot
--   B: brake
--   X: pause
-- ============================================================

local W, H = 240, 136

-- Button indices in TIC-80:
-- 0 Up, 1 Down, 2 Left, 3 Right, 4 A, 5 B, 6 X, 7 Y
local BTN_LEFT  = 2
local BTN_RIGHT = 3
local BTN_A     = 4
local BTN_B     = 5
local BTN_X     = 6

-- Product promise: a 3-7 minute score-chasing tank run where the
-- player reads the road, dodges hazards and shoots a path forward.
local GAME_TITLE = "TANK RUNNER"
local GAME_TAGLINE = "DODGE. BREAK THROUGH. GO FAR."

-- ============================================================
-- ORTHO MODE (no perspective)
-- We render the maze as a rectangular grid scrolling downward.
-- ============================================================
local TILE = 16
local FIELD_COLS = 9
local FIELD_W = FIELD_COLS * TILE
local FIELD_X0 = math.floor((W - FIELD_W) / 2)
local FIELD_Y0 = 0
local FIELD_H = H

local TANK_Y = H - TILE - 6
local TANK_W = TILE
local TANK_H = TILE

-- ============================================================
-- Tuning (game feel)
-- ============================================================
local HEALTH_MAX = 100
local DAMAGE_MAZE = 10      -- 10% HP on maze wall collision
local DAMAGE_OBSTACLE = 100 -- 100% (instant death) on obstacle collision

local SPEED_MIN = 0.6
local SPEED_MAX = 2.6
local SPEED_ACCEL = 0.02
local SPEED_BRAKE_DECEL = 0.06
local SPEED_ON_MAZE_HIT = 0.9 -- slow down on maze bump

-- Biome speed progression: every stage starts controlled and ramps up.
local BIOME_SPEED_MIN = { 1.0, 1.2, 1.4 }
local BIOME_SPEED_MAX = { 1.6, 1.9, 2.2 }

-- Debug: use a solid sprite to visualize maze cells clearly.
-- You said you made sprite #208 solid white for this purpose.
local DEBUG_MAZE = false
local DEBUG_MAZE_SPR = 208 -- 8×8 sprite, drawn scaled to 16×16
local DEBUG_HUD = false

-- ============================================================
-- Sprites (base ids).
-- NOTE: 16×16 uses a 2×2 block: S, S+1, S+16, S+17.
-- Keep this aligned with ASSETS.md and your actual sprite sheet.
-- ============================================================
local SPR = {
  tank_body_0 = 0,
  tank_body_1 = 2,

  -- angles: a0..a6 = -30..+30
  tank_turret = { 4, 6, 8, 10, 12, 14, 32 },
  tank_barrel = { 34, 36, 38, 40, 42, 44, 46 },

  obs_tree = 64,
  obs_rock = 66,
  obs_wall_intact = 68,
  obs_wall_cracked = 70,
  obs_wall_broken = 72,

  -- desert
  obs_cactus = 74,
  obs_bush = 76,
  obs_ruin_intact = 78,
  obs_ruin_broken = 96,

  -- city surfaces (16×16)
  tile_city_asphalt = 152,
  tile_city_crosswalk = 154,
  tile_city_puddle = 156,

  -- city obstacles (16×16)
  obs_city_car = 158,
  obs_city_dumpster = 178,

  item_ammo_box = 150, -- 16×16
  item_health = 210, -- 8×8 (we draw it scaled to 16×16)
  ui_ammo = 192, -- 8×8

  fx_bullet = 128,
  fx_muzzle = { 129, 130 },
  fx_dust = { 131, 132 },
  fx_debris = { 133, 134 },
}

-- Named audio slots. The game remains playable before sounds are authored
-- in TIC-80's SFX editor.
local SFX = {
  shoot = 0,
  hit = 1,
  break_wall = 2,
  pickup = 3,
  crash = 4,
  transition = 5,
  select = 6,
}
local MUSIC_RUN = 0

local function play_sfx(id, note, duration, channel, volume, speed)
  if sfx then sfx(id, note or -1, duration or 12, channel or 0, volume or 8, speed or 0) end
end

-- ============================================================
-- Preset Maze (prototype)
-- 9 columns; each row string must be length 9.
-- Legend:
--   # = maze wall (solid)
--   W = maze wall (destructible, 1 hit)
--   A = ammo pickup spawn
--   H = health pickup spawn (sprite #210)
--   X = deadly obstacle (instant death on collision)
--   O = city obstacle (deadly): car / dumpster (biome 3 only)
--   C = city surface: crosswalk (visual)
--   P = city surface: puddle (visual)
--   . = empty (in biome 3 treated as asphalt visual)
-- ============================================================
local MAZE_COLS = 9

-- Maze for biome 1 (forest)
local MAZE = {
  "#.......#",
  "###...###",
  "###...###",
  "##.....##",
  "##..A..##",
  "##...####",
  "##...####",
  "#...#####",
  "#...#####",
  "##...####",
  "###...###",
  "###W.W###",
  "###...###",
  "####...##",
  "####.A.##",
  "#####...#",
  "#####...#",
  "####...##",
  "###...###",
  "###.W.###",
  "###...###",
  "##...####",
  "##..A..##",
  "##.....##",
}

-- Maze for biome 2 (desert) – same length as MAZE
local MAZE2 = {
  -- wide entrance
  "#.......#",
  "##.....##",
  "##.....##",
  -- pinch + gate
  "###...###",
  "###.W.###",
  "###...###",
  -- shift corridor right, ammo in corridor
  "####...##",
  "####.A.##",
  "####...##",
  -- shift corridor left, health in corridor
  "##...####",
  "##.H.####",
  "##...####",
  -- zigzag section
  "###...###",
  "####...##",
  "#####...#",
  "####...##",
  "###...###",
  -- double gate
  "##.W.W.##",
  "##.....##",
  -- tighter segment (but still passable)
  "###...###",
  "###...###",
  "###.A.###",
  "###...###",
  "#.......#",
}

-- Maze for biome 3 (city) – same length as MAZE
-- X uses instant death.
local MAZE3 = {
  "#.......#",
  -- street with parked obstacle
  "##..O..##",
  "##.....##",
  -- crosswalk band
  "##.C.C.##",
  "##.C.C.##",
  -- barricade gate
  "###.W.###",
  "##.....##",
  -- zigzag alleys
  "#####...#",
  "####...##",
  "###...###",
  -- puddle + pickup pocket
  "##..P..##",
  "##..A..##",
  "##..P..##",
  -- deadly hazard (construction / pit)
  "###...###",
  "###.X.###",
  "###...###",
  -- recovery + health
  "##.....##",
  "##..H..##",
  "##.....##",
  -- double barricade
  "##.W.W.##",
  -- exit section with another parked obstacle
  "##..O..##",
  "####...##",
  "####.A.##",
  "#.......#",
}

-- (by request) keep 3 full-length maps, not fragmented.

-- Runtime level construction uses short, hand-authored chunks. This keeps
-- runs varied without giving up the fairness of authored routes.
local TUTORIAL_ROWS = {
  "#.......#",
  "##.....##",
  "##.....##",
  "###...###",
  "###.A.###",
  "###...###",
  "###.W.###",
  "###...###",
  "##.....##",
  "##..X..##",
  "##.....##",
  "#.......#",
}

local function slice_rows(rows, first, last)
  local out = {}
  for i = first, math.min(last, #rows) do out[#out + 1] = rows[i] end
  return out
end

local BIOME_SEGMENTS = {
  {
    slice_rows(MAZE, 1, 6),
    slice_rows(MAZE, 7, 12),
    slice_rows(MAZE, 13, 18),
    slice_rows(MAZE, 19, 24),
  },
  {
    slice_rows(MAZE2, 1, 6),
    slice_rows(MAZE2, 7, 12),
    slice_rows(MAZE2, 13, 18),
    slice_rows(MAZE2, 19, 24),
  },
  {
    slice_rows(MAZE3, 1, 6),
    slice_rows(MAZE3, 7, 12),
    slice_rows(MAZE3, 13, 18),
    slice_rows(MAZE3, 19, 25),
  },
}

local CAPSTONE_SEGMENTS = {
  {
    "##.....##",
    "##.W.W.##",
    "##.....##",
    "###.W.###",
    "##.....##",
  },
  {
    "#.......#",
    "##W...W##",
    "###.W.###",
    "##.....##",
    "#.......#",
  },
  {
    "##..O..##",
    "##.....##",
    "##.W.W.##",
    "##..O..##",
    "#.......#",
  },
}

local STAGE_DISTANCE = { 4800, 5700, 6600 }
local DISTANCE_TO_METERS = 0.1
local TUTORIAL_DISTANCE = 900
local NEAR_MISS_X = 5

local UPGRADES = {
  { id = "armor", name = "ARMOR", desc = "WALL DAMAGE -4" },
  { id = "mag", name = "BIG MAG", desc = "MAGAZINE +2" },
  { id = "rapid", name = "RAPID FIRE", desc = "FASTER SHOTS" },
  { id = "handling", name = "GRIP", desc = "SHARPER STEERING" },
  { id = "score", name = "DAREDEVIL", desc = "SCORE BONUS +50%" },
}

local AMMO_TOTAL_START = 20
local AMMO_MAG_SIZE = 6
local AMMO_RELOAD_FRAMES = 60
local AMMO_PICKUP_AMOUNT = 10

-- destructible visuals
local WALL_CRACKED_CHANCE = 0.35
local WALL_BROKEN_TTL = 16
local HEALTH_PICKUP_AMOUNT = 25

local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function iround(x)
  return math.floor(x + 0.5)
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function aabb(ax, ay, aw, ah, bx, by, bw, bh)
  return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end

local function overlap_amount(a0, a1, b0, b1)
  local lo = math.max(a0, b0)
  local hi = math.min(a1, b1)
  return hi - lo
end

-- Forgiving collision: only count a hit if the tank overlaps the cell
-- by a meaningful amount (prevents "I died before touching" feeling).
local HIT_MARGIN = 0          -- shrink obstacle hitbox by N pixels on each side (optional)
local HIT_OVERLAP_PX = 8      -- require ~half-tile overlap before damage/death triggers

local state = {
  inited = false,
  mode = "title",
  game_over = false,
  t = 0,
  biome = 1, -- 1 forest, 2 desert, 3 city
  biome_t = 0,
  run_distance = 0,
  stage_distance = 0,
  high_score = 0,
  death_reason = "",
  is_victory = false,
  freeze_t = 0,
  flash_t = 0,
  tutorial_row = 1,
  segment_queue = {},
  last_segment = 0,
  capstone_queued = false,
  upgrade_options = {},
  upgrade_choice = 1,
  upgrades = {},
  wall_damage = DAMAGE_MAZE,
  mag_size = AMMO_MAG_SIZE,
  shoot_delay = 8,
  steer_power = 1.15,
  score_mult = 1,
  player = {
    x = 0,
    vx = 0,
    speed = 1.0,
    hp = HEALTH_MAX,
    shoot_cd = 0,
    ammo_total = 0,
    ammo_in_mag = 0,
    reload_t = 0,
    hit_cd = 0,
  },
  bullets = {},
  pickups = {},
  fx = {},
  obstacles = {},
  surfaces = {}, -- biome 3 surfaces (city visuals)
  spawn_cd = 0,
  score = 0,
  combo = 0,
  combo_t = 0,
  stats = {
    damage_taken = 0,
    walls_broken = 0,
    near_misses = 0,
    health_pickups = 0,
    max_combo = 0,
  },
  earned_challenges = {},
}

local function biome_colors()
  if state.biome == 1 then return 1, 2, 3 end
  if state.biome == 2 then return 4, 5, 6 end
  -- city: dark asphalt / concrete
  return 0, 5, 6
end

local function biome_speed_range(biome)
  local i = clamp(biome, 1, 3)
  return BIOME_SPEED_MIN[i], BIOME_SPEED_MAX[i]
end

local function desired_speed_for_biome()
  local smin, smax = biome_speed_range(state.biome)
  local t = clamp(state.stage_distance / STAGE_DISTANCE[state.biome], 0, 1)
  return lerp(smin, smax, t), smin, smax
end

local function reset_game()
  state.mode = "play"
  state.game_over = false
  state.t = 0
  state.biome = 1
  state.biome_t = 0
  state.run_distance = 0
  state.stage_distance = 0
  state.death_reason = ""
  state.is_victory = false
  state.freeze_t = 0
  state.flash_t = 0
  state.tutorial_row = 1
  state.segment_queue = {}
  state.last_segment = 0
  state.capstone_queued = false
  state.upgrade_options = {}
  state.upgrade_choice = 1
  state.upgrades = {}
  state.wall_damage = DAMAGE_MAZE
  state.mag_size = AMMO_MAG_SIZE
  state.shoot_delay = 8
  state.steer_power = 1.15
  state.score_mult = 1

  local p = state.player
  p.x = FIELD_X0 + math.floor((FIELD_W - TANK_W) / 2)
  p.vx = 0
  p.speed = BIOME_SPEED_MIN[1]
  p.hp = HEALTH_MAX
  p.shoot_cd = 0
  p.hit_cd = 0

  p.ammo_total = AMMO_TOTAL_START
  p.ammo_in_mag = 0
  p.reload_t = 0
  local load = math.min(state.mag_size, p.ammo_total)
  p.ammo_in_mag = load
  p.ammo_total = p.ammo_total - load

  state.bullets = {}
  state.pickups = {}
  state.fx = {}
  state.obstacles = {}
  state.surfaces = {}
  state.spawn_cd = 0
  state.score = 0
  state.combo = 0
  state.combo_t = 0
  state.stats = {
    damage_taken = 0,
    walls_broken = 0,
    near_misses = 0,
    health_pickups = 0,
    max_combo = 0,
  }
  state.earned_challenges = {}
  if music then music(MUSIC_RUN, 0, 0, true) end
end

local function col_to_x(col)
  return FIELD_X0 + (col - 1) * TILE
end

local function add_fx(kind, x, y, ttl)
  state.fx[#state.fx + 1] = { kind = kind, x = x, y = y, t = ttl or 10 }
end

local function start_reload()
  local p = state.player
  if p.reload_t > 0 then return end
  if p.ammo_in_mag > 0 then return end
  if p.ammo_total <= 0 then return end
  p.reload_t = AMMO_RELOAD_FRAMES
end

local function fire()
  local p = state.player
  if p.shoot_cd > 0 then return end
  if p.reload_t > 0 then return end
  if p.ammo_in_mag <= 0 then
    start_reload()
    return
  end

  p.shoot_cd = state.shoot_delay
  p.ammo_in_mag = p.ammo_in_mag - 1

  state.bullets[#state.bullets + 1] = {
    x = p.x + 8,
    y = TANK_Y,
    v = 3.2,
  }

  add_fx("muzzle", p.x + 10, TANK_Y + 2, 5)
  play_sfx(SFX.shoot, -1, 8, 0, 6)

  if p.ammo_in_mag <= 0 then start_reload() end
end

local function angle_index()
  local center = FIELD_X0 + (FIELD_W - TANK_W) / 2
  local denom = (FIELD_W / 2)
  local x = clamp((state.player.x - center) / denom, -1, 1)
  local idx = 4 + iround(x * 3)
  return clamp(idx, 1, 7)
end

local function queue_next_segment()
  local pool = BIOME_SEGMENTS[state.biome]
  local pick = math.random(1, #pool)
  if #pool > 1 and pick == state.last_segment then
    pick = (pick % #pool) + 1
  end
  state.last_segment = pick
  state.segment_queue = {}
  for i = 1, #pool[pick] do
    state.segment_queue[#state.segment_queue + 1] = pool[pick][i]
  end
end

local function next_level_row()
  if state.biome == 1 and state.run_distance < TUTORIAL_DISTANCE and
     state.tutorial_row <= #TUTORIAL_ROWS then
    local row = TUTORIAL_ROWS[state.tutorial_row]
    state.tutorial_row = state.tutorial_row + 1
    return row
  end
  if not state.capstone_queued and
     state.stage_distance >= STAGE_DISTANCE[state.biome] - 450 and
     #state.segment_queue == 0 then
    state.capstone_queued = true
    for i = 1, #CAPSTONE_SEGMENTS[state.biome] do
      state.segment_queue[#state.segment_queue + 1] = CAPSTONE_SEGMENTS[state.biome][i]
    end
  end
  if state.capstone_queued and #state.segment_queue == 0 then
    return "#.......#"
  end
  if #state.segment_queue == 0 then queue_next_segment() end
  local row = state.segment_queue[1]
  table.remove(state.segment_queue, 1)
  return row
end

local function spawn_maze_row()
  local row = next_level_row()
  local y = -TILE

  for col = 1, MAZE_COLS do
    local ch = row:sub(col, col)
    local x = col_to_x(col)

    -- biome 3: surfaces are visuals only (no physics)
    if state.biome == 3 and ch ~= "#" and ch ~= "W" and ch ~= "X" and ch ~= "O" then
      local st = "asphalt"
      if ch == "C" then st = "crosswalk"
      elseif ch == "P" then st = "puddle"
      end
      state.surfaces[#state.surfaces + 1] = { typ = st, x = x, y = y }
    end

    if ch == "#" then
      local typ = (col % 2 == 0) and 1 or 2
      state.obstacles[#state.obstacles + 1] = { kind = "maze", typ = typ, x = x, y = y, hp = 1 }
    elseif ch == "X" then
      state.obstacles[#state.obstacles + 1] = { kind = "obstacle", typ = 2, x = x, y = y, hp = 1 }
    elseif ch == "O" then
      -- city deadly obstacles (car/dumpster)
      local typ = (col % 2 == 0) and 1 or 2
      state.obstacles[#state.obstacles + 1] = { kind = "obstacle", typ = typ, x = x, y = y, hp = 1 }
    elseif ch == "A" then
      state.pickups[#state.pickups + 1] = { typ = "ammo", x = x, y = y }
    elseif ch == "H" then
      state.pickups[#state.pickups + 1] = { typ = "health", x = x, y = y }
    elseif ch == "W" then
      -- non-gate destructible segment (fallback, if you ever use W without wanting a full-width gate)
      local deco = (math.random() < WALL_CRACKED_CHANCE) and "cracked" or "intact"
      state.obstacles[#state.obstacles + 1] = {
        kind = "maze",
        typ = 3,
        x = x,
        y = y,
        hp = 1,
        v = deco,
        broken_t = 0,
        scored = false,
      }
    end
  end
end

local function clear_world()
  state.obstacles = {}
  state.pickups = {}
  state.bullets = {}
  state.fx = {}
  state.surfaces = {}
  state.segment_queue = {}
  state.last_segment = 0
  state.capstone_queued = false
  state.spawn_cd = 0
end

local function finish_run(reason, victory)
  state.mode = "gameover"
  state.game_over = true
  state.death_reason = reason or "RUN ENDED"
  state.is_victory = victory or false
  local stats = state.stats
  state.earned_challenges = {}
  if stats.damage_taken == 0 then
    state.earned_challenges[#state.earned_challenges + 1] = "UNTOUCHABLE"
  end
  if stats.walls_broken >= 8 then
    state.earned_challenges[#state.earned_challenges + 1] = "DEMOLITION"
  end
  if stats.near_misses >= 5 then
    state.earned_challenges[#state.earned_challenges + 1] = "CLOSE CALL"
  end
  if stats.health_pickups == 0 and state.run_distance >= STAGE_DISTANCE[1] then
    state.earned_challenges[#state.earned_challenges + 1] = "NO REPAIRS"
  end
  if stats.max_combo >= 5 then
    state.earned_challenges[#state.earned_challenges + 1] = "COMBO ACE"
  end
  if state.score > state.high_score then
    state.high_score = state.score
    if pmem then pmem(0, state.high_score) end
  end
end

local function begin_upgrade()
  local first = math.random(1, #UPGRADES)
  local second = math.random(1, #UPGRADES - 1)
  if second >= first then second = second + 1 end
  state.upgrade_options = { UPGRADES[first], UPGRADES[second] }
  state.upgrade_choice = 1
  state.mode = "upgrade"
  clear_world()
  play_sfx(SFX.transition, -1, 18, 1, 7)
end

local function apply_upgrade(upgrade)
  state.upgrades[upgrade.id] = (state.upgrades[upgrade.id] or 0) + 1
  if upgrade.id == "armor" then
    state.wall_damage = math.max(2, state.wall_damage - 4)
  elseif upgrade.id == "mag" then
    state.mag_size = state.mag_size + 2
    state.player.ammo_in_mag = state.player.ammo_in_mag + 2
  elseif upgrade.id == "rapid" then
    state.shoot_delay = math.max(4, state.shoot_delay - 2)
  elseif upgrade.id == "handling" then
    state.steer_power = state.steer_power + 0.22
  elseif upgrade.id == "score" then
    state.score_mult = state.score_mult + 0.5
  end

  state.biome = state.biome + 1
  state.stage_distance = 0
  state.biome_t = 0
  local _, smin = desired_speed_for_biome()
  state.player.speed = smin
  state.mode = "play"
  state.flash_t = 10
  play_sfx(SFX.select, -1, 10, 1, 7)
end

local function update_progress()
  state.biome_t = state.biome_t + 1
  state.run_distance = state.run_distance + state.player.speed
  state.stage_distance = state.stage_distance + state.player.speed
  if state.biome_t % 10 == 0 then
    state.score = state.score + math.max(1, math.floor(state.player.speed * state.score_mult))
  end

  if state.combo_t > 0 then
    state.combo_t = state.combo_t - 1
  else
    state.combo = 0
  end

  if state.stage_distance >= STAGE_DISTANCE[state.biome] then
    if state.biome >= 3 then
      finish_run("CITY CLEARED", true)
    else
      begin_upgrade()
    end
  end
end

local function update_surfaces()
  local out = {}
  for i = 1, #state.surfaces do
    local s = state.surfaces[i]
    s.y = s.y + state.player.speed
    if s.y < H + TILE then out[#out + 1] = s end
  end
  state.surfaces = out
end

local function update_player()
  local p = state.player

  local steer = 0
  if btn(BTN_LEFT) then steer = steer - 1 end
  if btn(BTN_RIGHT) then steer = steer + 1 end

  p.vx = p.vx * 0.72 + steer * state.steer_power
  p.x = clamp(p.x + p.vx, FIELD_X0, FIELD_X0 + FIELD_W - TANK_W)

  local target, smin, smax = desired_speed_for_biome()
  if btn(BTN_B) then
    p.speed = clamp(p.speed - SPEED_BRAKE_DECEL, SPEED_MIN, smax)
  else
    if p.speed < target then
      p.speed = math.min(target, p.speed + SPEED_ACCEL)
    end
    p.speed = clamp(p.speed, smin, smax)
  end

  if p.shoot_cd > 0 then p.shoot_cd = p.shoot_cd - 1 end
  if p.hit_cd > 0 then p.hit_cd = p.hit_cd - 1 end

  if p.reload_t > 0 then
    p.reload_t = p.reload_t - 1
    if p.reload_t <= 0 then
      local load = math.min(state.mag_size, p.ammo_total)
      p.ammo_in_mag = load
      p.ammo_total = p.ammo_total - load
    end
  end

  if btnp(BTN_A) then fire() end

  if state.t % 10 == 0 and p.speed > 0.9 then
    add_fx("dust", p.x + 4 + math.random(0, 8), TANK_Y + 13, 12)
  end
end

local function draw_surfaces()
  if state.biome ~= 3 then return end
  for i = 1, #state.surfaces do
    local s = state.surfaces[i]
    local base = SPR.tile_city_asphalt
    if s.typ == "crosswalk" then base = SPR.tile_city_crosswalk
    elseif s.typ == "puddle" then base = SPR.tile_city_puddle
    end
    spr(base, math.floor(s.x), math.floor(s.y), 0, 1, 0, 0, 2, 2)
  end
end

local function update_spawn()
  state.spawn_cd = state.spawn_cd - 1
  if state.spawn_cd <= 0 then
    spawn_maze_row()
    local desired_px = 22
    local frames = math.floor(desired_px / math.max(0.1, state.player.speed))
    state.spawn_cd = clamp(frames + math.random(-1, 1), 8, 20)
  end
end

local function update_obstacles()
  local out = {}
  for i = 1, #state.obstacles do
    local o = state.obstacles[i]
    o.y = o.y + state.player.speed

    if not o.near_scored and o.hp > 0 and o.kind == "obstacle" and
       o.y > TANK_Y + TANK_H then
      local p = state.player
      local gap = math.max(o.x - (p.x + TANK_W), p.x - (o.x + TILE))
      if gap >= 0 and gap <= NEAR_MISS_X then
        state.combo = state.combo + 1
        state.combo_t = 120
        state.stats.near_misses = state.stats.near_misses + 1
        state.stats.max_combo = math.max(state.stats.max_combo, state.combo)
        state.score = state.score + math.floor((15 + state.combo * 5) * state.score_mult)
        state.flash_t = 3
      end
      o.near_scored = true
    end

    if o.hp > 0 and o.y < H + TILE then
      out[#out + 1] = o
    elseif o.hp <= 0 then
      if o.broken_t and o.broken_t > 0 and o.y < H + TILE then
        o.broken_t = o.broken_t - 1
        out[#out + 1] = o
      end

      if not o.scored then
        o.scored = true
        state.combo = state.combo + 1
        state.combo_t = 120
        state.stats.walls_broken = state.stats.walls_broken + 1
        state.stats.max_combo = math.max(state.stats.max_combo, state.combo)
        state.score = state.score + math.floor((10 + state.combo * 3) * state.score_mult)
      end
    end
  end
  state.obstacles = out
end

local function update_pickups()
  local out = {}
  for i = 1, #state.pickups do
    local it = state.pickups[i]
    it.y = it.y + state.player.speed
    if it.y < H + TILE then out[#out + 1] = it end
  end
  state.pickups = out
end

local function update_bullets()
  local out = {}
  for i = 1, #state.bullets do
    local b = state.bullets[i]
    b.y = b.y - b.v
    if b.y > -8 then out[#out + 1] = b end
  end
  state.bullets = out
end

local function update_fx()
  local out = {}
  for i = 1, #state.fx do
    local fx = state.fx[i]
    fx.t = fx.t - 1
    if fx.kind == "dust" then
      fx.y = fx.y + state.player.speed * 0.35
    end
    if fx.t > 0 then out[#out + 1] = fx end
  end
  state.fx = out
end

local function resolve_shots()
  for bi = 1, #state.bullets do
    local b = state.bullets[bi]
    local hit = false

    for oi = 1, #state.obstacles do
      local o = state.obstacles[oi]
      if o.hp > 0 and aabb(b.x, b.y, 4, 4, o.x, o.y, TILE, TILE) then
        hit = true
        if o.typ == 3 then
          o.hp = o.hp - 1
          if o.hp <= 0 then
            -- show a "broken" sprite briefly after destruction
            o.broken_t = WALL_BROKEN_TTL
            state.freeze_t = 2
            state.flash_t = 4
            play_sfx(SFX.break_wall, -1, 10, 1, 7)
          end
          add_fx("debris", o.x, o.y, 8)
        end
        break
      end
    end

    if hit then b.y = -999 end
  end
end

local function resolve_player_collision()
  local p = state.player
  if p.hit_cd > 0 then return end

  for i = 1, #state.obstacles do
    local o = state.obstacles[i]
    if o.hp > 0 and aabb(p.x, TANK_Y, TANK_W, TANK_H, o.x, o.y, TILE, TILE) then
      -- require deeper overlap (not just a touch)
      local ox0 = o.x + HIT_MARGIN
      local oy0 = o.y + HIT_MARGIN
      local ox1 = o.x + TILE - HIT_MARGIN
      local oy1 = o.y + TILE - HIT_MARGIN
      local px0 = p.x
      local py0 = TANK_Y
      local px1 = p.x + TANK_W
      local py1 = TANK_Y + TANK_H
      local ovx = overlap_amount(px0, px1, ox0, ox1)
      local ovy = overlap_amount(py0, py1, oy0, oy1)
      if ovx >= HIT_OVERLAP_PX and ovy >= HIT_OVERLAP_PX then
        if o.kind == "obstacle" then
          p.hp = clamp(p.hp - DAMAGE_OBSTACLE, 0, HEALTH_MAX)
          state.stats.damage_taken = state.stats.damage_taken + DAMAGE_OBSTACLE
          play_sfx(SFX.crash, -1, 24, 1, 8)
          finish_run("CRASHED INTO HAZARD", false)
          return
        end

        p.hp = clamp(p.hp - state.wall_damage, 0, HEALTH_MAX)
        state.stats.damage_taken = state.stats.damage_taken + state.wall_damage
        state.combo = 0
        state.flash_t = 6
        state.freeze_t = 2
        play_sfx(SFX.hit, -1, 10, 1, 7)
        if p.hp <= 0 then
          finish_run("TANK DESTROYED", false)
          return
        end

        p.speed = clamp(SPEED_ON_MAZE_HIT, SPEED_MIN, SPEED_MAX)
        p.hit_cd = 18
        add_fx("debris", o.x, o.y, 10)
        return
      end
    end
  end
end

local function resolve_pickups()
  local p = state.player
  local out = {}
  for i = 1, #state.pickups do
    local it = state.pickups[i]
    if aabb(p.x, TANK_Y, TANK_W, TANK_H, it.x, it.y, TILE, TILE) then
      if it.typ == "ammo" then
        p.ammo_total = p.ammo_total + AMMO_PICKUP_AMOUNT
      elseif it.typ == "health" then
        p.hp = clamp(p.hp + HEALTH_PICKUP_AMOUNT, 0, HEALTH_MAX)
        state.stats.health_pickups = state.stats.health_pickups + 1
      end
      state.score = state.score + math.floor(5 * state.score_mult)
      state.flash_t = 3
      play_sfx(SFX.pickup, -1, 8, 1, 6)
    else
      out[#out + 1] = it
    end
  end
  state.pickups = out
end

local function draw_background()
  local bg, g1, g2 = biome_colors()
  cls(bg)
  rect(FIELD_X0, FIELD_Y0, FIELD_W, FIELD_H, g1)
  rectb(FIELD_X0, FIELD_Y0, FIELD_W, FIELD_H, 0)

  local scroll = (state.t * math.floor(state.player.speed)) % 8

  if state.biome == 1 then
    -- forest: subtle horizontal stripes
    for y = FIELD_Y0 + scroll, FIELD_Y0 + FIELD_H, 8 do
      rect(FIELD_X0, y, FIELD_W, 1, g2)
    end
  elseif state.biome == 2 then
    -- desert: dotted sand noise (stable grid, no flicker)
    for y = FIELD_Y0 + (scroll % 4), FIELD_Y0 + FIELD_H, 4 do
      for x = FIELD_X0 + ((math.floor(y / 4)) % 2) * 2, FIELD_X0 + FIELD_W, 4 do
        pix(x, y, g2)
      end
    end
  else
    -- biome 3: solid field (texture comes from city surface tiles)
    -- (base rect is already drawn above)
  end
end

local function draw_obstacles()
  for i = 1, #state.obstacles do
    local o = state.obstacles[i]
    if o.hp > 0 or (o.broken_t and o.broken_t > 0) then
      if DEBUG_MAZE then
        spr(DEBUG_MAZE_SPR, math.floor(o.x), math.floor(o.y), 0, 2, 0, 0, 1, 1)
      else
        -- deadly obstacles (instant death on collision)
        if o.kind == "obstacle" then
          -- A pulsing warning silhouette makes lethal objects readable even
          -- when their palette is close to ordinary scenery.
          local warning = (math.floor(state.t / 6) % 2 == 0) and 2 or 9
          circ(math.floor(o.x + 8), math.floor(o.y + 8), 8, warning)
          local base = SPR.obs_rock
          if state.biome == 2 then base = SPR.obs_bush end
          if state.biome == 3 then
            base = (o.typ == 1) and SPR.obs_city_car or SPR.obs_city_dumpster
          end
          spr(base, math.floor(o.x), math.floor(o.y), 0, 1, 0, 0, 2, 2)
        else
        local base = SPR.obs_tree
        if state.biome == 1 then
          -- forest
          if o.typ == 1 then base = SPR.obs_tree
          elseif o.typ == 2 then base = SPR.obs_rock
          else
            if o.hp <= 0 and o.broken_t and o.broken_t > 0 then
              base = SPR.obs_wall_broken
            else
              base = (o.v == "cracked") and SPR.obs_wall_cracked or SPR.obs_wall_intact
            end
          end
        elseif state.biome == 2 then
          -- desert
          if o.typ == 1 then base = SPR.obs_cactus
          elseif o.typ == 2 then base = SPR.obs_bush
          else
            if o.hp <= 0 and o.broken_t and o.broken_t > 0 then
              base = SPR.obs_ruin_broken
            else
              base = SPR.obs_ruin_intact
            end
          end
        else
          -- city (temporary: reuse desert ruins for a "concrete/barrier" look)
          if o.typ == 1 then base = SPR.obs_ruin_intact
          elseif o.typ == 2 then base = SPR.obs_ruin_intact
          else
            if o.hp <= 0 and o.broken_t and o.broken_t > 0 then
              base = SPR.obs_ruin_broken
            else
              base = SPR.obs_ruin_intact
            end
          end
        end
        spr(base, math.floor(o.x), math.floor(o.y), 0, 1, 0, 0, 2, 2)
        end
      end
    end
  end
end

local function draw_pickups()
  for i = 1, #state.pickups do
    local it = state.pickups[i]
    local bob = math.floor(math.sin((state.t + i * 7) / 8) * 2)
    if it.typ == "ammo" then
      spr(SPR.item_ammo_box, math.floor(it.x), math.floor(it.y + bob), 0, 1, 0, 0, 2, 2)
    elseif it.typ == "health" then
      -- draw 8×8 sprite scaled to 16×16 cell
      spr(SPR.item_health, math.floor(it.x), math.floor(it.y + bob), 0, 2, 0, 0, 1, 1)
    end
  end
end

local function draw_bullets()
  for i = 1, #state.bullets do
    local b = state.bullets[i]
    if b.y > -8 then
      line(math.floor(b.x + 2), math.floor(b.y + 5), math.floor(b.x + 2), math.floor(b.y + 10), 9)
      spr(SPR.fx_bullet, math.floor(b.x), math.floor(b.y), 0, 1, 0, 0, 1, 1)
    end
  end
end

local function draw_fx()
  for i = 1, #state.fx do
    local fx = state.fx[i]
    if fx.kind == "muzzle" then
      local frame = (fx.t % 2) + 1
      local id = SPR.fx_muzzle[frame]
      spr(id, fx.x - 4, fx.y - 4, 0, 1, 0, 0, 1, 1)
    elseif fx.kind == "debris" then
      local frame = (fx.t % 2) + 1
      local id = SPR.fx_debris[frame]
      spr(id, math.floor(fx.x + 4), math.floor(fx.y + 4), 0, 1, 0, 0, 1, 1)
    elseif fx.kind == "dust" then
      local frame = (fx.t % 2) + 1
      spr(SPR.fx_dust[frame], math.floor(fx.x - 4), math.floor(fx.y - 4), 0, 1, 0, 0, 1, 1)
    end
  end
end

local function draw_tank()
  local p = state.player
  if p.hit_cd > 0 and math.floor(p.hit_cd / 3) % 2 == 0 then return end
  local body_id = (math.floor(state.t / 8) % 2 == 0) and SPR.tank_body_0 or SPR.tank_body_1
  spr(body_id, math.floor(p.x), TANK_Y, 0, 1, 0, 0, 2, 2)

  local ai = angle_index()
  spr(SPR.tank_turret[ai], math.floor(p.x), TANK_Y, 0, 1, 0, 0, 2, 2)
  spr(SPR.tank_barrel[ai], math.floor(p.x), TANK_Y, 0, 1, 0, 0, 2, 2)
end

local function draw_hud()
  local p = state.player
  -- Keep information outside the playfield whenever possible.
  rect(0, 0, FIELD_X0 - 2, H, 0)
  rect(FIELD_X0 + FIELD_W + 2, 0, W - (FIELD_X0 + FIELD_W + 2), H, 0)

  print("SCORE", 3, 5, 12)
  print(state.score, 3, 13, 15)
  print("BEST", 3, 26, 12)
  print(state.high_score, 3, 34, 15)
  print("DIST", 3, 48, 12)
  print(math.floor(state.run_distance * DISTANCE_TO_METERS).."M", 3, 56, 15)

  if state.combo > 1 then
    print("X"..state.combo, 3, 70, 10)
  end

  -- health bar
  local bar_x, bar_y = FIELD_X0 + FIELD_W + 5, 25
  local bar_w, bar_h = 38, 7
  print("HP", bar_x, 15, p.hp <= 25 and 2 or 12)
  rectb(bar_x, bar_y, bar_w, bar_h, 15)
  local fill = math.floor((bar_w - 2) * (p.hp / HEALTH_MAX))
  rect(bar_x + 1, bar_y + 1, fill, bar_h - 2, p.hp <= 25 and 2 or 6)
  print(p.hp.."%", bar_x, 35, 15)

  local biome_name = (state.biome == 1 and "FOREST") or (state.biome == 2 and "DESERT") or "CITY"
  print(biome_name, FIELD_X0 + FIELD_W + 5, 5, 15)

  -- ammo
  local ammo_x = FIELD_X0 + FIELD_W + 5
  spr(SPR.ui_ammo, ammo_x, 54, 0, 1, 0, 0, 1, 1)
  local status = p.ammo_in_mag .. "/" .. p.ammo_total
  if p.reload_t > 0 then status = "RELOAD" end
  print(status, ammo_x + 10, 55, p.reload_t > 0 and 9 or 15)

  local progress = clamp(state.stage_distance / STAGE_DISTANCE[state.biome], 0, 1)
  rectb(FIELD_X0 + 3, 2, FIELD_W - 6, 4, 15)
  rect(FIELD_X0 + 4, 3, math.floor((FIELD_W - 8) * progress), 2, 10)

  if state.biome == 1 and state.run_distance < TUTORIAL_DISTANCE then
    local hint = "LEFT/RIGHT: STEER"
    if state.run_distance > 560 then hint = "BREAK W WALLS"
    elseif state.run_distance > 260 then hint = "A: FIRE"
    end
    local x = math.floor((W - #hint * 6) / 2)
    rect(x - 3, 12, #hint * 6 + 6, 9, 0)
    print(hint, x, 14, 15)
  end

  if DEBUG_HUD then
    print(string.format("%.2f", p.speed), 3, 90, 15)
  end
end

local function draw_world()
  draw_background()
  draw_surfaces()
  draw_obstacles()
  draw_pickups()
  draw_bullets()
  draw_fx()
  draw_tank()
  draw_hud()
  if state.flash_t > 0 then
    rect(0, 0, W, H, state.is_victory and 11 or 15)
    state.flash_t = state.flash_t - 1
  end
end

local function centered(text, y, color, scale)
  scale = scale or 1
  local width = #text * 6 * scale
  print(text, math.floor((W - width) / 2), y, color or 15, false, scale)
end

local function draw_title()
  draw_background()
  centered(GAME_TITLE, 34, 15, 2)
  centered(GAME_TAGLINE, 57, 12, 1)
  centered("LEFT/RIGHT STEER", 79, 15, 1)
  centered("A FIRE   B BRAKE   X PAUSE", 89, 15, 1)
  centered("PRESS A", 111, 10, 1)
  if state.high_score > 0 then centered("BEST "..state.high_score, 124, 12, 1) end
end

local function draw_pause()
  draw_world()
  rect(62, 43, 116, 45, 0)
  rectb(62, 43, 116, 45, 15)
  centered("PAUSED", 53, 15, 2)
  centered("X RESUME  A RESTART", 76, 12, 1)
end

local function draw_upgrade()
  draw_background()
  centered("STAGE CLEARED", 18, 10, 2)
  centered("CHOOSE UPGRADE", 42, 15, 1)
  for i = 1, 2 do
    local x = (i == 1) and 17 or 125
    local selected = i == state.upgrade_choice
    rect(x, 58, 98, 48, selected and 5 or 0)
    rectb(x, 58, 98, 48, selected and 15 or 12)
    local u = state.upgrade_options[i]
    print(u.name, x + 7, 68, selected and 15 or 12)
    print(u.desc, x + 7, 84, selected and 15 or 12, false, 1, true)
  end
  centered("LEFT/RIGHT + A", 118, 12, 1)
end

local function draw_gameover()
  draw_world()
  rect(43, 24, 154, 104, 0)
  rectb(43, 24, 154, 104, state.is_victory and 10 or 2)
  centered(state.is_victory and "RUN COMPLETE" or "GAME OVER", 33, 15, 2)
  centered(state.death_reason, 57, 12, 1)
  centered("SCORE "..state.score.."  BEST "..state.high_score, 72, 15, 1)
  centered(math.floor(state.run_distance * DISTANCE_TO_METERS).." METERS", 83, 12, 1)
  if #state.earned_challenges > 0 then
    local badges = state.earned_challenges[1]
    if #state.earned_challenges > 1 then badges = badges.." + "..state.earned_challenges[2] end
    centered(badges, 96, 10, 1)
  end
  centered("A: RUN AGAIN", 115, 10, 1)
end

local function validate_level_data()
  local valid = true
  local function validate_rows(rows)
    local reachable = {}
    for col = 1, MAZE_COLS do reachable[col] = true end
    for i = 1, #rows do
      if #rows[i] ~= MAZE_COLS then valid = false end
      if not rows[i]:find("[%.AWHCP]") then valid = false end

      local next_reachable = {}
      for col = 1, MAZE_COLS do
        local ch = rows[i]:sub(col, col)
        local traversable = ch ~= "#" and ch ~= "X" and ch ~= "O"
        if traversable then
          for previous = math.max(1, col - 2), math.min(MAZE_COLS, col + 2) do
            if reachable[previous] then
              next_reachable[col] = true
              break
            end
          end
        end
      end
      reachable = next_reachable
      local has_route = false
      for col = 1, MAZE_COLS do
        if reachable[col] then has_route = true break end
      end
      if not has_route then valid = false end
    end
  end
  validate_rows(TUTORIAL_ROWS)
  for b = 1, #BIOME_SEGMENTS do
    for s = 1, #BIOME_SEGMENTS[b] do validate_rows(BIOME_SEGMENTS[b][s]) end
    validate_rows(CAPSTONE_SEGMENTS[b])
  end
  return valid
end

function TIC()
  if not state.inited then
    state.inited = true
    math.randomseed((tstamp and tstamp()) or 1)
    if pmem then state.high_score = pmem(0) or 0 end
    reset_game()
    state.mode = "title"
    if not validate_level_data() then DEBUG_HUD = true end
  end

  state.t = state.t + 1

  if state.mode == "title" then
    draw_title()
    if btnp(BTN_A) then reset_game() end
    return
  end

  if state.mode == "pause" then
    draw_pause()
    if btnp(BTN_X) then state.mode = "play" end
    if btnp(BTN_A) then reset_game() end
    return
  end

  if state.mode == "upgrade" then
    draw_upgrade()
    if btnp(BTN_LEFT) then state.upgrade_choice = 1 end
    if btnp(BTN_RIGHT) then state.upgrade_choice = 2 end
    if btnp(BTN_A) then apply_upgrade(state.upgrade_options[state.upgrade_choice]) end
    return
  end

  if state.mode == "gameover" then
    draw_gameover()
    if btnp(BTN_A) then reset_game() end
    return
  end

  if btnp(BTN_X) then
    state.mode = "pause"
    draw_pause()
    return
  end

  if state.freeze_t > 0 then
    state.freeze_t = state.freeze_t - 1
    draw_world()
    return
  end

  update_player()
  update_progress()
  if state.mode ~= "play" then
    if state.mode == "upgrade" then draw_upgrade() else draw_gameover() end
    return
  end
  update_spawn()
  update_bullets()
  update_obstacles()
  update_pickups()
  update_surfaces()
  update_fx()
  resolve_shots()
  resolve_player_collision()
  resolve_pickups()

  draw_world()
end

