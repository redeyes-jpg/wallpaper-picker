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

// Wallhaven API constants (adapted from wallarchy).
var WALLHAVEN_TAGS = [
  "anime", "scenery", "landscape", "nature", "minimal",
  "abstract", "dark", "dark-mode", "4k", "8k",
  "cyberpunk", "retro", "vaporwave", "aesthetic", "space", "neon"
]

var WALLHAVEN_CATEGORIES = [
  {id: "general", label: "General", bit: 4},
  {id: "anime", label: "Anime", bit: 2},
  {id: "people", label: "People", bit: 1}
]

var WALLHAVEN_PURITY = [
  {id: "100", label: "SFW"},
  {id: "010", label: "Sketchy"},
  {id: "001", label: "NSFW"}
]

var WALLHAVEN_SORTINGS = [
  {id: "relevance", label: "Relevance"},
  {id: "random", label: "Random"},
  {id: "date_added", label: "Date Added"},
  {id: "views", label: "Views"},
  {id: "favorites", label: "Favorites"},
  {id: "toplist", label: "Toplist"}
]

var WALLHAVEN_RESOLUTIONS = [
  "1920x1080", "2560x1440", "3840x2160", "5120x2880",
  "2560x1080", "3440x1440", "5120x2160"
]

var WALLHAVEN_RATIOS = ["16x9", "16x10", "21x9", "32x9", "4x3", "5x4", "3x2"]

// Normalize API response to UI shape.
function photoRows(json) {
  var data = json && json.data ? json.data : (json instanceof Array ? json : [])
  var out = []
  for (var i = 0; i < data.length; i++) {
    var p = data[i]
    var thumbs = p.thumbs || {}
    var resolution = p.resolution || ""
    var category = p.category || ""
    var purity = p.purity || ""
    var label = resolution
    if (category) label += label ? " • " + category : category
    if (purity) label += label ? " • " + purity : purity
    out.push({
      wallhavenId: String(p.id || ""),
      thumb: thumbs.small || thumbs.large || "",
      preview: thumbs.large || p.path || "",
      full: p.path || "",
      color: p.color || "",
      label: label,
      link: p.url || "",
      ext: (p.path && p.path.split(".").pop()) || "jpg"
    })
  }
  return out
}

// Bitfield helpers (from wallarchy).
function normalizeBits(bits) {
  if (typeof bits !== "number") return 0
  return bits
}

function bitAt(bits, pos) {
  if (typeof bits !== "number") return 0
  return (bits >> pos) & 1
}

function toggleBit(bits, pos) {
  if (typeof bits !== "number") return 0
  return bits ^ (1 << pos)
}

// Safe JSON parse with size limit and fallback.
function parseJson(text, fallback, maxBytes) {
  if (!text || typeof text !== "string") return fallback
  if (maxBytes && text.length > maxBytes) return fallback
  try {
    return JSON.parse(text)
  } catch (e) {
    return fallback
  }
}

// Boolean coercion with fallback.
function asBool(value, fallback) {
  if (value === true || value === "true" || value === 1 || value === "1") return true
  if (value === false || value === "false" || value === 0 || value === "0") return false
  return fallback
}

// Integer coercion with fallback.
function asInt(value, fallback) {
  var n = Number(value)
  if (isFinite(n)) return Math.round(n)
  return fallback
}

// Human-readable interval label from minutes.
function intervalLabel(minutes) {
  for (var i = 0; i < INTERVALS.length; i++) {
    if (INTERVALS[i].minutes === minutes) return INTERVALS[i].label
  }
  return minutes + "m"
}

// Next interval in the cycle.
function nextInterval(currentMinutes) {
  for (var i = 0; i < INTERVALS.length; i++) {
    if (INTERVALS[i].minutes === currentMinutes) {
      return INTERVALS[(i + 1) % INTERVALS.length].minutes
    }
  }
  return INTERVALS[1].minutes // default to 15m
}