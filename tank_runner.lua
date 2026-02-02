-- title:  Tank Runner
-- author: ssinyakov + Cursor
-- desc:   Endless offroad tank runner (prototype)
-- script: lua

-- ============================================================
-- Controls (default TIC-80):
--   Left/Right: steer
--   A: shoot
--   B: brake (prototype; just slows)
-- ============================================================

local W, H = 240, 136

-- Button indices in TIC-80:
-- 0 Up, 1 Down, 2 Left, 3 Right, 4 A, 5 B, 6 X, 7 Y
local BTN_LEFT  = 2
local BTN_RIGHT = 3
local BTN_A     = 4
local BTN_B     = 5

local COLOR_BG = 1
local COLOR_GROUND_DARK = 2
local COLOR_GROUND_LIGHT = 3
local COLOR_TEXT = 15

local HORIZON_Y = 34

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

  item_ammo_box = 150, -- 16×16 (occupies also 151/166/167)

  ui_ammo = 192, -- 8×8 (safe, doesn't collide with 16×16 blocks)

  fx_bullet = 128,           -- 8×8
  fx_muzzle = { 129, 130 },  -- 8×8
  fx_dust = { 131, 132 },    -- 8×8
  fx_debris = { 133, 134 },  -- 8×8
}

-- "Road" / playable field in world-X.
-- We clamp the tank and also spawn gameplay objects inside these bounds,
-- so obstacles won't appear outside the playable area.
local ROAD_X_MIN = -1.0
local ROAD_X_MAX = 1.0

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

local function randf(a, b)
  return a + (b - a) * math.random()
end

-- "Depth" d: 0.0 far (near horizon) -> 1.0 near (player)
local function project(world_x, d, player_x)
  local t = clamp(d, 0, 1)
  -- perspective curve: far moves slowly, near accelerates
  local y = HORIZON_Y + (t * t) * (H - HORIZON_Y - 12)
  local scale = 0.15 + t * 1.35
  local screen_x = (W / 2) + (world_x - player_x) * (W * 0.38) * scale
  return screen_x, y, scale
end

local function aabb(ax, ay, aw, ah, bx, by, bw, bh)
  return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end

local state = {
  inited = false,
  game_over = false,
  t = 0,
  biome = 1, -- 1 forest, 2 desert, 3 "blue"
  biome_t = 0,
  player = {
    x = 0.0, -- lateral in world space [-1..1]
    vx = 0.0,
    speed = 0.45, -- world speed (affects obstacle approach)
    health = 3,
    shoot_cd = 0,

    -- ammo system (MVP)
    ammo_total = 0,     -- reserve (not in mag)
    ammo_in_mag = 0,
    reload_t = 0,
    hit_cd = 0,         -- collision cooldown
  },
  bullets = {},
  pickups = {},
  fx = {},
  obstacles = {},
  spawn_cd = 0,
  pickup_cd = 0,
  score = 0,
}

local AMMO_TOTAL_START = 20
local AMMO_MAG_SIZE = 6
local AMMO_RELOAD_FRAMES = 60
local AMMO_PICKUP_AMOUNT = 10

local function reset_game()
  state.game_over = false
  state.t = 0
  state.biome = 1
  state.biome_t = 0
  state.player.x = 0.0
  state.player.vx = 0.0
  state.player.speed = 0.45
  state.player.health = 3
  state.player.shoot_cd = 0
  state.player.hit_cd = 0

  -- load starting ammo into mag
  state.player.ammo_total = AMMO_TOTAL_START
  state.player.ammo_in_mag = 0
  state.player.reload_t = 0

  state.bullets = {}
  state.pickups = {}
  state.fx = {}
  state.obstacles = {}
  state.spawn_cd = 0
  state.pickup_cd = 60
  state.score = 0

  -- initial reload (instant) to fill mag
  local load = math.min(AMMO_MAG_SIZE, state.player.ammo_total)
  state.player.ammo_in_mag = load
  state.player.ammo_total = state.player.ammo_total - load
end

local function biome_colors()
  if state.biome == 1 then
    -- forest-ish
    return 1, 2, 3
  elseif state.biome == 2 then
    -- desert-ish (reuse palette indices; can refine later)
    return 4, 5, 6
  else
    -- "blue landscape"
    return 12, 13, 14
  end
end

