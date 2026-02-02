-- title:  Tank Runner
-- author: ssinyakov + Cursor
-- desc:   Ortho maze prototype (TIC-80 Lua)
-- script: lua

-- ============================================================
-- Controls (default TIC-80):
--   Left/Right: steer
--   A: shoot
--   B: brake
-- ============================================================

local W, H = 240, 136

-- Button indices in TIC-80:
-- 0 Up, 1 Down, 2 Left, 3 Right, 4 A, 5 B, 6 X, 7 Y
local BTN_LEFT  = 2
local BTN_RIGHT = 3
local BTN_A     = 4
local BTN_B     = 5

local COLOR_BG = 1
local COLOR_TEXT = 15

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

-- Biome speed progression:
-- biome 1 starts slow and ramps; biome 2 starts higher; biome 3 higher still.
local BIOME_DURATION_FRAMES = 60 * 30
local BIOME_SPEED_MIN = { 1.0, 1.2, 1.4 }
local BIOME_SPEED_MAX = { 1.6, 1.9, 2.2 }

-- Debug: use a solid sprite to visualize maze cells clearly.
-- You said you made sprite #208 solid white for this purpose.
local DEBUG_MAZE = false
local DEBUG_MAZE_SPR = 208 -- 8×8 sprite, drawn scaled to 16×16
local DEBUG_HUD = true -- show extra debug info (speed, etc.)

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

  item_ammo_box = 150, -- 16×16
  item_health = 210, -- 8×8 (we draw it scaled to 16×16)
  ui_ammo = 192, -- 8×8

  fx_bullet = 128,
  fx_muzzle = { 129, 130 },
  fx_debris = { 133, 134 },
}

-- ============================================================
-- Preset Maze (prototype)
-- 9 columns; each row string must be length 9.
-- Legend:
--   # = maze wall (solid)
--   W = maze wall (destructible, 1 hit)
--   A = ammo pickup spawn
--   H = health pickup spawn (sprite #210)
--   X = deadly obstacle (instant death on collision)
--   . = empty
-- ============================================================
local MAZE_COLS = 9
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

local AMMO_TOTAL_START = 20
local AMMO_MAG_SIZE = 6
local AMMO_RELOAD_FRAMES = 60
local AMMO_PICKUP_AMOUNT = 10
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
  game_over = false,
  t = 0,
  biome = 1, -- 1 forest, 2 desert, 3 blue
  biome_t = 0,
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
  spawn_cd = 0,
  maze_row_idx = 1,
  score = 0,
}

local function biome_colors()
  if state.biome == 1 then return 1, 2, 3 end
  if state.biome == 2 then return 4, 5, 6 end
  return 12, 13, 14
end

local function biome_speed_range(biome)
  local i = clamp(biome, 1, 3)
  return BIOME_SPEED_MIN[i], BIOME_SPEED_MAX[i]
end

local function desired_speed_for_biome()
  local smin, smax = biome_speed_range(state.biome)
  local t = clamp(state.biome_t / BIOME_DURATION_FRAMES, 0, 1)
  return lerp(smin, smax, t), smin, smax
end

local function reset_game()
  state.game_over = false
  state.t = 0
  state.biome = 1
  state.biome_t = 0

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
  local load = math.min(AMMO_MAG_SIZE, p.ammo_total)
  p.ammo_in_mag = load
  p.ammo_total = p.ammo_total - load

  state.bullets = {}
  state.pickups = {}
  state.fx = {}
  state.obstacles = {}
  state.spawn_cd = 0
  state.maze_row_idx = 1
  state.score = 0
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

  p.shoot_cd = 8
  p.ammo_in_mag = p.ammo_in_mag - 1

  state.bullets[#state.bullets + 1] = {
    x = p.x + 8,
    y = TANK_Y,
    v = 3.2,
  }

  add_fx("muzzle", p.x + 10, TANK_Y + 2, 5)

  if p.ammo_in_mag <= 0 then start_reload() end
end

local function angle_index()
  local center = FIELD_X0 + (FIELD_W - TANK_W) / 2
  local denom = (FIELD_W / 2)
  local x = clamp((state.player.x - center) / denom, -1, 1)
  local idx = 4 + iround(x * 3)
  return clamp(idx, 1, 7)
end

