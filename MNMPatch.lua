-- Monomachine Randomizer v1.3
--
-- HANJO, Tokyo, Japan.
--
-- 6 banks (one per MNM track), each with its own MIDI channel and
-- its own randomized CC values. CC target layout is shared across
-- banks (so the 7 pages of CCs hit the same parameters on every
-- track, just with independent random values).
--
-- K3: Randomize CC values on the current page of the active bank.
--     Hold K3: while held, note-ons on the auto-lock trigger port reroll
--     the whole current page (Auto Page Roll).
-- E1: Change page (1..7). Scroll left past SYNTH to the "ALL" page,
--     where K3 rolls every page of the active bank at once.
-- K1 + E1: Change active bank (1..6).
-- E2: Select CC slot.
-- K2: Cycle edit mode (CC / VAL / MIDI channel).
-- E3: Adjust CC, value, or active bank's MIDI channel.
-- Scroll to CC -1 : OFF feature.
--
-- MIDI forwarding (configurable in PARAMETERS > MIDI Forwarding):
--   Every forwardable message type (notes, CC in, clock, transport)
--   can be independently routed to: off, port 1, port 2, or both.
--   Notes / aftertouch / pitch bend / program change from the input
--   device forward on their incoming channel by default (1:1); the
--   Note Channel option can instead remap them onto the active bank's
--   MIDI channel. CCs pass through on their original channel and mix
--   with the randomizer's outgoing CCs. Transport covers start /
--   continue / stop and song position. The secondary output port
--   (port 2) is configurable (default 2); the main output is port 1.
--

local midi_out
local midi_out_2
local midi_in
local midi_in_2

-- MIDI status nibbles (high 4 bits of the status byte for channel-voice messages)
local STATUS_NOTE_OFF        = 0x80
local STATUS_NOTE_ON         = 0x90
local STATUS_POLY_PRESSURE   = 0xA0
local STATUS_CC              = 0xB0
local STATUS_PROGRAM_CHANGE  = 0xC0
local STATUS_CHANNEL_PRESSURE= 0xD0
local STATUS_PITCH_BEND      = 0xE0

-- System realtime / common
local STATUS_SONG_POSITION   = 0xF2
local STATUS_SONG_SELECT     = 0xF3
local STATUS_CLOCK           = 0xF8
local STATUS_START           = 0xFA
local STATUS_CONTINUE        = 0xFB
local STATUS_STOP            = 0xFC

-- Routing options for clock / transport forwarding.
-- Indices are stable (params store the integer index): 1=off, 2=port 1, 3=port 2, 4=both.
local ROUTE_OFF    = 1
local ROUTE_PORT_1 = 2
local ROUTE_PORT_2 = 3
local ROUTE_BOTH   = 4
local ROUTE_OPTIONS = { "off", "port 1", "port 2", "both" }

-- Channel mapping for forwarded notes. 1:1 keeps the incoming channel so
-- scrolling through banks never retargets forwarded notes; active-bank
-- remaps onto the selected bank's channel (the original behaviour).
-- Indices are stable (params store the integer index).
local NOTE_CHAN_PASSTHROUGH = 1
local NOTE_CHAN_ACTIVE_BANK = 2
local NOTE_CHAN_OPTIONS = { "1:1 passthrough", "active bank" }

local num_slots_per_page = 8
local num_pages = 7
local num_banks = 6

-- Page 0 is the virtual "ALL" page: it displays the SYNTH page's slots but
-- K3 there rolls every page of the active bank at once.
local ALL_PAGE = 0
local current_page = 1

local function effective_page()
  return math.max(current_page, 1)
end
local current_bank = 1
local k1_held = false

-- CC target layout is shared across all banks; only values vary per bank.
-- cc_labels (optional) name each slot for display. SYNTH is intentionally
-- left unlabeled and falls back to showing "CC###" in the UI.
local LFO_LABELS = { "PAGE", "DEST", "TRIG", "WAVE", "MULT", "SPD", "INTL", "DPTH" }

-- Params (by label) that K3 / auto-lock rolls must never touch.
-- Manual edits (E3 in VAL mode) still work on these slots.
local LFO_ROLL_EXCLUDE = { MULT = true, SPD = true }

