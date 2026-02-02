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

local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
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
  },
  bullets = {},
  obstacles = {},
  spawn_cd = 0,
  score = 0,
}

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
  state.bullets = {}
  state.obstacles = {}
  state.spawn_cd = 0
  state.score = 0
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
end

local function draw_tank()
  -- simple placeholder tank (we'll replace with sprites)
  local px = W / 2 + state.player.x * 60
  local py = H - 22
  rect(px - 9, py - 6, 18, 12, 11)     -- body
  rect(px - 4, py - 12, 8, 8, 10)      -- turret base
  rect(px - 1, py - 18, 2, 8, 10)      -- cannon
  rect(px - 12, py - 5, 3, 10, 0)      -- left track
  rect(px + 9, py - 5, 3, 10, 0)       -- right track
end

local function spawn_obstacle()
  -- Types:
  -- tree: 1 (indestructible)
  -- rock: 2 (indestructible)
  -- wall: 3 (destructible)
  local r = math.random()
  local typ = (r < 0.45) and 1 or ((r < 0.8) and 2 or 3)

  local ox = randf(-1.1, 1.1)
  local d = randf(0.0, 0.2) -- far start

  local hp = 1
  if typ == 3 then hp = 2 end

  state.obstacles[#state.obstacles + 1] = {
    typ = typ,
    ox = ox,
    d = d,
    hp = hp,
  }
end

local function fire()
  if state.player.shoot_cd > 0 then return end
  state.player.shoot_cd = 10
  state.bullets[#state.bullets + 1] = {
    ox = state.player.x,
    d = 0.88, -- start near player then travel forward (toward horizon)
    v = 0.06,
  }
end

local function update_player()
  local p = state.player

  local steer = 0
  if btn(BTN_LEFT) then steer = steer - 1 end
  if btn(BTN_RIGHT) then steer = steer + 1 end

  -- smooth steering
  p.vx = p.vx * 0.75 + steer * 0.06
  p.x = clamp(p.x + p.vx, -1.2, 1.2)

  -- brake (prototype)
  if btn(BTN_B) then
    p.speed = clamp(p.speed - 0.015, 0.18, 0.6)
  else
    p.speed = clamp(p.speed + 0.007, 0.18, 0.6)
  end

  if p.shoot_cd > 0 then p.shoot_cd = p.shoot_cd - 1 end
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
  local py = H - 22
  local pr = 10

  for i = 1, #state.obstacles do
    local o = state.obstacles[i]
    if o.hp > 0 and o.d > 0.78 then
      local ox, oy, os = project(o.ox, o.d, state.player.x)
      local dx = ox - px
      local dy = oy - py
      local rr = pr + 10 * os
      if (dx * dx + dy * dy) < rr * rr then
        -- hit!
        o.hp = 0
        state.player.health = state.player.health - 1
        if state.player.health <= 0 then
          state.game_over = true
        end
      end
    end
  end
end

local function update_spawn()
  state.spawn_cd = state.spawn_cd - 1
  if state.spawn_cd <= 0 then
    spawn_obstacle()
    -- adapt spawn rate slightly with speed
    local base = lerp(45, 22, (state.player.speed - 0.18) / (0.6 - 0.18))
    state.spawn_cd = math.floor(base + math.random(0, 10))
  end
end

local function draw_obstacles()
  for i = 1, #state.obstacles do
    local o = state.obstacles[i]
    if o.hp > 0 then
      local x, y, s = project(o.ox, o.d, state.player.x)
      if o.typ == 1 then
        -- tree
        rect(x - 2*s, y - 10*s, 4*s, 6*s, 4)
        tri(x, y - 18*s, x - 10*s, y - 8*s, x + 10*s, y - 8*s, 11)
      elseif o.typ == 2 then
        -- rock
        circ(x, y - 8*s, 7*s, 13)
        circb(x, y - 8*s, 7*s, 0)
      else
        -- wall (destructible)
        rect(x - 10*s, y - 14*s, 20*s, 14*s, 9)
        rectb(x - 10*s, y - 14*s, 20*s, 14*s, 0)
      end
    end
  end
end

local function draw_bullets()
  for i = 1, #state.bullets do
    local b = state.bullets[i]
    if b.d and b.d > 0 then
      local x, y, s = project(b.ox, 1.0 - b.d, state.player.x)
      line(x, y - 6*s, x, y, 15)
    end
  end
end

local function draw_hud()
  print("SCORE "..state.score, 6, 6, COLOR_TEXT)
  print("HP "..state.player.health, 6, 14, COLOR_TEXT)
  local biome_name = (state.biome == 1 and "FOREST") or (state.biome == 2 and "DESERT") or "BLUE"
  print(biome_name, W - 54, 6, COLOR_TEXT)
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
  update_bullets()
  update_obstacles()
  resolve_shots()
  resolve_player_collision()

  draw_background()
  draw_obstacles()
  draw_bullets()
  draw_tank()
  draw_hud()
end

