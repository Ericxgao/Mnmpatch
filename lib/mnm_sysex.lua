-- Monomachine sysex protocol helpers.
--
-- Message framing (from the MNM sysex reference, manual appendix C):
--   F0 00 20 3C 03 00 <message id> <payload...> F7
--
-- Dump payloads are packed (RLE) and then 7-bit encoded:
--   * 7-bit encoding: groups of up to 8 sysex data bytes decode to up to 7
--     8-bit bytes; the first byte of each group carries the MSBs (bit 6 =
--     MSB of byte 1 ... bit 0 = MSB of byte 7).
--   * RLE (applied to the decoded 8-bit stream): if bit 7 of a byte is
--     set, its low 7 bits are a repeat count for the byte that follows;
--     otherwise the byte is literal.
--
-- Dump messages end with a 14-bit checksum (2 data) and a 14-bit length
-- (2 data). Length counts bytes from "version" through the checksum.

local MnmSysex = {}

MnmSysex.HEADER = { 0x00, 0x20, 0x3C, 0x03, 0x00 }

MnmSysex.KIT_DUMP        = 0x52
MnmSysex.KIT_REQUEST     = 0x53
MnmSysex.STATUS_REQUEST  = 0x70
MnmSysex.STATUS_RESPONSE = 0x72

-- Status request parameter for "current kit number". 0x02 matches the
-- Machinedrum's documented status params; VERIFY ON HARDWARE — if the
-- status response comes back with a different param byte, adjust here.
MnmSysex.STATUS_CURRENT_KIT = 0x02

-- Status request parameter for "currently selected audio track" (0-5).
-- From MCL: MNM_CURRENT_AUDIO_TRACK_REQUEST = 0x22.
MnmSysex.STATUS_CURRENT_AUDIO_TRACK = 0x22