local page_data = {
  { title = "SYNTH",  cc_targets = {48, 49, 50, 51, 52, 53, 54, 55} },
  { title = "AMP",    cc_targets = {56, 57, 58, 59, 60, 61, 62, 63},
                      cc_labels  = {"ATK", "HOLD", "DEC", "REL", "DIST", "VOL", "PAN", "PORT"},
                      roll_exclude = { ATK = true, HOLD = true, REL = true, VOL = true, PAN = true, PORT = true } },
  { title = "FILTER", cc_targets = {72, 73, 74, 75, 76, 77, 78, 79},
                      cc_labels  = {"BASE", "WDTH", "HFQ", "LFQ", "ATK", "DEC", "BDFS", "WDFS"},
                      roll_exclude = { BASE = true, WDTH = true, ATK = true, BDFS = true, WDFS = true } },
  { title = "EFFECTS",cc_targets = {80, 81, 82, 83, 84, 85, 86, 87},
                      cc_labels  = {"EQF", "EQG", "SRR", "DTIM", "DSND", "DFB", "DBAS", "DWID"},
                      roll_exclude = { DTIM = true, DSND = true, DFB = true, DBAS = true, DWID = true } },
  { title = "LFO 1",  cc_targets = {88,  89,  90,  91,  92,  93,  94,  95},  cc_labels = LFO_LABELS, roll_exclude = LFO_ROLL_EXCLUDE },
  { title = "LFO 2",  cc_targets = {104, 105, 106, 107, 108, 109, 110, 111}, cc_labels = LFO_LABELS, roll_exclude = LFO_ROLL_EXCLUDE },
  { title = "LFO 3",  cc_targets = {112, 113, 114, 115, 116, 117, 118, 119}, cc_labels = LFO_LABELS, roll_exclude = LFO_ROLL_EXCLUDE }
}

-- CC numbers that rolls must never touch, regardless of page or label
-- (55 = SYNTH page slot 8). Manual E3 edits still work.
local ROLL_EXCLUDE_CCS = { [55] = true }

local function is_roll_excluded(page, slot)
  local cc = page.cc_targets[slot]
  if ROLL_EXCLUDE_CCS[cc] then return true end
  if not (page.roll_exclude and page.cc_labels) then return false end
  local label = page.cc_labels[slot]
  return label ~= nil and page.roll_exclude[label] == true
end