local function draw_background()
  local bg, g1, g2 = biome_colors()
  cls(bg)

  -- sky band
  rect(0, 0, W, HORIZON_Y, bg)
  -- ground gradient-ish stripes
  for y = HORIZON_Y, H - 1 do
    local t = (y - HORIZON_Y) / (H - HORIZON_Y)
    local c = (t < 0.5) and g1 or g2
    pix(0, y, c) -- seed first pixel
    -- cheap fill: draw horizontal line with rect
    rect(0, y, W, 1, c)
  end

  -- perspective guide lines (road-ish feel)
  local scroll = (state.t * 40) % 8
  for i = 0, 28 do
    local d = i / 28
    local y = HORIZON_Y + (d * d) * (H - HORIZON_Y - 10)
    local w = lerp(10, 220, d)
    local x0 = (W - w) / 2
    rectb(x0, y, w, 1, 0)
  end
  -- moving stripes to imply speed
  for i = 0, 18 do
    local y = H - 1 - i * 7 + scroll
    if y >= HORIZON_Y then
      local t = (y - HORIZON_Y) / (H - HORIZON_Y)
      local w = lerp(8, 120, t)
      rect((W - w) / 2, y, w, 1, 0)
    end
  end

  -- road edges (visual hint; gameplay clamp is ROAD_X_MIN/MAX)
  for i = 0, 16 do
    local d = i / 16
    local y = HORIZON_Y + (d * d) * (H - HORIZON_Y - 10)
    local w = lerp(80, 220, d)
    local x0 = (W - w) / 2
    pix(x0, y, 0)
    pix(x0 + w - 1, y, 0)
  end
end

local function angle_index()
  -- Map steering to turret aim for now (MVP):
  local denom = math.max(math.abs(ROAD_X_MIN), math.abs(ROAD_X_MAX))
  local x = clamp(state.player.x / denom, -1, 1)
  local idx = 4 + iround(x * 3) -- 1..7
  return clamp(idx, 1, 7)
end

local function draw_tank()
  local px = W / 2 + state.player.x * 60
  local ground_y = H - 6

  local body_id = SPR.tank_body_0
  if state.player.speed > 0.22 then
    body_id = (math.floor(state.t / 8) % 2 == 0) and SPR.tank_body_0 or SPR.tank_body_1
  end

  local x0 = math.floor(px - 8)
  local y0 = ground_y - 16

  -- body
  spr(body_id, x0, y0, 0, 1, 0, 0, 2, 2)

  -- turret + barrel (aim)
  local ai = angle_index()
  local turret_id = SPR.tank_turret[ai]
  local barrel_id = SPR.tank_barrel[ai]
  spr(turret_id, x0, y0, 0, 1, 0, 0, 2, 2)
  spr(barrel_id, x0, y0, 0, 1, 0, 0, 2, 2)
end

local function spawn_obstacle()
  -- Types:
  -- tree: 1 (indestructible)
  -- rock: 2 (indestructible)
  -- wall: 3 (destructible)
  local r = math.random()
  local typ = (r < 0.45) and 1 or ((r < 0.8) and 2 or 3)

  local ox = randf(ROAD_X_MIN, ROAD_X_MAX)
  local d = randf(0.0, 0.2) -- far start

  local hp = 1 -- all destructibles = 1 hit (requirement)

  local wall_full = false
  if typ == 3 then
    -- Walls block the whole road width: cannot be bypassed, must be shot.
    wall_full = true
    ox = 0.0
  end

  state.obstacles[#state.obstacles + 1] = {
    typ = typ,
    ox = ox,
    d = d,
    hp = hp,
    wall_full = wall_full,
  }
end

local function spawn_ammo_pickup()
  state.pickups[#state.pickups + 1] = {
    typ = "ammo",
    ox = randf(ROAD_X_MIN, ROAD_X_MAX),
    d = randf(0.0, 0.2),
  }
end

local function add_fx(kind, ox, d, ttl, extra)
  state.fx[#state.fx + 1] = {
    kind = kind,
    ox = ox or 0,
    d = d or 0,
    t = ttl or 10,
    extra = extra,
  }
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
    ox = p.x,
    d = 0.88, -- start near player then travel forward (toward horizon)
    v = 0.06,
  }

  -- muzzle flash (screen-space-ish)
  add_fx("muzzle", p.x, 0.92, 5, { a = angle_index() })

  if p.ammo_in_mag <= 0 then
    start_reload()
  end
end