-- Machine model IDs (from the MNM sysex reference "assign machine" list;
-- matches MCL's MNM_*_MODEL constants). types[track] distinguishes synth
-- machines (0) from MID machines (1): a MID track reports model 0 + type 1.
MnmSysex.MACHINE_NAMES = {
  [0]  = "GND-GND",   [1]  = "GND-SIN",   [2]  = "GND-NOIS",
  [3]  = "SID-6581",
  [4]  = "SWAVE-SAW", [5]  = "SWAVE-PULS",[14] = "SWAVE-ENS",
  [6]  = "DPRO-WAVE", [7]  = "DPRO-BBOX", [32] = "DPRO-DDRW", [33] = "DPRO-DENS",
  [8]  = "FM+-STAT",  [9]  = "FM+-PAR",   [10] = "FM+-DYN",
  [11] = "VO-VO6",
  [12] = "FX-THRU",   [13] = "FX-REVERB", [15] = "FX-CHORUS",
  [16] = "FX-DYNAMIX",[17] = "FX-RINGMOD",[18] = "FX-PHASER", [19] = "FX-FLANGER",
}

-- SYNTH page parameter names per machine model (param index 0..7 = knobs
-- 1..8 = CCs 48..55). From MCL resource/machine_param_names.cpp; block
-- assignment follows that file's own comments (its MNMParams.cpp offset
-- map disagrees for SID/SWAVE, but the names themselves clearly match the
-- machines as documented in the MNM manual). Params absent from a table
-- are unused knobs on that machine. FX-PHASER/FLANGER have no table in
-- MCL; they fall back to generic labels.
MnmSysex.SYNTH_PARAM_NAMES = {
  [1]  = { [7] = "TUN" },                                                 -- GND-SIN
  [2]  = { [0] = "ST", [1] = "RED", [7] = "TUN" },                        -- GND-NOIS
  [3]  = { [0] = "PW", [1] = "PWD", [2] = "PWR", [3] = "WAV",
           [4] = "MOD", [5] = "MSR", [6] = "MFQ", [7] = "TUN" },          -- SID-6581
  [4]  = { [0] = "UNL", [1] = "UNW", [2] = "UNX", [4] = "SBX",
           [5] = "SB1", [6] = "SB2", [7] = "TUN" },                       -- SWAVE-SAW
  [5]  = { [0] = "UNL", [1] = "UNW", [2] = "SB1", [3] = "SB2",
           [4] = "PW", [5] = "PWD", [6] = "PWR", [7] = "TUN" },           -- SWAVE-PULS
  [14] = { [0] = "PC2", [1] = "PC3", [2] = "PC4", [3] = "WAV",
           [4] = "PW", [5] = "CHL", [6] = "CHW", [7] = "TUN" },           -- SWAVE-ENS
  [6]  = { [0] = "WAV", [1] = "WP", [2] = "WPM", [3] = "WPR",
           [4] = "SYN", [5] = "SFQ", [7] = "TUN" },                       -- DPRO-WAVE
  [7]  = { [0] = "PTC", [1] = "STR", [4] = "RTG", [5] = "RTM" },          -- DPRO-BBOX
  [32] = { [0] = "WV1", [1] = "MIX", [2] = "WV2", [3] = "TIM",
           [4] = "BR1", [5] = "WID", [6] = "BR2", [7] = "TUN" },          -- DPRO-DDRW
  [33] = { [0] = "PC2", [1] = "PC3", [2] = "PC4", [3] = "WAV",
           [5] = "CHL", [6] = "CHW", [7] = "TUN" },                       -- DPRO-DENS
  [8]  = { [0] = "1FQ", [1] = "1FI", [2] = "1NV", [3] = "1FB",
           [4] = "2FQ", [5] = "2VL", [6] = "TON", [7] = "TUN" },          -- FM+-STAT
  [9]  = { [0] = "1FQ", [1] = "1NV", [2] = "2FQ", [3] = "2NV",
           [4] = "3FQ", [5] = "3NV", [6] = "TON", [7] = "TUN" },          -- FM+-PAR
  [10] = { [0] = "1FQ", [1] = "1FN", [2] = "1VL", [3] = "1VN",
           [4] = "2FQ", [5] = "2NV", [6] = "2FB", [7] = "TUN" },          -- FM+-DYN
  [11] = { [0] = "VC1", [1] = "VC2", [2] = "VSW", [3] = "VOI",
           [4] = "CNS", [5] = "CLN", [6] = "VCL", [7] = "TUN" },          -- VO-VO6
  [12] = { [7] = "INP" },                                                 -- FX-THRU
  [13] = { [0] = "DEC", [1] = "DMP", [2] = "GAT", [3] = "MIX",
           [4] = "HP", [5] = "LP", [7] = "INP" },                         -- FX-REVERB
  [15] = { [0] = "DEL", [1] = "DEP", [2] = "SPD", [3] = "MIX",
           [4] = "FB", [5] = "WID", [6] = "LP", [7] = "INP" },            -- FX-CHORUS
  [16] = { [0] = "ATK", [1] = "REL", [2] = "THR", [3] = "MIX",
           [4] = "RAT", [5] = "GAI", [6] = "RMS", [7] = "INP" },          -- FX-DYNAMIX
  [17] = { [0] = "WAV", [1] = "EXT", [3] = "MIX", [7] = "INP" },          -- FX-RINGMOD
}

-- Name of SYNTH page param 0..7 for a machine model, or nil when unknown
-- (unlisted model, MID machine, or an unused knob on that machine).
function MnmSysex.synth_param_name(model, param_index)
  local t = MnmSysex.SYNTH_PARAM_NAMES[model]
  return t and t[param_index] or nil
end

-- Whether a machine actually has SYNTH param `param_index` (0-based):
--   true  = the machine exposes that knob,
--   false = that knob is unused on the machine (e.g. DPRO-WAVE has no
--           param 6 / 7th knob),
--   nil   = the model is unknown to us (MID track, or a machine with no
--           param table like FX-PHASER/FLANGER), so existence is unknown.
-- Not all machines expose 8 params; the gaps per model are exactly the
-- indices missing from SYNTH_PARAM_NAMES. For reference:
--   GND-SIN: only 7 · GND-NOIS: 0,1,7 · SWAVE-SAW: no 3 · DPRO-WAVE: no 6
--   DPRO-BBOX: 0,1,4,5 · DPRO-DENS: no 4 · FX-THRU: only 7
--   FX-REVERB: no 6 · FX-RINGMOD: 0,1,3,7 · (all others expose 0..7)
function MnmSysex.synth_param_exists(model, param_index)
  local t = MnmSysex.SYNTH_PARAM_NAMES[model]
  if not t then return nil end
  return t[param_index] ~= nil
