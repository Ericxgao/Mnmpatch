-- Monomachine Randomizer v1.3
--
-- HANJO, Tokyo, Japan.
--
-- 7 banks, each with its own MIDI channel and its own randomized CC
-- values. Banks 1-6 map to MNM tracks 1-6; bank 7 ("CUR") defaults to
-- channel 9, the MNM auto channel, so it always addresses whatever track
-- is currently selected on the machine. CC target layout is shared across
-- banks (so the 7 pages of CCs hit the same parameters on every
-- track, just with independent random values).
--
-- K1: Query the MNM (sysex workspace-kit request on the main output) for
--     the machine assigned to each track; the active bank's machine then
--     shows in the header in place of the channel.
-- K3: Randomize CC values on the current page of the active bank.
--     Hold K3: while held, note-ons on the auto-lock trigger port reroll
--     the whole current page (Auto Page Roll).
-- E1: Change active bank (1..6 = tracks, 7 = CUR/auto channel).
-- E2: Change page (1..7). Scroll left past SYNTH to the "ALL" page:
--     K3 rolls every non-LFO page (SYNTH/AMP/FILTER/EFFECTS) of the
--     active bank, leaving the three LFOs untouched.
-- K2: Cycle edit mode (CC / VAL / MIDI channel).
--     On the ALL page: tapping K2 rolls the three LFO pages of the
--     active bank; holding K2 fills a popup bar and, held to full,
--     clears DPTH to 0 on all three LFOs.
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

local mnm_sysex = include("lib/mnm_sysex")

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

-- Banks 1-6 map to MNM tracks 1-6. Bank 7 is the "CUR" bank: it defaults
-- to channel 9, the MNM's auto channel, so its CCs always hit whatever
-- track is currently selected on the machine.
local num_banks = 7
local CUR_BANK = 7
local CUR_BANK_DEFAULT_CHANNEL = 9

local function bank_default_channel(bank)
  return bank == CUR_BANK and CUR_BANK_DEFAULT_CHANNEL or bank
end

local function bank_display_name(bank)
  return bank == CUR_BANK and "CUR" or ("B" .. bank)
end

-- Virtual page left of SYNTH. Displays the SYNTH page's slots:
--   Page 0 ("ALL"): K3 rolls every non-LFO page (SYNTH/AMP/FILTER/
--   EFFECTS) of the active bank; a K2 tap rolls the three LFO pages,
--   and a K2 hold clears their depths (see LFO depth clear below).
local ALL_PAGE = 0
local FIRST_PAGE = ALL_PAGE
local current_page = 1

local function effective_page()
  return math.max(current_page, 1)
end
local current_bank = CUR_BANK

-- CC target layout is shared across all banks; only values vary per bank.
-- cc_labels (optional) name each slot for display. SYNTH is intentionally
-- left unlabeled and falls back to showing "CC###" in the UI.
local LFO_LABELS = { "PAGE", "DEST", "TRIG", "WAVE", "MULT", "SPD", "INTL", "DPTH" }
local FILTER_LABELS = { "BASE", "WDTH", "HFQ", "LFQ", "ATK", "DEC", "BDFS", "WDFS" }

-- Params (by label) that K3 / auto-lock rolls must never touch.
-- Manual edits (E3 in VAL mode) still work on these slots. SPD is not
-- excluded but rolls from a constrained BPM-synced allowlist
-- (see LFO_ALLOWED_SPD_VALUES below).
local LFO_ROLL_EXCLUDE = { INTL = true }