local function spawn_maze_row()
  local row = MAZE[state.maze_row_idx] or MAZE[1]
  local y = -TILE

  for col = 1, MAZE_COLS do
    local ch = row:sub(col, col)
    local x = col_to_x(col)

    if ch == "#" then
      local typ = (col % 2 == 0) and 1 or 2
      state.obstacles[#state.obstacles + 1] = { kind = "maze", typ = typ, x = x, y = y, hp = 1 }
    elseif ch == "W" then
      state.obstacles[#state.obstacles + 1] = { kind = "maze", typ = 3, x = x, y = y, hp = 1 }
    elseif ch == "A" then
      state.pickups[#state.pickups + 1] = { typ = "ammo", x = x, y = y }
    elseif ch == "H" then
      state.pickups[#state.pickups + 1] = { typ = "health", x = x, y = y }
    elseif ch == "X" then
      state.obstacles[#state.obstacles + 1] = { kind = "obstacle", typ = 2, x = x, y = y, hp = 1 }
    end
  end

  state.maze_row_idx = state.maze_row_idx + 1
  if state.maze_row_idx > #MAZE then state.maze_row_idx = 1 end
end

local function update_biome()
  state.biome_t = state.biome_t + 1
  if state.biome_t > BIOME_DURATION_FRAMES then
    state.biome_t = 0
    state.biome = (state.biome % 3) + 1
    local _, smin, smax = desired_speed_for_biome()
    state.player.speed = clamp(state.player.speed, smin, smax)
  end
end

local function update_player()
  local p = state.player

  local steer = 0
  if btn(BTN_LEFT) then steer = steer - 1 end
  if btn(BTN_RIGHT) then steer = steer + 1 end

  p.vx = p.vx * 0.72 + steer * 1.15
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
      local load = math.min(AMMO_MAG_SIZE, p.ammo_total)
      p.ammo_in_mag = load
      p.ammo_total = p.ammo_total - load
    end
  end

  if btnp(BTN_A) then fire() end
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
    if o.hp > 0 and o.y < H + TILE then
      out[#out + 1] = o
    elseif o.hp <= 0 then
      state.score = state.score + 10
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
      if ovx < HIT_OVERLAP_PX or ovy < HIT_OVERLAP_PX then
        -- "kiss" the wall: no damage
        return
      end

      if o.kind == "obstacle" then
        p.hp = 0
        state.game_over = true
        return
      end

      p.hp = clamp(p.hp - DAMAGE_MAZE, 0, HEALTH_MAX)
      if p.hp <= 0 then
        state.game_over = true
        return
      end

      p.speed = clamp(SPEED_ON_MAZE_HIT, SPEED_MIN, SPEED_MAX)
      p.hit_cd = 18
      add_fx("debris", o.x, o.y, 10)
      return
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
      end
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
  for y = FIELD_Y0 + scroll, FIELD_Y0 + FIELD_H, 8 do
    rect(FIELD_X0, y, FIELD_W, 1, g2)
  end
end

local function draw_obstacles()
  for i = 1, #state.obstacles do
    local o = state.obstacles[i]
    if o.hp > 0 then
      if DEBUG_MAZE then
        spr(DEBUG_MAZE_SPR, math.floor(o.x), math.floor(o.y), 0, 2, 0, 0, 1, 1)
      else
        local base = SPR.obs_tree
        if o.typ == 1 then base = SPR.obs_tree
        elseif o.typ == 2 then base = SPR.obs_rock
        else base = SPR.obs_wall_intact end
        spr(base, math.floor(o.x), math.floor(o.y), 0, 1, 0, 0, 2, 2)
      end
    end
  end
end

local function draw_pickups()
  for i = 1, #state.pickups do
    local it = state.pickups[i]
    if it.typ == "ammo" then
      spr(SPR.item_ammo_box, math.floor(it.x), math.floor(it.y), 0, 1, 0, 0, 2, 2)
    elseif it.typ == "health" then
      -- draw 8×8 sprite scaled to 16×16 cell
      spr(SPR.item_health, math.floor(it.x), math.floor(it.y), 0, 2, 0, 0, 1, 1)
    end
  end
end

local function draw_bullets()
  for i = 1, #state.bullets do
    local b = state.bullets[i]
    if b.y > -8 then
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
    end
  end
end

local function draw_tank()
  local p = state.player
  local body_id = (math.floor(state.t / 8) % 2 == 0) and SPR.tank_body_0 or SPR.tank_body_1
  spr(body_id, math.floor(p.x), TANK_Y, 0, 1, 0, 0, 2, 2)

  local ai = angle_index()
  spr(SPR.tank_turret[ai], math.floor(p.x), TANK_Y, 0, 1, 0, 0, 2, 2)
  spr(SPR.tank_barrel[ai], math.floor(p.x), TANK_Y, 0, 1, 0, 0, 2, 2)
end

local function draw_hud()
  local p = state.player
  -- HUD panel background for readability (debug/UI WIP)
  rect(0, 0, FIELD_X0 - 2, H, 0)

  print("SCORE "..state.score, 6, 6, 15)

  -- health bar
  local bar_x, bar_y = 6, 14
  local bar_w, bar_h = 70, 7
  rectb(bar_x, bar_y, bar_w, bar_h, 15)
  local fill = math.floor((bar_w - 2) * (p.hp / HEALTH_MAX))
  rect(bar_x + 1, bar_y + 1, fill, bar_h - 2, 6)
  print(p.hp.."%", bar_x + bar_w + 4, bar_y, 15)

  local biome_name = (state.biome == 1 and "FOREST") or (state.biome == 2 and "DESERT") or "BLUE"
  print(biome_name, W - 54, 6, 15)

  -- ammo
  spr(SPR.ui_ammo, 6, 24, 0, 1, 0, 0, 1, 1)
  local status = p.ammo_in_mag .. "/" .. p.ammo_total
  if p.reload_t > 0 then status = "RELOAD " .. math.ceil(p.reload_t / 6) end
  print(status, 16, 22, 15)

  if DEBUG_HUD then
    print(string.format("SPD %.2f", p.speed), 6, 34, 15)
  end
end

function TIC()
  if not state.inited then
    state.inited = true
    math.randomseed((tstamp and tstamp()) or 1)
    reset_game()
  end

  state.t = state.t + 1

  if state.game_over then
    draw_background()
    draw_obstacles()
    draw_pickups()
    draw_bullets()
    draw_fx()
    draw_tank()
    draw_hud()
    print("GAME OVER", 92, 60, 15)
    print("PRESS A TO RESTART", 64, 72, 15)
    if btnp(BTN_A) then reset_game() end
    return
  end

  update_player()
  update_biome()
  update_spawn()
  update_bullets()
  update_obstacles()
  update_pickups()
  update_fx()
  resolve_shots()
  resolve_player_collision()
  resolve_pickups()

  draw_background()
  draw_obstacles()
  draw_pickups()
  draw_bullets()
  draw_fx()
  draw_tank()
  draw_hud()
end