end

-- Modulation-source knobs (SYNC selectors) ----------------------------
-- On some machines the 5th SYNTH knob (param index 4, CC 52) is a
-- modulation-source selector: a discrete 3-state list OFF / SFRQ / PRCH.
-- PRCH means "previous channel" (sync to the track below), which is
-- undesirable when randomizing a single voice, so rolls of this knob must
-- avoid the PRCH bucket. The CC splits 0..127 into 3 even buckets; we
-- allow only the first two, emitted as bucket midpoints (same convention
-- as the LFO TRIG roll).
MnmSysex.MODSRC_PARAM_INDEX = 4 -- 0-based: 5th knob, CC 52
local MODSRC_STATES = 3
local MODSRC_FORBIDDEN_STATE = 3 -- 1-based: PRCH is the last state

-- Machine models whose 5th knob is such a mod-source selector.
MnmSysex.MODSRC_MACHINES = {
  [3] = true, -- SID-6581
  [6] = true, -- DPRO-WAVE
}

MnmSysex.MODSRC_ALLOWED_VALUES = {}
for state = 1, MODSRC_STATES do
  if state ~= MODSRC_FORBIDDEN_STATE then
    table.insert(MnmSysex.MODSRC_ALLOWED_VALUES,
      math.floor((state - 0.5) * 128 / MODSRC_STATES))
  end
end

-- True when this machine's given SYNTH param (0-based) is a mod-source
-- selector whose PRCH state must be excluded from rolls.
function MnmSysex.is_modsrc_param(model, param_index)
  return MnmSysex.MODSRC_MACHINES[model] == true
    and param_index == MnmSysex.MODSRC_PARAM_INDEX
end

-- Per MCL's getMNMMachineNameShort: the type byte only distinguishes MID
-- machines for model 0 (synth machines carry type 1 as a matter of course,
-- so type must NOT be treated as a general MID flag).
function MnmSysex.machine_name(model, machine_type)
  if model == 0 and machine_type == 1 then
    return "MID"
  end
  return MnmSysex.MACHINE_NAMES[model] or string.format("?%d", model)
end

local function message(id, payload)
  local msg = { 0xF0 }
  for _, b in ipairs(MnmSysex.HEADER) do table.insert(msg, b) end
  table.insert(msg, id)
  for _, b in ipairs(payload or {}) do table.insert(msg, b & 0x7F) end
  table.insert(msg, 0xF7)
  return msg
end

function MnmSysex.kit_request(kit_number)
  return message(MnmSysex.KIT_REQUEST, { kit_number })
end

-- Request the live edit-buffer kit (reflects unsaved edits). The third
-- payload byte is a workspace flag; MCL sends {0x53, kit, 1} for this
-- (see MNMClass::requestKit / getWorkSpaceKit in the MCL sources).
function MnmSysex.workspace_kit_request()
  return message(MnmSysex.KIT_REQUEST, { 0, 1 })
end

function MnmSysex.status_request(param)
  return message(MnmSysex.STATUS_REQUEST, { param })
end

