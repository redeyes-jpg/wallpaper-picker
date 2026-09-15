.pragma library

// Shared helpers for the Wallpicker surfaces (overlay + service).

var INTERVALS = [
  { label: "Off", minutes: 0 },
  { label: "15m", minutes: 15 },
  { label: "30m", minutes: 30 },
  { label: "1h", minutes: 60 },
  { label: "3h", minutes: 180 },
  { label: "6h", minutes: 360 },
  { label: "12h", minutes: 720 },
  { label: "Daily", minutes: 1440 }
]

// Process output / config file content is untrusted input as far as the
// shell process is concerned: a wedged shell or a race on the file must not
// be able to blow up the parse.
function parseJson(raw, fallback, limit) {
  try {
    if (typeof raw !== "string") return fallback
    if (raw.length > (limit || 2097152)) return fallback
    var trimmed = raw.trim()
    if (trimmed === "") return fallback
    var parsed = JSON.parse(trimmed)
    return parsed === null || parsed === undefined ? fallback : parsed
  } catch (error) {
    return fallback
  }
}

function asBool(value, fallback) {
  if (value === true || value === "true" || value === 1) return true
  if (value === false || value === "false" || value === 0) return false
  return fallback
}

function asInt(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? Math.round(n) : fallback
}

function intervalLabel(minutes) {
  for (var i = 0; i < INTERVALS.length; i++)
    if (INTERVALS[i].minutes === minutes) return INTERVALS[i].label
  return minutes + "m"
}

function nextInterval(minutes) {
  var index = 0
  for (var i = 0; i < INTERVALS.length; i++)
    if (INTERVALS[i].minutes === minutes)
      index = (i + 1) % INTERVALS.length
  return INTERVALS[index].minutes
}