local function update_player()
  local p = state.player

  local steer = 0
  if btn(BTN_LEFT) then steer = steer - 1 end
  if btn(BTN_RIGHT) then steer = steer + 1 end

  -- smooth steering
  p.vx = p.vx * 0.75 + steer * 0.06
  p.x = clamp(p.x + p.vx, ROAD_X_MIN, ROAD_X_MAX)

  -- brake (prototype)
  if btn(BTN_B) then
    p.speed = clamp(p.speed - 0.015, 0.18, 0.6)
  else
    p.speed = clamp(p.speed + 0.007, 0.18, 0.6)
  end

  if p.shoot_cd > 0 then p.shoot_cd = p.shoot_cd - 1 end
  if p.hit_cd > 0 then p.hit_cd = p.hit_cd - 1 end

  -- reload tick
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

local function update_biome()
  state.biome_t = state.biome_t + 1
  -- switch biome roughly every ~30 seconds (60fps)
  if state.biome_t > 60 * 30 then
    state.biome_t = 0
    state.biome = (state.biome % 3) + 1
  end
end

local function update_bullets()
  local out = {}
  for i = 1, #state.bullets do
    local b = state.bullets[i]
    b.d = b.d - b.v
    if b.d > 0.02 then
      out[#out + 1] = b
    end
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

local function update_obstacles()
  local speed = state.player.speed

  local out = {}
  for i = 1, #state.obstacles do
    local o = state.obstacles[i]
    o.d = o.d + speed * 0.018
    if o.d < 1.08 and o.hp > 0 then
      out[#out + 1] = o
    else
      -- passed / destroyed
      if o.hp <= 0 then
        state.score = state.score + 10
      end
    end
  end
  state.obstacles = out
end

local function update_pickups()
  local speed = state.player.speed

  local out = {}
  for i = 1, #state.pickups do
    local p = state.pickups[i]
    p.d = p.d + speed * 0.018
    if p.d < 1.08 then
      out[#out + 1] = p
    end
  end
  state.pickups = out
end

local function resolve_shots()
  -- bullet vs obstacle in projected space (simple)
  for bi = 1, #state.bullets do
    local b = state.bullets[bi]
    if b.d then
      local bx, by, bs = project(b.ox, 1.0 - b.d, state.player.x)
      local bw, bh = 2 * bs, 4 * bs
      local hit = false

      for oi = 1, #state.obstacles do
        local o = state.obstacles[oi]
        if o.hp > 0 then
          -- obstacle depth is o.d (0 far -> 1 near), bullet forward depth is (1-b.d) (0 near -> 1 far)
          local od = o.d
          local bd = 1.0 - b.d
          if math.abs(od - bd) < 0.06 then
            local ox, oy, os = project(o.ox, od, state.player.x)
            local ow, oh = 12 * os, 14 * os
            if aabb(bx - bw/2, by - bh, bw, bh, ox - ow/2, oy - oh, ow, oh) then
              hit = true
              -- destructible only
              if o.typ == 3 then
                o.hp = o.hp - 1
              end
              break
            end
          end
        end
      end

      if hit then
        -- mark bullet dead
        b.d = -1
      end
    end
  end
end

local function resolve_player_collision()
  local px = W / 2
  local py = H - 14
  local pr = 12
  local p = state.player
  if p.hit_cd > 0 then return end

  for i = 1, #state.obstacles do
    local o = state.obstacles[i]
    if o.hp > 0 and o.d > 0.74 then
      if o.typ == 3 and o.wall_full then
        -- Full-width wall: can't bypass, must be shot.
        p.speed = 0.18
        p.hit_cd = 18
        add_fx("debris", 0, o.d, 10, nil)
        return
      else
        local ox, oy, os = project(o.ox, o.d, state.player.x)
        local dx = ox - px
        local dy = oy - py
        local rr = pr + 10 * os
        if (dx * dx + dy * dy) < rr * rr then
          -- collision requirement: obstacle stays, forward speed stops
          p.speed = 0.18
          p.hit_cd = 18
          add_fx("debris", o.ox, o.d, 10, nil)
          return
        end
      end
    end
  end
end

local function resolve_pickups()
  local px = W / 2
  local py = H - 14
  local pr = 14

  local out = {}
  for i = 1, #state.pickups do
    local it = state.pickups[i]
    if it.d > 0.78 then
      local ox, oy, os = project(it.ox, it.d, state.player.x)
      local dx = ox - px
      local dy = oy - py
      local rr = pr + 10 * os
      if (dx * dx + dy * dy) < rr * rr then
        if it.typ == "ammo" then
          state.player.ammo_total = state.player.ammo_total + AMMO_PICKUP_AMOUNT
          add_fx("muzzle", it.ox, it.d, 8, { a = 4 })
        end
      else
        out[#out + 1] = it
      end
    else
      out[#out + 1] = it
    end
  end
  state.pickups = out
end

local function update_spawn()
  state.spawn_cd = state.spawn_cd - 1
  if state.spawn_cd <= 0 then
    spawn_obstacle()
    -- adapt spawn rate slightly with speed
    local base = lerp(30, 14, (state.player.speed - 0.18) / (0.6 - 0.18))
    state.spawn_cd = math.floor(base + math.random(0, 8))
  end
end

local function update_pickup_spawn()
  state.pickup_cd = state.pickup_cd - 1
  if state.pickup_cd <= 0 then
    spawn_ammo_pickup()
    state.pickup_cd = 60 * 4 + math.random(0, 120)
  end
end

local function draw_obstacles()
  for i = 1, #state.obstacles do
    local o = state.obstacles[i]
    if o.hp > 0 then
      local x, y, s = project(o.ox, o.d, state.player.x)
      local base = SPR.obs_tree
      if o.typ == 1 then base = SPR.obs_tree
      elseif o.typ == 2 then base = SPR.obs_rock
      else base = SPR.obs_wall_intact end

      local y0 = math.floor((y - 16*s))
      local sc = math.max(1, math.floor(s + 0.2))
      if o.typ == 3 and o.wall_full then
        local tile = 16 * sc
        for xx = -tile, W + tile, tile do
          spr(base, xx, y0, 0, sc, 0, 0, 2, 2)
        end
      else
        local x0 = math.floor(x - 8*s)
        spr(base, x0, y0, 0, sc, 0, 0, 2, 2)
      end
    end
  end
end

local function draw_pickups()
  for i = 1, #state.pickups do
    local it = state.pickups[i]
    local x, y, s = project(it.ox, it.d, state.player.x)
    local x0 = math.floor(x - 8*s)
    local y0 = math.floor((y - 16*s))
    local sc = math.max(1, math.floor(s + 0.2))
    spr(SPR.item_ammo_box, x0, y0, 0, sc, 0, 0, 2, 2)
  end
end

local function draw_bullets()
  for i = 1, #state.bullets do
    local b = state.bullets[i]
    if b.d and b.d > 0 then
      local x, y, s = project(b.ox, 1.0 - b.d, state.player.x)
      local x0 = math.floor(x - 4)
      local y0 = math.floor(y - 4)
      spr(SPR.fx_bullet, x0, y0, 0, 1, 0, 0, 1, 1)
    end
  end
end

local function draw_fx()
  local px = W / 2 + state.player.x * 60
  local ground_y = H - 6
  local tank_x0 = math.floor(px - 8)
  local tank_y0 = ground_y - 16

  for i = 1, #state.fx do
    local fx = state.fx[i]
    if fx.kind == "muzzle" then
      local frame = (fx.t % 2) + 1
      local id = SPR.fx_muzzle[frame]
      -- place around turret pivot (8,9) with small offset upward
      local mx = tank_x0 + 8
      local my = tank_y0 + 4
      spr(id, mx - 4, my - 4, 0, 1, 0, 0, 1, 1)
    elseif fx.kind == "debris" then
      local frame = (fx.t % 2) + 1
      local id = SPR.fx_debris[frame]
      local x, y = project(fx.ox, fx.d, state.player.x)
      spr(id, math.floor(x - 4), math.floor(y - 8), 0, 1, 0, 0, 1, 1)
    end
  end
end

local function draw_hud()
  print("SCORE "..state.score, 6, 6, COLOR_TEXT)
  print("HP "..state.player.health, 6, 14, COLOR_TEXT)
  local biome_name = (state.biome == 1 and "FOREST") or (state.biome == 2 and "DESERT") or "BLUE"
  print(biome_name, W - 54, 6, COLOR_TEXT)

  -- ammo
  spr(SPR.ui_ammo, 6, 24, 0, 1, 0, 0, 1, 1)
  local p = state.player
  local status = p.ammo_in_mag .. "/" .. p.ammo_total
  if p.reload_t > 0 then
    status = "RELOAD " .. math.ceil(p.reload_t / 6)
  end
  print(status, 16, 22, COLOR_TEXT)
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
  update_pickup_spawn()
  update_bullets()
  update_pickups()
  update_fx()
  update_obstacles()
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