local page_data = {
  { title = "SYNTH",  cc_targets = {48, 49, 50, 51, 52, 53, 54, 55} },
  { title = "AMP",    cc_targets = {56, 57, 58, 59, 60, 61, 62, 63},
                      cc_labels  = {"ATK", "HOLD", "DEC", "REL", "DIST", "VOL", "PAN", "PORT"},
                      roll_exclude = { ATK = true, HOLD = true, DEC = true, REL = true, VOL = true, PAN = true, PORT = true },
                      roll_min     = { DIST = 64 } },
  -- FILTER: every param is roll-excluded (manual E3 edits still work).
  -- The band slots (BASE/WDTH/BDFS/WDFS) are additionally gated by
  -- FILTER_BAND_ROLL_ENABLED below, so re-enabling rolls here means
  -- trimming this list AND deciding on the band gate.
  { title = "FILTER", cc_targets = {72, 73, 74, 75, 76, 77, 78, 79},
                      cc_labels  = FILTER_LABELS,
                      roll_exclude = { BASE = true, WDTH = true, HFQ = true, LFQ = true,
                                       ATK = true, DEC = true, BDFS = true, WDFS = true } },
  { title = "EFFECTS",cc_targets = {80, 81, 82, 83, 84, 85, 86, 87},
                      cc_labels  = {"EQF", "EQG", "SRR", "DTIM", "DSND", "DFB", "DBAS", "DWID"},
                      roll_exclude = { SRR = true, DTIM = true, DSND = true, DFB = true, DBAS = true, DWID = true },
                      roll_min     = { EQG = 64 } },
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

-- Per-label floor for rolled values (page.roll_min): params like DIST and
-- EQG must never roll below 64. Returns nil when no floor applies.
local function roll_min_for(page, slot)
  if not (page.roll_min and page.cc_labels) then return nil end
  local label = page.cc_labels[slot]
  return label and page.roll_min[label] or nil
end

-- LFO PAGE/DEST constrained rolling ------------------------------------
-- PAGE and DEST are discrete-list params driven by a continuous CC: the
-- MNM splits 0..127 into even buckets (PAGE: 9 entries, DEST: 8 entries,
-- ordered like the target page's 8 knobs). Rolling them freely could aim
-- an LFO at a param we've excluded from rolling, modulating it anyway.
-- Instead, rolls pick a random (page, dest) pair from the allowlist below
-- and emit the midpoint CC value of each bucket.
--
-- HARDWARE-VERIFIED (probing session, Jul 2026): the LFO PAGE CC selects
-- from NINE pages, not 8, so buckets are 128/9 ~ 14.2 wide. Probe results:
--   10 -> PTCH, 32 -> AMP, 56 -> FLT, 72 -> LFO1, 120 -> MIDI, 64 -> EFF
-- All consistent with this order and bucket width (page N, 1-based,
-- spans floor((N-1)*128/9) .. floor(N*128/9)-1):
--   PTCH 0-13, SYN 14-27, AMP 28-42, FLT 43-56, EFF 57-70,
--   LFO1 71-85, LFO2 86-99, LFO3 100-113, MIDI 114-127
-- Gotcha for future work: assuming 8 x 16-wide buckets *appears* to work
-- for the first four pages (their midpoints happen to fall in the right
-- 9-page buckets) but breaks from EFF upward (16-wide midpoint 72 lands
-- in LFO1's bucket).
-- The DEST CC is different: it has 8 even buckets (16-wide), one per knob
-- slot of the target page, in that page's knob order (slot 1 = 0-15, etc).
local LFO_TARGET_PAGE_OPTIONS = { "PTCH", "SYN", "AMP", "FLT", "EFF", "LFO1", "LFO2", "LFO3", "MIDI" }

-- Allowed DEST slots (1..8) per target page; mirrors the roll exclusions
-- above (SYN slot 8 = CC 55). Pages absent from this table are never
-- picked as roll targets. LFO_TARGET_PAGE_OPTIONS still lists every page
-- so the PAGE CC bucket positions stay correct.
local LFO_ALLOWED_DESTS = {
  SYN = { 1, 2, 3, 4, 5, 6, 7 },
  EFF = { 1 }  -- EQF only
}

-- Precomputed target descriptors, one per allowed (page, dest) pair:
--   page_val / dest_val = bucket-midpoint CC values to emit
--   page_name / dest_slot = which page and 1-based knob it selects
-- Midpoints of the 9-page layout above: PTCH 7, SYN 21, AMP 35, FLT 49,
-- EFF 64, LFO1 78, LFO2 92, LFO3 106, MIDI 120. SYN=21 and EFF=64 are the
-- pairs currently rolled and both are hardware-confirmed.
local LFO_TARGET_PAIRS = {}
for page_idx, page_name in ipairs(LFO_TARGET_PAGE_OPTIONS) do
  local page_val = math.floor((page_idx - 0.5) * 128 / #LFO_TARGET_PAGE_OPTIONS)
  for _, dest_slot in ipairs(LFO_ALLOWED_DESTS[page_name] or {}) do
    local dest_val = (dest_slot - 1) * 16 + 8
    table.insert(LFO_TARGET_PAIRS, {
      page_val = page_val, dest_val = dest_val,
      page_name = page_name, dest_slot = dest_slot,
    })
  end
end

local LFO_PAGE_SLOT = 1
local LFO_DEST_SLOT = 2
local LFO_TRIG_SLOT = 3

-- LFO TRIG is also a discrete list (5 entries, even buckets). Rolls may
-- only pick FREE or HOLD. Values are bucket midpoints.
local LFO_TRIG_OPTIONS = { "FREE", "TRIG", "HOLD", "ONE", "HALF" }
local LFO_TRIG_EXCLUDE = { TRIG = true, ONE = true, HALF = true }
local LFO_ALLOWED_TRIG_VALUES = {}
for idx, name in ipairs(LFO_TRIG_OPTIONS) do
  if not LFO_TRIG_EXCLUDE[name] then
    table.insert(LFO_ALLOWED_TRIG_VALUES,
      math.floor((idx - 0.5) * 128 / #LFO_TRIG_OPTIONS))
  end
end

local LFO_SPD_SLOT = 6

-- LFO SPD constrained rolling: the LFO clock ticks 128 times per bar and
-- SPD * MULT ticks elapse per bar, so cycle length = 128 / (SPD * MULT)
-- bars. MULT is always a power of two, so the cycle stays a clean
-- power-of-two multiple/division of the bar exactly when SPD is one too.
-- 127 stands in for the unreachable 128 (the manual's own convention for
-- straight beats: "try setting SPD to 16, 32, 64 or 127").
local LFO_ALLOWED_SPD_VALUES = { 1, 2, 4, 8, 16, 32, 64, 127 }

local function is_lfo_page(page)
  return page.cc_labels == LFO_LABELS
end

-- FILTER constrained rolling -------------------------------------------
-- The MNM filter is a band [BASE, BASE+WDTH]; rolling BASE/WDTH freely
-- often lands the band above the audible range (silence). BDFS/WDFS are
-- bipolar envelope offsets (64 = none) that sweep the band, so they can
-- silence an otherwise-audible patch at envelope peak. Rolls therefore
-- treat BASE+WDTH+BDFS+WDFS as one unit: pick a resting band that meets
-- the audibility invariant, then roll offsets within the headroom that
-- band leaves so the swept band stays audible too. The sweep is linear
-- from rest to peak, so checking both endpoints covers every point.
-- Set true to include the filter band (BASE/WDTH/BDFS/WDFS) in rolls.
-- When false, those four slots are never rolled (pre-band-roll behaviour);
-- manual E3 edits still work.
local FILTER_BAND_ROLL_ENABLED = false

local FILTER_BASE_SLOT = 1
local FILTER_WIDTH_SLOT = 2
local FILTER_BOFS_SLOT = 7
local FILTER_WOFS_SLOT = 8
local FILTER_GROUP_SLOTS = {
  [FILTER_BASE_SLOT] = true, [FILTER_WIDTH_SLOT] = true,
  [FILTER_BOFS_SLOT] = true, [FILTER_WOFS_SLOT] = true,
}

local FILTER_MIN_WIDTH = 40  -- narrowest band (resting or swept) ever rolled
local FILTER_HI_MIN    = 88  -- band top must reach at least this far up
local FILTER_LO_MAX    = 72  -- highest resting base
local FILTER_MAX_SWEEP = 48  -- musical cap on envelope offset magnitude

local function is_filter_page(page)
  return page.cc_labels == FILTER_LABELS
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
--   Channel mapping: bank N listens on channel N (bank 1 -> ch 1, ..., bank 6 -> ch 6);
--   the CUR bank listens on the channel of the MNM's currently selected
--   track (tracked via the current-audio-track status poll).
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

-- LFO depth clear (ALL page only):
--   Holding K2 on the ALL page shows a popup with a bar that fills over
--   LFO_CLEAR_HOLD_TIME. If K2 is held until it fills, DPTH of all three
--   LFOs on the active bank is set to 0 and sent. Releasing early cancels
--   and instead rolls the three LFO pages (K2 tap = LFO roll on ALL;
--   on other pages a tap still cycles edit mode).
local LFO_DPTH_SLOT = 8
local LFO_CLEAR_HOLD_TIME = 0.6
local lfo_clear_clock_id = nil
local lfo_clear_progress = nil  -- 0..1 while the popup is showing, else nil
local lfo_clear_fired = false   -- suppresses edit-mode cycle on release

-- Currently selected audio track on the MNM (1..6), kept fresh by the
-- current-audio-track status poll. nil until the first response arrives.
local mnm_current_track = nil

-- Trigger channel a bank's auto-lock/auto-roll listens on. Banks 1-6
-- listen on their own track's channel. The CUR bank follows whatever
-- track is currently selected on the MNM (polled continuously via
-- STATUS_CURRENT_AUDIO_TRACK); until the first poll answers, the track
-- is unknown and this returns nil (no trigger channel matches yet).
local function auto_lock_channel_for_bank(bank)
  if bank == CUR_BANK then
    return mnm_current_track
  end
  return bank
end

-- MNM machine query:
--   K1 sends a sysex workspace-kit request to the main output (assumed to
--   be the Monomachine). The kit dump reply — which can arrive on either
--   MIDI input — is parsed for the kit name and the machine assigned to
--   each of the 6 tracks. The active bank's machine is shown in the
--   header (banks 1-6; CUR keeps the channel display since the machine
--   depends on which track the MNM has selected).
local mnm_kit_name = nil
local mnm_machines = nil -- [1..6] = { model, type, name }
-- (mnm_current_track is declared above, near auto_lock_channel_for_bank.)

-- Machine info backing a bank's display: banks 1-6 map straight to MNM
-- tracks; CUR resolves through the last-queried current audio track.
-- Until the track status reply arrives, CUR has no machine to show
-- (falls back to CH## in the header).
local function machine_for_bank(bank)
  if not mnm_machines then return nil end
  if bank <= 6 then return mnm_machines[bank] end
  return mnm_current_track and mnm_machines[mnm_current_track] or nil
end

-- Fallback timing: the workspace-kit request reads the live edit buffer
-- but is not honoured by all firmware. Only if no kit dump arrives within
-- this window do we fall back to querying the current *saved* kit (which
-- may be stale, so it must never clobber a workspace result).
local MNM_QUERY_FALLBACK_TIME = 1.0
local mnm_query_fallback_clock_id = nil
local mnm_kit_dump_received = false

local function handle_mnm_sysex(msg)
  -- Status response to our "current kit?" query: fetch that kit by number.
  -- Used as a fallback because the workspace-kit request is not honoured
  -- by all MNM firmware versions.
  if msg.id == mnm_sysex.STATUS_RESPONSE then
    local param, value = msg.data[1], msg.data[2]
    if param == mnm_sysex.STATUS_CURRENT_KIT and value then
      print(string.format("MNM: current kit is %d, requesting its dump...", value))
      midi_out:send(mnm_sysex.kit_request(value))
      midi_out_2:send(mnm_sysex.kit_request(value))
    elseif param == mnm_sysex.STATUS_CURRENT_AUDIO_TRACK and value and value <= 5 then
      if mnm_current_track ~= value + 1 then
        mnm_current_track = value + 1
        print(string.format("MNM: current audio track is %d", mnm_current_track))
      end
    end
    return
  end
  if msg.id ~= mnm_sysex.KIT_DUMP then
    local bytes = {}
    for i = 1, math.min(#msg.data, 8) do
      table.insert(bytes, string.format("%02X", msg.data[i]))
    end
    print(string.format("MNM sysex: ignoring message id 0x%02X (%d data: %s)",
      msg.id, #msg.data, table.concat(bytes, " ")))
    return
  end
  local kit, err = mnm_sysex.parse_kit(msg.data)
  if not kit then
    print("MNM kit dump parse failed: " .. err)
    return
  end
  mnm_kit_dump_received = true

  -- Polling fetches the kit continuously; only log when it changed.
  local changed = (mnm_kit_name ~= kit.name) or (mnm_machines == nil)
  if not changed then
    for t = 1, 6 do
      if mnm_machines[t].model ~= kit.machines[t].model
          or mnm_machines[t].type ~= kit.machines[t].type then
        changed = true
        break
      end
    end
  end

  mnm_kit_name = kit.name
  mnm_machines = kit.machines
  if changed then
    print(string.format("MNM kit '%s' (pos %d):", kit.name, kit.position))
    for t = 1, 6 do
      print(string.format("  track %d: %s (model %d, type %d)",
        t, kit.machines[t].name, kit.machines[t].model, kit.machines[t].type))
    end
  end
end

local mnm_sysex_receiver = mnm_sysex.new_receiver(handle_mnm_sysex)

-- Flip on for verbose sysex logging (receiver start/complete lines);
-- useful when debugging why a dump isn't being picked up.
mnm_sysex.debug = false

-- Keeping machine info fresh: the workspace kit and the current audio
-- track are polled every MNM_POLL_TIME seconds, so kit loads, machine
-- swaps and track changes all show up within one poll cycle. K1 forces
-- an immediate refresh.
local MNM_POLL_TIME = 1.5

-- Selective polling: the workspace kit dump reply is a large sysex blob
-- that shares the MIDI wire with forwarded clock/notes. The MNM stops
-- processing its MIDI input for the duration of the dump, so polls are
-- suspended while transport is running. When stopped, polls run at full
-- rate (and STOP itself triggers an immediate refresh). K1 always
-- force-refreshes regardless of transport state.
--
-- Script (re)start hole: `transport_running` defaults false even mid-
-- playback, so a blind poll would dump into a live set. Many clock
-- sources also keep sending F8 while stopped, so tick presence alone
-- cannot mean "playing". Until a real START/CONTINUE/STOP arrives,
-- polling is also suspended while clock is live AND notes were recently
-- forwarded (mid-playback restart). Clock-while-stopped with no notes
-- polls normally — the header can show machine names without requiring
-- a transport message the sequencer may never send.
local transport_running = false
local transport_state_known = false

-- Tick timestamping is used for tick-phase-aligned sends below
-- (ticks flow even when stopped, so alignment always applies).
local CLOCK_IDLE_TIME = 1.0 -- seconds without a clock tick = no clock source
local last_clock_time = 0

-- Post-restart mid-play detection (ignored once transport_state_known).
local LIVE_NOTE_IDLE_TIME = 2.0
local last_note_forward_time = nil -- set on first forwarded note

local function midi_clock_running()
  return (util.time() - last_clock_time) < CLOCK_IDLE_TIME
end

-- Auto kit/track polls when stopped. K1 bypasses via request_mnm_machines().
local function mnm_polling_suspended()
  if transport_running then return true end
  if not transport_state_known
      and midi_clock_running()
      and last_note_forward_time
      and (util.time() - last_note_forward_time) < LIVE_NOTE_IDLE_TIME then
    return true
  end
  return false
end

-- Tick-phase-aligned sends: while the clock runs, poll requests are not
-- sent from the poll loop directly (they could land right before a tick
-- is due and delay it). Instead they are queued here and flushed by the
-- clock handler immediately AFTER a tick has been forwarded, so the
-- request bytes go out at the start of the inter-tick gap. The gap is
-- ~20.8 ms at 120 BPM (24 PPQN) and the status request is ~10 bytes
-- ≈ 3.2 ms on DIN MIDI, so it fits with a lot of headroom.
-- Queue entries: { out = <midi device>, data = <message bytes> }.
local pending_tick_sends = {}

local function send_between_ticks(out, data)
  if midi_clock_running() then
    table.insert(pending_tick_sends, { out = out, data = data })
  else
    out:send(data)
  end
end

-- Called from the clock handler right after a tick is forwarded.
local function flush_pending_tick_sends()
  if #pending_tick_sends == 0 then return end
  for _, msg in ipairs(pending_tick_sends) do
    msg.out:send(msg.data)
  end
  pending_tick_sends = {}
end

-- One machine query: request the workspace kit (live edit buffer) and the
-- current audio track. Requests go to both output ports since the MNM may
-- sit on either.
-- NO FALLBACK to the saved-kit path: it needs the current-kit status
-- query (0x70 0x02), which this MNM's firmware answers with a truncated
-- sysex AND it wedges the sysex responder — after one of those, every
-- later kit request also comes back truncated until the MNM is
-- power-cycled. If the workspace request goes unanswered we just say so.
local function request_mnm_machines()
  print("MNM: requesting workspace kit + current track...")
  mnm_kit_dump_received = false
  for _, out in ipairs({ midi_out, midi_out_2 }) do
    out:send(mnm_sysex.workspace_kit_request())
    out:send(mnm_sysex.status_request(mnm_sysex.STATUS_CURRENT_AUDIO_TRACK))
  end
  if mnm_query_fallback_clock_id then
    clock.cancel(mnm_query_fallback_clock_id)
  end
  mnm_query_fallback_clock_id = clock.run(function()
    clock.sleep(MNM_QUERY_FALLBACK_TIME)
    mnm_query_fallback_clock_id = nil
    if not mnm_kit_dump_received then
      print("MNM: no workspace kit reply — if this persists, "
        .. "power-cycle the MNM (wedged sysex responder)")
    end
  end)
end

-- Steady-state polling sends only the two 1-byte status queries; the full
-- kit dump is fetched from handle_mnm_sysex when the kit number changes.
-- This keeps the MNM's kit-load view usable while browsing (large sysex
-- dumps glitch its rendering on some firmware).
-- HARDWARE NOTE: the current-kit status query (0x70 0x02) is NOT honoured
-- by this MNM's firmware — worse, it makes the MNM emit a truncated sysex
-- reply (F0 00 20, then nothing), so it must never be polled. Kit-change
-- detection therefore uses the workspace kit dump itself.
-- Both queries are sent only when mnm_polling_suspended() is false (see
-- above — an immediate kit request also fires from the STOP handler).
local function mnm_poll_loop()
  local was_suspended = false
  while true do
    clock.sleep(MNM_POLL_TIME)
    local suspended = mnm_polling_suspended()
    if suspended ~= was_suspended then
      print(suspended
        and "MNM: polling suspended"
        or  "MNM: transport stopped — polling resumed")
      was_suspended = suspended
    end
    -- Clock source vanished with sends still queued (no tick to flush
    -- them): drop them — they are stale requests superseded by the fresh
    -- ones this iteration sends directly.
    if not midi_clock_running() and #pending_tick_sends > 0 then
      pending_tick_sends = {}
    end
    if not suspended then
      for _, out in ipairs({ midi_out, midi_out_2 }) do
        send_between_ticks(out, mnm_sysex.workspace_kit_request())
        send_between_ticks(out,
          mnm_sysex.status_request(mnm_sysex.STATUS_CURRENT_AUDIO_TRACK))
      end
    end
  end
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
    local label = (b == CUR_BANK) and "CUR Bank Channel" or ("Bank " .. b .. " Channel")
    params:add_number("bank_" .. b .. "_channel", label, 1, 16, bank_default_channel(b))
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
  clock.run(mnm_poll_loop)
  clock.run(cc_send_loop)
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

-- Paced CC output: a full ALL-page roll emits ~30 CCs; sent back-to-back
-- they occupy the DIN wire for tens of ms, delaying forwarded clock ticks
-- and note-offs (hung notes on the MNM) and flooding its parser. All
-- randomizer CCs therefore go through a FIFO drained with a small gap
-- between messages, so clock/note traffic can interleave. Order is
-- preserved (grouped sends like LFO PAGE+DEST stay paired). Routing is
-- resolved at send time, matching the previous behaviour.
local CC_SEND_SPACING = 0.003  -- seconds between queued CC sends
local cc_send_queue = {}

local function send_random_cc(cc, val, ch)
  table.insert(cc_send_queue, { cc = cc, val = val, ch = ch })
end

-- Global (not local): init() is defined earlier in the file and resolves
-- this name at call time, same as redraw_loop.
function cc_send_loop()
  while true do
    local msg = table.remove(cc_send_queue, 1)
    if msg then
      if should_send_to_port_1("out_random_cc") then
        midi_out:cc(msg.cc, msg.val, msg.ch)
      end
      if should_send_to_port_2("out_random_cc") then
        midi_out_2:cc(msg.cc, msg.val, msg.ch)
      end
      clock.sleep(CC_SEND_SPACING)
    else
      clock.sleep(0.01)
    end
  end
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
  if mnm_sysex_receiver:feed(data) then return end
  local status = data[1]

  -- System realtime: single-byte, no channel.
  if status == STATUS_CLOCK then
    last_clock_time = util.time()
    if should_send_to_port_1("forward_clock") then midi_out:send(data) end
    if should_send_to_port_2("forward_clock") then midi_out_2:send(data) end
    -- Queued poll requests go out right after the tick, at the start of
    -- the inter-tick gap (see send_between_ticks).
    flush_pending_tick_sends()
    return
  end
  if status == STATUS_START or status == STATUS_CONTINUE then
    transport_state_known = true
    transport_running = true
    cancel_pending_stop()
    if should_send_to_port_1("forward_transport") then midi_out:send(data) end
    if should_send_to_port_2("forward_transport") then midi_out_2:send(data) end
    return
  end
  if status == STATUS_STOP then
    transport_state_known = true
    transport_running = false
    local send_p1 = should_send_to_port_1("forward_transport")
    local send_p2 = should_send_to_port_2("forward_transport")
    if send_p1 then midi_out:send(data) end
    if send_p2 then midi_out_2:send(data) end
    if send_p1 or send_p2 then
      schedule_stop_resend(data, send_p1, send_p2)
    end
    -- Transport just stopped: fetch the kit and current track right away
    -- so changes made during playback (polling is fully suspended then)
    -- show up without waiting for the next poll cycle.
    for _, out in ipairs({ midi_out, midi_out_2 }) do
      send_between_ticks(out, mnm_sysex.workspace_kit_request())
      send_between_ticks(out,
        mnm_sysex.status_request(mnm_sysex.STATUS_CURRENT_AUDIO_TRACK))
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
    local sent = false
    if should_send_to_port_1("forward_notes") then
      midi_out:send(out_data)
      sent = true
    end
    if should_send_to_port_2("forward_notes") then
      midi_out_2:send(out_data)
      sent = true
    end
    if sent then last_note_forward_time = util.time() end
    return
  end
end

-- Secondary input: Auto Param Lock / Auto Page Roll triggers, and sysex
-- listen (the MNM often sits on this port). Nothing is forwarded out.
function handle_midi_in_2(data)
  if not data or #data == 0 then return end
  if mnm_sysex_receiver:feed(data) then return end
  if not (auto_lock_active or auto_roll_page_active) then return end

  local status = data[1]
  if (status & 0xF0) ~= STATUS_NOTE_ON then return end

  local velocity = data[3] or 0
  if velocity == 0 then return end -- velocity-0 note-on is a note-off

  local channel = (status & 0x0F) + 1
  local trigger_channel = auto_lock_channel_for_bank(current_bank)
  if trigger_channel == nil then
    -- CUR bank with the MNM's selected track not yet known (no status
    -- poll answered). Say so instead of dropping triggers silently.
    print("auto-roll: CUR bank trigger ignored — current MNM track unknown")
    return
  end
  if channel ~= trigger_channel then return end

  if auto_roll_page_active then
    send_dice_roll()
  else
    send_dice_roll_slot(selected_slot)
  end
end

function get_current_page_data()
  return page_data[effective_page()]
end

-- Zero out DPTH on all three LFO pages of the active bank (K2 hold on ALL).
local function clear_lfo_depths()
  local ch = get_active_channel()
  for p, data in ipairs(page_data) do
    if is_lfo_page(data) then
      local cc = data.cc_targets[LFO_DPTH_SLOT]
      bank_values[current_bank][p][LFO_DPTH_SLOT] = 0
      if cc >= 0 then
        send_random_cc(cc, 0, ch)
      end
    end
  end
  print(string.format("LFO depths cleared on bank %d (ch %d)", current_bank, ch))
end

-- Roll an LFO's PAGE+DEST as one unit: pick a random allowed target pair
-- and emit both CCs, so the LFO never lands on a roll-excluded param.
-- Pairs already targeted by the bank's other LFOs are excluded, so no two
-- LFOs on a track ever modulate the same param. (Rolled targets are always
-- bucket midpoints, so exact value comparison identifies overlaps; manually
-- dialed targets off-midpoint are not detected.)
local function randomize_lfo_target(page)
  local data = page_data[page]
  local values = bank_values[current_bank][page]
  local page_cc = data.cc_targets[LFO_PAGE_SLOT]
  local dest_cc = data.cc_targets[LFO_DEST_SLOT]
  if page_cc < 0 or dest_cc < 0 then return end

  local taken = {}
  for p, pdata in ipairs(page_data) do
    if p ~= page and is_lfo_page(pdata) then
      local other = bank_values[current_bank][p]
      taken[other[LFO_PAGE_SLOT] .. ":" .. other[LFO_DEST_SLOT]] = true
    end
  end

  -- Filter SYN dest slots by the bank's machine (only when it's known;
  -- unknown machines — no kit query yet, or MID tracks — keep the full
  -- SYN allowlist). Two exclusions:
  --   * params the machine doesn't have (e.g. DPRO-WAVE has no 7th knob):
  --     targeting them would modulate nothing.
  --   * mod-source selector knobs (SID-6581 MSR = param 5, DPRO-WAVE SYN
  --     = param 4): an LFO there would sweep the discrete selector,
  --     including into PRCH, which we forbid for value rolls too.
  --     SID's MOD knob (param 4) is a normal continuous param and stays
  --     a valid LFO target.
  local machine = machine_for_bank(current_bank)
  local function dest_allowed(desc)
    if desc.page_name ~= "SYN" or not machine then return true end
    local param_index = desc.dest_slot - 1
    if mnm_sysex.synth_param_exists(machine.model, param_index) == false then
      return false
    end
    if mnm_sysex.is_modsrc_param(machine.model, param_index) then
      return false
    end
    return true
  end

  local candidates = {}
  for _, desc in ipairs(LFO_TARGET_PAIRS) do
    if dest_allowed(desc)
        and not taken[desc.page_val .. ":" .. desc.dest_val] then
      table.insert(candidates, desc)
    end
  end
  -- Guard: if machine filtering + overlap exclusion ever empty the list,
  -- fall back to whatever the machine allows (ignoring overlap), then to
  -- the full list, so a roll always produces a valid target.
  if #candidates == 0 then
    for _, desc in ipairs(LFO_TARGET_PAIRS) do
      if dest_allowed(desc) then table.insert(candidates, desc) end
    end
  end
  if #candidates == 0 then candidates = LFO_TARGET_PAIRS end

  local ch = get_active_channel()
  local desc = candidates[math.random(#candidates)]

  values[LFO_PAGE_SLOT] = desc.page_val
  values[LFO_DEST_SLOT] = desc.dest_val
  send_random_cc(page_cc, desc.page_val, ch)
  send_random_cc(dest_cc, desc.dest_val, ch)
  print(string.format("🎲 B%d P%d LFO target → %s.%d: CC %d = %d, CC %d = %d (ch %d)",
    current_bank, page, desc.page_name, desc.dest_slot,
    page_cc, desc.page_val, dest_cc, desc.dest_val, ch))
end

-- Roll the filter band + envelope offsets as one constrained unit.
-- Emits BASE, WDTH, BDFS, WDFS; guarantees the band is audible at rest
-- and at envelope peak (see FILTER constrained rolling above).
local function randomize_filter_band(page)
  local data = page_data[page]
  local values = bank_values[current_bank][page]
  local ccs = {
    base = data.cc_targets[FILTER_BASE_SLOT],
    width = data.cc_targets[FILTER_WIDTH_SLOT],
    bofs = data.cc_targets[FILTER_BOFS_SLOT],
    wofs = data.cc_targets[FILTER_WOFS_SLOT],
  }
  if ccs.base < 0 or ccs.width < 0 or ccs.bofs < 0 or ccs.wofs < 0 then return end

  -- Resting band [lo, hi]: at least FILTER_MIN_WIDTH wide, top reaching
  -- FILTER_HI_MIN so it always passes meaningful spectrum.
  local lo = math.random(0, FILTER_LO_MAX)
  local hi = math.random(math.max(lo + FILTER_MIN_WIDTH, FILTER_HI_MIN), 127)
  local width = hi - lo

  -- Base offset: signed, bounded by CC range (BDFS = 64 + bofs), the
  -- band's headroom (peak top <= 127), and the musical sweep cap.
  local bofs_min = math.max(-64, -lo, -FILTER_MAX_SWEEP)
  local bofs_max = math.min(63, 127 - hi, FILTER_MAX_SWEEP)
  local bofs = math.random(bofs_min, bofs_max)

  -- Width offset: peak width stays >= FILTER_MIN_WIDTH, peak top stays
  -- >= FILTER_HI_MIN (tightens when bofs sweeps the base down) and
  -- within 0..127.
  local peak_lo = lo + bofs
  local wofs_min = math.max(-64, FILTER_MIN_WIDTH - width, FILTER_HI_MIN - peak_lo - width, -FILTER_MAX_SWEEP)
  local wofs_max = math.min(63, 127 - peak_lo - width, FILTER_MAX_SWEEP)
  local wofs = math.random(math.min(wofs_min, wofs_max), wofs_max)

  local ch = get_active_channel()
  local out = {
    { FILTER_BASE_SLOT, ccs.base, lo },
    { FILTER_WIDTH_SLOT, ccs.width, width },
    { FILTER_BOFS_SLOT, ccs.bofs, 64 + bofs },
    { FILTER_WOFS_SLOT, ccs.wofs, 64 + wofs },
  }
  for _, o in ipairs(out) do
    values[o[1]] = o[3]
    send_random_cc(o[2], o[3], ch)
  end
  print(string.format("🎲 B%d P%d FLT band → lo %d hi %d bofs %+d wofs %+d (ch %d)",
    current_bank, page, lo, hi, bofs, wofs, ch))
end

local function randomize_slot(page, slot)
  local data = page_data[page]
  local values = bank_values[current_bank][page]

  if is_lfo_page(data) and (slot == LFO_PAGE_SLOT or slot == LFO_DEST_SLOT) then
    randomize_lfo_target(page)
    return
  end

  if is_filter_page(data) and FILTER_GROUP_SLOTS[slot] then
    if FILTER_BAND_ROLL_ENABLED then
      randomize_filter_band(page)
    end
    return
  end

  local cc = data.cc_targets[slot]
  if cc < 0 then return end
  if is_roll_excluded(data, slot) then return end

  -- SYNTH mod-source selector knob (SID-6581 MSR / DPRO-WAVE SYN): roll
  -- only that machine's allowed states so it never lands on PRCH
  -- ("previous channel"). Keyed off the queried machine for this bank, so
  -- it only applies when we know the track's machine and the slot still
  -- points at that SYNTH param.
  if cc >= 48 and cc <= 55 then
    local machine = machine_for_bank(current_bank)
    local allowed = machine
      and mnm_sysex.modsrc_allowed_values(machine.model, cc - 48)
    if allowed then
      local ch = get_active_channel()
      local val = allowed[math.random(#allowed)]
      values[slot] = val
      send_random_cc(cc, val, ch)
      print(string.format("🎲 B%d P%d S%d MODSRC → CC %d = %d (ch %d)",
        current_bank, page, slot, cc, val, ch))
      return
    end
  end

  -- LFO TRIG: pick from allowed trig-mode buckets (never ONE).
  if is_lfo_page(data) and slot == LFO_TRIG_SLOT then
    local ch = get_active_channel()
    local val = LFO_ALLOWED_TRIG_VALUES[math.random(#LFO_ALLOWED_TRIG_VALUES)]
    values[slot] = val
    send_random_cc(cc, val, ch)
    print(string.format("🎲 B%d P%d S%d TRIG → CC %d = %d (ch %d)",
      current_bank, page, slot, cc, val, ch))
    return
  end

  -- LFO SPD: pick from the BPM-synced allowlist (powers of two, straight
  -- beats only) so the cycle always stays locked to the bar.
  if is_lfo_page(data) and slot == LFO_SPD_SLOT then
    local ch = get_active_channel()
    local val = LFO_ALLOWED_SPD_VALUES[math.random(#LFO_ALLOWED_SPD_VALUES)]
    values[slot] = val
    send_random_cc(cc, val, ch)
    print(string.format("🎲 B%d P%d S%d SPD → CC %d = %d (ch %d)",
      current_bank, page, slot, cc, val, ch))
    return
  end

  local val_min = params:get("cc_val_min")
  local val_max = params:get("cc_val_max")
  local floor_val = roll_min_for(data, slot)
  if floor_val then
    val_min = math.max(val_min, floor_val)
    val_max = math.max(val_max, val_min)
  end
  local ch = get_active_channel()
  local val = math.random(val_min, val_max)

  values[slot] = val
  send_random_cc(cc, val, ch)
  print(string.format("🎲 B%d P%d S%d → CC %d = %d (ch %d)",
    current_bank, page, slot, cc, val, ch))
end

-- Last page index the ALL-page roll touches (all pages, LFOs included).
local ALL_ROLL_LAST_PAGE = num_pages

-- On the ALL page, roll SYNTH/AMP/FILTER/EFFECTS of the active bank;
-- otherwise just the current page. Roll exclusions apply either way.
-- Roll all slots of one page. Grouped slots roll as one unit via their
-- first slot: on LFO pages slot 1 rolls the PAGE+DEST pair (DEST is
-- skipped), and on the FILTER page slot 1 rolls the BASE+WDTH+BDFS+WDFS
-- band (the other three group slots are skipped).
local function roll_page(page)
  local data = page_data[page]
  for i = 1, num_slots_per_page do
    local skip = (is_lfo_page(data) and i == LFO_DEST_SLOT)
      or (is_filter_page(data) and FILTER_GROUP_SLOTS[i] and i ~= FILTER_BASE_SLOT)
    if not skip then
      randomize_slot(page, i)
    end
  end
end

function send_dice_roll()
  if current_page == ALL_PAGE then
    -- ALL page default: roll every non-LFO page; LFOs roll via K2 tap.
    for p = 1, ALL_ROLL_LAST_PAGE do
      if not is_lfo_page(page_data[p]) then
        roll_page(p)
      end
    end
  else
    roll_page(current_page)
  end
end

-- Roll the three LFO pages of the active bank (K2 tap on the ALL page).
local function roll_lfo_pages()
  for p, data in ipairs(page_data) do
    if is_lfo_page(data) then
      roll_page(p)
    end
  end
end

function send_dice_roll_slot(slot)
  randomize_slot(effective_page(), slot)
end

function key(n, z)
  if n == 1 then
    if z == 1 then
      request_mnm_machines()
    end
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
      if current_page == ALL_PAGE then
        -- ALL page: K2 hold arms the LFO depth clear instead of auto-lock.
        if lfo_clear_clock_id then
          clock.cancel(lfo_clear_clock_id)
          lfo_clear_clock_id = nil
        end
        lfo_clear_fired = false
        lfo_clear_clock_id = clock.run(function()
          local step = 1 / 30
          local elapsed = 0
          lfo_clear_progress = 0
          while elapsed < LFO_CLEAR_HOLD_TIME do
            clock.sleep(step)
            elapsed = elapsed + step
            lfo_clear_progress = math.min(elapsed / LFO_CLEAR_HOLD_TIME, 1)
          end
          clear_lfo_depths()
          lfo_clear_fired = true
          lfo_clear_progress = nil
          lfo_clear_clock_id = nil
        end)
      else
        if k2_hold_clock_id then
          clock.cancel(k2_hold_clock_id)
          k2_hold_clock_id = nil
        end
        k2_hold_clock_id = clock.run(function()
          clock.sleep(AUTO_LOCK_HOLD_THRESHOLD)
          auto_lock_active = true
          k2_hold_clock_id = nil
        end)
      end
    else
      if lfo_clear_clock_id then
        clock.cancel(lfo_clear_clock_id)
        lfo_clear_clock_id = nil
      end
      lfo_clear_progress = nil
      if k2_hold_clock_id then
        clock.cancel(k2_hold_clock_id)
        k2_hold_clock_id = nil
      end
      if lfo_clear_fired then
        lfo_clear_fired = false
      elseif auto_lock_active then
        auto_lock_active = false
      elseif current_page == ALL_PAGE then
        -- ALL page: a K2 tap (released before the clear bar fills)
        -- rolls the three LFO pages instead of cycling edit mode.
        roll_lfo_pages()
      else
        cycle_edit_mode()
      end
    end
  end
end

function enc(n, d)
  local current_data = get_current_page_data()
  if n == 1 then
    current_bank = util.clamp(current_bank + d, 1, num_banks)
  elseif n == 2 then
    current_page = util.clamp(current_page + d, FIRST_PAGE, num_pages)
    selected_slot = 1
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
  screen.text(bank_display_name(current_bank))

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

  local title
  if current_page == ALL_PAGE then
    title = "ALL"
  else
    title = current_data.title
  end
  local title_x = (128 - (#title * 8)) / 2 + 6
  screen.move(title_x, 5)
  screen.text(title)

  screen.move(126, 5)
  local machine = machine_for_bank(current_bank)
  if machine then
    screen.text_right(machine.name)
  else
    screen.text_right(string.format("CH%02d", get_active_channel()))
  end

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
    screen.text("E2:AL")
  else
    screen.text(string.format("E2:%02d", current_page))
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

  -- LFO depth clear popup: filling bar while K2 is held on the ALL page.
  if lfo_clear_progress then
    screen.level(0)
    screen.rect(14, 20, 100, 26)
    screen.fill()
    screen.level(15)
    screen.rect(14, 20, 100, 26)
    screen.stroke()
    screen.move(64, 30)
    screen.text_center("CLEAR LFO DPTH")
    screen.rect(18, 35, math.floor(92 * lfo_clear_progress), 6)
    screen.fill()
  end

  screen.update()
end

function draw_slot(i, page, values, x, y)
  local marker = (selected_slot == i) and ">" or " "
  local cc = page.cc_targets[i]
  local label = page.cc_labels and page.cc_labels[i]

  -- SYNTH page has no static labels: its 8 knobs are machine-specific.
  -- Once a kit has been queried (K1), label slots whose CC is still a
  -- SYNTH param (48-55) with the machine's param name for that knob.
  if not label and cc >= 48 and cc <= 55 then
    local machine = machine_for_bank(current_bank)
    if machine then
      label = mnm_sysex.synth_param_name(machine.model, cc - 48)
    end
  end

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
