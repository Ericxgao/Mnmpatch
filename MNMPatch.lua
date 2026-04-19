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
-- E1: Change page (1..7).
-- K1 + E1: Change active bank (1..6).
-- E2: Select CC slot.
-- K2: Cycle edit mode (CC / VAL / MIDI channel).
-- E3: Adjust CC, value, or active bank's MIDI channel.
-- Scroll to CC -1 : OFF feature.
--
-- MIDI forwarding (configurable in PARAMETERS > MIDI Forwarding):
--   Notes / aftertouch / pitch bend / program change from the
--   input device are remapped onto the active bank's MIDI channel
--   and sent to the output device.
--   CCs from the input device pass through on their original
--   channel and mix with the randomizer's outgoing CCs.
--   Clock and transport (start/continue/stop, song position) are
--   forwarded raw, each with its own toggle.
-- 

local midi_out
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

local num_slots_per_page = 8
local num_pages = 7
local num_banks = 6

local current_page = 1
local current_bank = 1
local k1_held = false

-- CC target layout is shared across all banks; only values vary per bank.
-- cc_labels (optional) name each slot for display. SYNTH is intentionally
-- left unlabeled and falls back to showing "CC###" in the UI.
local LFO_LABELS = { "PAGE", "DEST", "TRIG", "WAVE", "MULT", "SPD", "INTL", "DPTH" }

local page_data = {
  { title = "SYNTH",  cc_targets = {48, 49, 50, 51, 52, 53, 54, 55} },
  { title = "AMP",    cc_targets = {56, 57, 58, 59, 60, 61, 62, 63},
                      cc_labels  = {"ATK", "HOLD", "DEC", "REL", "DIST", "VOL", "PAN", "PORT"} },
  { title = "FILTER", cc_targets = {72, 73, 74, 75, 76, 77, 78, 79},
                      cc_labels  = {"BASE", "WDTH", "HFQ", "LFQ", "ATK", "DEC", "BDFS", "WDFS"} },
  { title = "EFFECTS",cc_targets = {80, 81, 82, 83, 84, 85, 86, 87},
                      cc_labels  = {"EQF", "EQG", "SRR", "DTIM", "DSND", "DFB", "DBAS", "DWID"} },
  { title = "LFO 1",  cc_targets = {88,  89,  90,  91,  92,  93,  94,  95},  cc_labels = LFO_LABELS },
  { title = "LFO 2",  cc_targets = {104, 105, 106, 107, 108, 109, 110, 111}, cc_labels = LFO_LABELS },
  { title = "LFO 3",  cc_targets = {112, 113, 114, 115, 116, 117, 118, 119}, cc_labels = LFO_LABELS }
}

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

local function schedule_stop_resend(data)
  cancel_pending_stop()
  local payload = { table.unpack(data) }
  pending_stop_clock_id = clock.run(function()
    clock.sleep(1)
    midi_out:send(payload)
    pending_stop_clock_id = nil
  end)
end

function init()
  midi_out = midi.connect(1)

  params:add_separator("CC Randomizer Settings")
  params:add_number("cc_val_min", "Value Min", 0, 127, 0)
  params:add_number("cc_val_max", "Value Max", 0, 127, 127)

  params:add_separator("Bank MIDI Channels")
  for b = 1, num_banks do
    params:add_number("bank_" .. b .. "_channel", "Bank " .. b .. " Channel", 1, 16, b)
  end

  params:add_separator("MIDI Forwarding")
  params:add_number("midi_in_device", "Input Device (port)", 1, 16, 1)
  params:set_action("midi_in_device", function(val) connect_midi_in(val) end)
  params:add_option("forward_notes",     "Forward Notes",     {"off", "on"}, 2)
  params:add_option("forward_cc_in",     "Forward CC In",     {"off", "on"}, 2)
  params:add_option("forward_clock",     "Forward Clock",     {"off", "on"}, 2)
  params:add_option("forward_transport", "Forward Transport", {"off", "on"}, 2)

  params:add_separator("Auto Param Lock")
  params:add_number("midi_in_device_2", "Auto-Lock Trigger Port", 1, 16, 2)
  params:set_action("midi_in_device_2", function(val) connect_midi_in_2(val) end)

  connect_midi_in(params:get("midi_in_device"))
  connect_midi_in_2(params:get("midi_in_device_2"))

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