-- LFO PAGE/DEST constrained rolling ------------------------------------
-- PAGE and DEST are discrete-list params driven by a continuous CC: the
-- MNM splits 0..127 into even buckets (PAGE: 5 entries, DEST: 8 entries,
-- ordered like the target page's 8 knobs). Rolling them freely could aim
-- an LFO at a param we've excluded from rolling, modulating it anyway.
-- Instead, rolls pick a random (page, dest) pair from the allowlist below
-- and emit the midpoint CC value of each bucket.
local LFO_TARGET_PAGE_OPTIONS = { "SYN", "AMP", "FLT", "EFF", "LFO" }

-- Allowed DEST slots (1..8) per target page; mirrors the roll exclusions
-- above (SYN slot 8 = CC 55; LFO page: MULT/SPD are slots 5/6).
local LFO_ALLOWED_DESTS = {
  SYN = { 1, 2, 3, 4, 5, 6, 7 },
  AMP = { 3, 5 },              -- DEC, DIST
  FLT = { 3, 4, 6 },           -- HFQ, LFQ, DEC
  EFF = { 1, 2, 3 },           -- EQF, EQG, SRR
  LFO = { 1, 2, 3, 4, 7, 8 },  -- everything but MULT/SPD
}

-- Flattened { page_value, dest_value } CC pairs, precomputed once.
local LFO_TARGET_PAIRS = {}
for page_idx, page_name in ipairs(LFO_TARGET_PAGE_OPTIONS) do
  local page_val = math.floor((page_idx - 0.5) * 128 / #LFO_TARGET_PAGE_OPTIONS)
  for _, dest_slot in ipairs(LFO_ALLOWED_DESTS[page_name]) do
    local dest_val = (dest_slot - 1) * 16 + 8
    table.insert(LFO_TARGET_PAIRS, { page_val, dest_val })
  end
end

local LFO_PAGE_SLOT = 1
local LFO_DEST_SLOT = 2

local function is_lfo_page(page)
  return page.cc_labels == LFO_LABELS
end

-- Randomized values per bank/page/slot: bank_values[bank][page][slot] = 0..127
local bank_values = {}
for b = 1, num_banks do
  bank_values[b] = {}
  for p = 1, num_pages do
    bank_values[b][p] = {}
    for s = 1, num_slots_per_page do
      bank_values[b][p][s] = 0
    end
  end
end

local selected_slot = 1
local edit_mode = "cc"

local function cycle_edit_mode()
  if edit_mode == "cc" then
    edit_mode = "value"
  elseif edit_mode == "value" then
    edit_mode = "midi"
  else
    edit_mode = "cc"
  end
end

-- Auto Param Lock:
--   Hold K2 past AUTO_LOCK_HOLD_THRESHOLD seconds to enter auto-lock mode.
--   While active, note-on messages on the secondary MIDI input that match
--   the active bank's auto-lock channel reroll only the currently
--   highlighted slot (single-param lock).
--   Channel mapping: bank N listens on channel N (bank 1 -> ch 1, ..., bank 6 -> ch 6).
--   A short K2 tap (released before the threshold) cycles edit mode instead.
local AUTO_LOCK_HOLD_THRESHOLD = 0.25
local auto_lock_active = false
local k2_hold_clock_id = nil

-- Auto Page Roll:
--   Same idea as Auto Param Lock, but for the whole page. Hold K3 past the
--   threshold to arm it; while held, matching note-ons on the trigger port
--   reroll the entire current page (or the ALL set on the ALL page).
--   K3 still fires one roll immediately on press, so a short tap behaves
--   exactly as before. Releasing K3 disarms.
local auto_roll_page_active = false
local k3_hold_clock_id = nil

local function auto_lock_channel_for_bank(bank)
  return bank
end

-- Some receivers (e.g. Monomachine) can miss a single STOP if it
-- arrives mid-clock-tick. We forward STOP immediately and then
-- schedule a second STOP 1 second later, cancelling that resend
-- if a START or CONTINUE arrives in the meantime.
local pending_stop_clock_id = nil

local function cancel_pending_stop()
  if pending_stop_clock_id then
    clock.cancel(pending_stop_clock_id)
    pending_stop_clock_id = nil
  end
end

local function schedule_stop_resend(data, send_port_1, send_port_2)
  cancel_pending_stop()
  local payload = { table.unpack(data) }
  pending_stop_clock_id = clock.run(function()
    clock.sleep(1)
    if send_port_1 then midi_out:send(payload) end
    if send_port_2 then midi_out_2:send(payload) end
    pending_stop_clock_id = nil
  end)
end

function init()
  midi_out = midi.connect(1)

  params:add_separator("CC Randomizer Settings")
  params:add_number("cc_val_min", "Value Min", 0, 127, 0)
  params:add_number("cc_val_max", "Value Max", 0, 127, 127)
  params:add_option("out_random_cc", "Random CC Out", ROUTE_OPTIONS, ROUTE_BOTH)

  params:add_separator("Bank MIDI Channels")
  for b = 1, num_banks do
    params:add_number("bank_" .. b .. "_channel", "Bank " .. b .. " Channel", 1, 16, b)
  end

  params:add_separator("MIDI Forwarding")
  params:add_number("midi_in_device", "Input Device (port)", 1, 16, 1)
  params:set_action("midi_in_device", function(val) connect_midi_in(val) end)
  params:add_number("midi_out_device_2", "Secondary Output (port)", 1, 16, 2)
  params:set_action("midi_out_device_2", function(val) connect_midi_out_2(val) end)
  params:add_option("forward_notes",     "Forward Notes",     ROUTE_OPTIONS, ROUTE_PORT_2)
  params:add_option("forward_cc_in",     "Forward CC In",     ROUTE_OPTIONS, ROUTE_PORT_2)
  params:add_option("forward_clock",     "Forward Clock",     ROUTE_OPTIONS, ROUTE_PORT_2)
  params:add_option("forward_transport", "Forward Transport", ROUTE_OPTIONS, ROUTE_PORT_2)
  params:add_option("note_channel_mode", "Note Channel",      NOTE_CHAN_OPTIONS, NOTE_CHAN_PASSTHROUGH)

  params:add_separator("Auto Param Lock")
  params:add_number("midi_in_device_2", "Auto-Lock Trigger Port", 1, 16, 2)
  params:set_action("midi_in_device_2", function(val) connect_midi_in_2(val) end)

  connect_midi_in(params:get("midi_in_device"))
  connect_midi_in_2(params:get("midi_in_device_2"))
  connect_midi_out_2(params:get("midi_out_device_2"))

  clock.run(redraw_loop)
end

function connect_midi_in(port)
  if midi_in and midi_in.event then
    midi_in.event = nil
  end
  midi_in = midi.connect(port)
  midi_in.event = handle_midi_in
end

function connect_midi_in_2(port)
  if midi_in_2 and midi_in_2.event then
    midi_in_2.event = nil
  end
  midi_in_2 = midi.connect(port)
  midi_in_2.event = handle_midi_in_2
end

function connect_midi_out_2(port)
  midi_out_2 = midi.connect(port)
end

local function should_send_to_port_1(route_param_id)
  local v = params:get(route_param_id)
  return v == ROUTE_PORT_1 or v == ROUTE_BOTH
end

local function should_send_to_port_2(route_param_id)
  local v = params:get(route_param_id)
  return v == ROUTE_PORT_2 or v == ROUTE_BOTH
end

-- Emit a randomizer-generated CC (from a reroll or a manual E3 nudge) to
-- whichever output port(s) the Random CC Out route selects.
local function send_random_cc(cc, val, ch)
  if should_send_to_port_1("out_random_cc") then midi_out:cc(cc, val, ch) end
  if should_send_to_port_2("out_random_cc") then midi_out_2:cc(cc, val, ch) end
end

local function get_bank_channel(bank)
  return params:get("bank_" .. bank .. "_channel")
end

local function get_active_channel()
  return get_bank_channel(current_bank)
end

local function get_active_values()
  return bank_values[current_bank][effective_page()]
end

-- Rebuild a channel-voice message with the configured outgoing channel.
local function with_channel(data, ch)
  local rebuilt = { (data[1] & 0xF0) | ((ch - 1) & 0x0F) }
  for i = 2, #data do rebuilt[i] = data[i] end
  return rebuilt
end

function handle_midi_in(data)
  if not data or #data == 0 then return end
  local status = data[1]

  -- System realtime: single-byte, no channel.
  if status == STATUS_CLOCK then
    if should_send_to_port_1("forward_clock") then midi_out:send(data) end
    if should_send_to_port_2("forward_clock") then midi_out_2:send(data) end
    return
  end
  if status == STATUS_START or status == STATUS_CONTINUE then
    cancel_pending_stop()
    if should_send_to_port_1("forward_transport") then midi_out:send(data) end
    if should_send_to_port_2("forward_transport") then midi_out_2:send(data) end
    return
  end
  if status == STATUS_STOP then
    local send_p1 = should_send_to_port_1("forward_transport")
    local send_p2 = should_send_to_port_2("forward_transport")
    if send_p1 then midi_out:send(data) end
    if send_p2 then midi_out_2:send(data) end
    if send_p1 or send_p2 then
      schedule_stop_resend(data, send_p1, send_p2)
    end
    return
  end

  -- System common transport-related messages.
  if status == STATUS_SONG_POSITION or status == STATUS_SONG_SELECT then
    if should_send_to_port_1("forward_transport") then midi_out:send(data) end
    if should_send_to_port_2("forward_transport") then midi_out_2:send(data) end
    return
  end

  -- Anything else in the system range (sysex, tune req, active sense, reset): ignore.
  if status >= 0xF0 then return end

  -- Channel-voice messages.
  local high = status & 0xF0

  if high == STATUS_CC then
    -- CCs pass through on their original channel (no remap), mixing
    -- with the randomizer's outgoing CCs on whichever port(s) are routed.
    if should_send_to_port_1("forward_cc_in") then midi_out:send(data) end
    if should_send_to_port_2("forward_cc_in") then midi_out_2:send(data) end
    return
  end

  if high == STATUS_NOTE_ON
      or high == STATUS_NOTE_OFF
      or high == STATUS_POLY_PRESSURE
      or high == STATUS_CHANNEL_PRESSURE
      or high == STATUS_PITCH_BEND
      or high == STATUS_PROGRAM_CHANGE then
    -- Note Channel: 1:1 passthrough forwards on the incoming channel so
    -- scrolling banks never retargets forwarded notes; active bank remaps
    -- onto the selected bank's channel.
    local out_data = data
    if params:get("note_channel_mode") == NOTE_CHAN_ACTIVE_BANK then
      out_data = with_channel(data, get_active_channel())
    end
    if should_send_to_port_1("forward_notes") then midi_out:send(out_data) end
    if should_send_to_port_2("forward_notes") then midi_out_2:send(out_data) end
    return
  end
end

-- Secondary input: trigger-only. Used by Auto Param Lock to reroll on every
-- new note-on for the active bank's auto-lock channel. Nothing from this
-- port is forwarded to the output.
function handle_midi_in_2(data)
  if not (auto_lock_active or auto_roll_page_active) then return end
  if not data or #data == 0 then return end

  local status = data[1]
  if (status & 0xF0) ~= STATUS_NOTE_ON then return end

  local velocity = data[3] or 0
  if velocity == 0 then return end -- velocity-0 note-on is a note-off

  local channel = (status & 0x0F) + 1
  if channel ~= auto_lock_channel_for_bank(current_bank) then return end

  if auto_roll_page_active then
    send_dice_roll()
  else
    send_dice_roll_slot(selected_slot)
  end
end

function get_current_page_data()
  return page_data[effective_page()]
end

-- Roll an LFO's PAGE+DEST as one unit: pick a random allowed target pair
-- and emit both CCs, so the LFO never lands on a roll-excluded param.
local function randomize_lfo_target(page)
  local data = page_data[page]
  local values = bank_values[current_bank][page]
  local page_cc = data.cc_targets[LFO_PAGE_SLOT]
  local dest_cc = data.cc_targets[LFO_DEST_SLOT]
  if page_cc < 0 or dest_cc < 0 then return end

  local ch = get_active_channel()
  local pair = LFO_TARGET_PAIRS[math.random(#LFO_TARGET_PAIRS)]

  values[LFO_PAGE_SLOT] = pair[1]
  values[LFO_DEST_SLOT] = pair[2]
  send_random_cc(page_cc, pair[1], ch)
  send_random_cc(dest_cc, pair[2], ch)
  print(string.format("🎲 B%d P%d LFO target → CC %d = %d, CC %d = %d (ch %d)",
    current_bank, page, page_cc, pair[1], dest_cc, pair[2], ch))
end

local function randomize_slot(page, slot)
  local data = page_data[page]
  local values = bank_values[current_bank][page]

  if is_lfo_page(data) and (slot == LFO_PAGE_SLOT or slot == LFO_DEST_SLOT) then
    randomize_lfo_target(page)
    return
  end

  local cc = data.cc_targets[slot]
  if cc < 0 then return end
  if is_roll_excluded(data, slot) then return end

  local val_min = params:get("cc_val_min")
  local val_max = params:get("cc_val_max")
  local ch = get_active_channel()
  local val = math.random(val_min, val_max)

  values[slot] = val
  send_random_cc(cc, val, ch)
  print(string.format("🎲 B%d P%d S%d → CC %d = %d (ch %d)",
    current_bank, page, slot, cc, val, ch))
end

-- Last page index the ALL-page roll touches: SYNTH through EFFECTS.
-- The LFO pages are deliberately left out of the all-roll.
local ALL_ROLL_LAST_PAGE = 4

-- On the ALL page, roll SYNTH/AMP/FILTER/EFFECTS of the active bank;
-- otherwise just the current page. Roll exclusions apply either way.
function send_dice_roll()
  if current_page == ALL_PAGE then
    for p = 1, ALL_ROLL_LAST_PAGE do
      for i = 1, num_slots_per_page do
        randomize_slot(p, i)
      end
    end
  else
    for i = 1, num_slots_per_page do
      -- On LFO pages, slot 1 rolls the PAGE+DEST pair together; skip
      -- the DEST slot so the pair isn't rolled twice.
      if not (is_lfo_page(page_data[current_page]) and i == LFO_DEST_SLOT) then
        randomize_slot(current_page, i)
      end
    end
  end
end

function send_dice_roll_slot(slot)
  randomize_slot(effective_page(), slot)
end

function key(n, z)
  if n == 1 then
    k1_held = (z == 1)
  elseif n == 3 then
    if z == 1 then
      send_dice_roll()
      if k3_hold_clock_id then
        clock.cancel(k3_hold_clock_id)
        k3_hold_clock_id = nil
      end
      k3_hold_clock_id = clock.run(function()
        clock.sleep(AUTO_LOCK_HOLD_THRESHOLD)
        auto_roll_page_active = true
        k3_hold_clock_id = nil
      end)
    else
      if k3_hold_clock_id then
        clock.cancel(k3_hold_clock_id)
        k3_hold_clock_id = nil
      end
      auto_roll_page_active = false
    end
  elseif n == 2 then
    if z == 1 then
      if k2_hold_clock_id then
        clock.cancel(k2_hold_clock_id)
        k2_hold_clock_id = nil
      end
      k2_hold_clock_id = clock.run(function()
        clock.sleep(AUTO_LOCK_HOLD_THRESHOLD)
        auto_lock_active = true
        k2_hold_clock_id = nil
      end)
    else
      if k2_hold_clock_id then
        clock.cancel(k2_hold_clock_id)
        k2_hold_clock_id = nil
      end
      if auto_lock_active then
        auto_lock_active = false
      else
        cycle_edit_mode()
      end
    end
  end
end

function enc(n, d)
  local current_data = get_current_page_data()
  if n == 1 then
    if k1_held then
      current_bank = util.clamp(current_bank + d, 1, num_banks)
    else
      current_page = util.clamp(current_page + d, ALL_PAGE, num_pages)
      selected_slot = 1
    end
  elseif n == 2 then
    selected_slot = util.clamp(selected_slot + d, 1, num_slots_per_page)
  elseif n == 3 then
    if edit_mode == "cc" then
      local new_cc = util.clamp(current_data.cc_targets[selected_slot] + d, -1, 127)
      current_data.cc_targets[selected_slot] = new_cc
    elseif edit_mode == "value" then
      local values = get_active_values()
      local new_val = util.clamp(values[selected_slot] + d, 0, 127)
      values[selected_slot] = new_val
      local cc = current_data.cc_targets[selected_slot]
      if cc >= 0 then
        send_random_cc(cc, new_val, get_active_channel())
      end
    elseif edit_mode == "midi" then
      local pid = "bank_" .. current_bank .. "_channel"
      params:set(pid, util.clamp(params:get(pid) + d, 1, 16))
    end
  end
end

function redraw()
  screen.clear()
  screen.font_size(8)

  local current_data = get_current_page_data()
  local values = get_active_values()

  screen.move(2, 5)
  screen.text("B" .. current_bank)

  -- Trigger-mode indicators: K2 hold = single-slot reroll (filled square),
  -- K3 hold = whole-page reroll (outlined square) on incoming triggers.
  if auto_lock_active then
    screen.rect(15, 1, 4, 4)
    screen.fill()
  end
  if auto_roll_page_active then
    screen.rect(21, 1, 4, 4)
    screen.stroke()
  end

  local title = (current_page == ALL_PAGE) and "ALL" or current_data.title
  local title_x = (128 - (#title * 8)) / 2 + 6
  screen.move(title_x, 5)
  screen.text(title)

  screen.move(126, 5)
  screen.text_right(string.format("CH%02d", get_active_channel()))

  for i = 1, 4 do
    draw_slot(i, current_data, values, 2, 15 + (i - 1) * 10)
  end
  for i = 5, 8 do
    draw_slot(i, current_data, values, 68, 15 + (i - 5) * 10)
  end

  screen.move(96, 60)
  screen.text("K3: Roll")
  screen.move(54, 60)
  if current_page == ALL_PAGE then
    screen.text("E1:AL")
  else
    screen.text(string.format("E1:%02d", current_page))
  end
  screen.move(4, 60)
  if edit_mode == "cc" then
    local sel_cc = current_data.cc_targets[selected_slot]
    if sel_cc == -1 then
      screen.text("CC OFF")
    else
      screen.text(string.format("CC%3d", sel_cc))
    end
  elseif edit_mode == "value" then
    screen.text("VAL")
  elseif edit_mode == "midi" then
    screen.text(string.format("MIDI %02d", get_active_channel()))
  end

  screen.update()
end

function draw_slot(i, page, values, x, y)
  local marker = (selected_slot == i) and ">" or " "
  local cc = page.cc_targets[i]
  local label = page.cc_labels and page.cc_labels[i]

  -- Slot caption: OFF if disabled, otherwise the param label (or CC# if
  -- the page has no labels). The editable CC number for the selected slot
  -- is shown separately in the bottom mode indicator.
  local caption
  if cc == -1 then
    caption = "OFF "
  elseif label then
    caption = string.format("%-4s", label)
  else
    caption = string.format("CC%3d", cc)
  end

  screen.move(x, y)
  screen.text(string.format("%s%d: %s→%3d", marker, i, caption, values[i]))
end

function redraw_loop()
  while true do
    redraw()
    clock.sleep(1 / 15)
  end
end