-- 7-bit groups -> 8-bit bytes.
function MnmSysex.decode_7bit(data)
  local out = {}
  local i = 1
  while i <= #data do
    local msbs = data[i]
    local group_len = math.min(7, #data - i)
    for j = 1, group_len do
      local msb = (msbs >> (7 - j)) & 1
      table.insert(out, (msb << 7) | data[i + j])
    end
    i = i + group_len + 1
  end
  return out
end

-- Expand the RLE packing of the 8-bit stream.
function MnmSysex.rle_expand(bytes)
  local out = {}
  local i = 1
  while i <= #bytes do
    local b = bytes[i]
    if (b & 0x80) ~= 0 then
      local count = b & 0x7F
      local value = bytes[i + 1]
      if value == nil then break end -- truncated run at end of stream
      for _ = 1, count do table.insert(out, value) end
      i = i + 2
    else
      table.insert(out, b)
      i = i + 1
    end
  end
  return out
end

-- Streaming receiver: accumulates bytes across midi.event chunks until a
-- complete F0..F7 message arrives, then parses the MNM header and hands
-- { id = <message id>, data = <payload bytes, 7-bit> } to the callback.
-- feed() returns true if the chunk was consumed as sysex.
-- Set true to log receiver activity (sysex start/end, header bytes) to
-- the console; useful when debugging why a dump isn't being picked up.
MnmSysex.debug = false

function MnmSysex.new_receiver(callback)
  local self = { active = false, buffer = {} }

  local function finish()
    local buf = self.buffer
    self.active = false
    self.buffer = {}
    if MnmSysex.debug then
      local head = {}
      for i = 1, math.min(#buf, 8) do
        table.insert(head, string.format("%02X", buf[i]))
      end
      print(string.format("mnm_sysex: complete sysex, %d bytes, head: %s",
        #buf, table.concat(head, " ")))
    end
    for i, expected in ipairs(MnmSysex.HEADER) do
      if buf[1 + i] ~= expected then
        print(string.format(
          "mnm_sysex: ignoring sysex with foreign header (byte %d = %02X)",
          1 + i, buf[1 + i] or -1))
        return
      end
    end
    local id = buf[2 + #MnmSysex.HEADER]
    local data = {}
    for i = 3 + #MnmSysex.HEADER, #buf - 1 do
      table.insert(data, buf[i])
    end
    callback({ id = id, data = data })
  end

  function self:feed(chunk)
    -- Realtime messages (clock etc) interleave with sysex as separate
    -- chunks; never consume them so the caller can still forward them.
    if chunk[1] >= 0xF8 then return false end
    if not self.active and chunk[1] ~= 0xF0 then return false end
    for _, b in ipairs(chunk) do
      if b == 0xF0 then
        if MnmSysex.debug then print("mnm_sysex: sysex start") end
        self.active = true
        self.buffer = { b }
      elseif self.active and b < 0xF8 then
        -- realtime bytes (clock etc) may interleave mid-sysex; skip them
        table.insert(self.buffer, b)
        if b == 0xF7 then finish() end
      end
    end
    return true
  end

  return self
end

-- Parse a kit dump payload (the bytes after the 0x52 message id) into
-- position, kit name, and per-track machine info.
--
-- Payload layout (mirrors MCL MNMKit::fromSysex):
--   [1] version, [2] revision, [3] kit position,
--   [4] extra workspace flag byte, ONLY when version == 64,
--   then the packed body, then 2 data checksum + 2 data length.
-- Unpacked body layout: name[11], levels[6], parameters[6][72],
--   models[6], types[6], ... (rest not needed here).
-- types[t] == 1 marks a MID (MIDI sequencer) machine.
function MnmSysex.parse_kit(payload)
  local version = payload[1]
  local body_start = (version == 64) and 5 or 4

  local packed = {}
  for i = body_start, #payload - 4 do
    table.insert(packed, payload[i])
  end
  local u = MnmSysex.rle_expand(MnmSysex.decode_7bit(packed))

  local MODELS_OFFSET = 11 + 6 + 6 * 72 -- name + levels + parameters
  if #u < MODELS_OFFSET + 12 then
    return nil, string.format("kit dump too short after unpack (%d bytes)", #u)
  end

  -- Name is null-terminated within its 11 bytes; bytes after the
  -- terminator are uninitialized padding, so stop at the first NUL.
  local name = {}
  for i = 1, 11 do
    local c = u[i]
    if not c or c == 0 then break end
    if c >= 32 and c < 127 then table.insert(name, string.char(c)) end
  end

  local machines = {}
  for t = 1, 6 do
    local model = u[MODELS_OFFSET + t]
    local mtype = u[MODELS_OFFSET + 6 + t]
    machines[t] = {
      model = model,
      type = mtype,
      name = MnmSysex.machine_name(model, mtype),
    }
  end

  return {
    position = payload[3],
    version = version,
    name = table.concat(name),
    machines = machines,
  }
end

return MnmSysex