local function is_on(param_id)
  return params:get(param_id) == 2
end

local function get_bank_channel(bank)
  return params:get("bank_" .. bank .. "_channel")
end

local function get_active_channel()
  return get_bank_channel(current_bank)
end

local function get_active_values()
  return bank_values[current_bank][current_page]
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
    if is_on("forward_clock") then midi_out:send(data) end
    return
  end
  if status == STATUS_START or status == STATUS_CONTINUE then
    cancel_pending_stop()
    if is_on("forward_transport") then midi_out:send(data) end
    return
  end
  if status == STATUS_STOP then
    if is_on("forward_transport") then
      midi_out:send(data)
      schedule_stop_resend(data)
    end
    return
  end

  -- System common transport-related messages.
  if status == STATUS_SONG_POSITION or status == STATUS_SONG_SELECT then
    if is_on("forward_transport") then midi_out:send(data) end
    return
  end

  -- Anything else in the system range (sysex, tune req, active sense, reset): ignore.
  if status >= 0xF0 then return end

  -- Channel-voice messages.
  local high = status & 0xF0

  if high == STATUS_CC then
    if is_on("forward_cc_in") then midi_out:send(data) end
    return
  end

  if high == STATUS_NOTE_ON
      or high == STATUS_NOTE_OFF
      or high == STATUS_POLY_PRESSURE
      or high == STATUS_CHANNEL_PRESSURE
      or high == STATUS_PITCH_BEND
      or high == STATUS_PROGRAM_CHANGE then
    if is_on("forward_notes") then
      midi_out:send(with_channel(data, get_active_channel()))
    end
    return
  end
end

-- Secondary input: trigger-only. Used by Auto Param Lock to reroll on every
-- new note-on for the active bank's auto-lock channel. Nothing from this
-- port is forwarded to the output.
function handle_midi_in_2(data)
  if not auto_lock_active then return end
  if not data or #data == 0 then return end

  local status = data[1]
  if (status & 0xF0) ~= STATUS_NOTE_ON then return end

  local velocity = data[3] or 0
  if velocity == 0 then return end -- velocity-0 note-on is a note-off

  local channel = (status & 0x0F) + 1
  if channel ~= auto_lock_channel_for_bank(current_bank) then return end

  send_dice_roll_slot(selected_slot)
end

function get_current_page_data()
  return page_data[current_page]
end

local function randomize_slot(slot)
  local current_data = get_current_page_data()
  local values = get_active_values()
  local cc = current_data.cc_targets[slot]
  if cc < 0 then return end

  local val_min = params:get("cc_val_min")
  local val_max = params:get("cc_val_max")
  local ch = get_active_channel()
  local val = math.random(val_min, val_max)

  values[slot] = val
  midi_out:cc(cc, val, ch)
  print(string.format("🎲 B%d P%d S%d → CC %d = %d (ch %d)",
    current_bank, current_page, slot, cc, val, ch))
end

function send_dice_roll()
  for i = 1, num_slots_per_page do
    randomize_slot(i)
  end
end

function send_dice_roll_slot(slot)
  randomize_slot(slot)
end

function key(n, z)
  if n == 1 then
    k1_held = (z == 1)
  elseif n == 3 and z == 1 then
    send_dice_roll()
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
      current_page = util.clamp(current_page + d, 1, num_pages)
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
        midi_out:cc(cc, new_val, get_active_channel())
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

  -- Auto-lock indicator (K2 hold = single-slot reroll on incoming triggers).
  if auto_lock_active then
    screen.rect(15, 1, 4, 4)
    screen.fill()
  end

  local title = current_data.title
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
  screen.text(string.format("E1:%02d", current_page))
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
