-- Direct FFI bindings to ncurses (the wide-character build, libncursesw).
-- This is the only file that talks to the C library: a thin, policy-free
-- layer exposing exactly the calls and attribute constants lupus uses.
-- Screen lifecycle, colors, and drawing live in lupus/tui/screen.lua.

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
typedef struct _win_st WINDOW;
typedef unsigned int chtype;

WINDOW *initscr(void);
int     endwin(void);
bool    isendwin(void);

int raw(void);
int noecho(void);
int curs_set(int visibility);

bool has_colors(void);
int  start_color(void);
int  use_default_colors(void);
int  init_pair(short pair, short fg, short bg);

int werase(WINDOW *win);
int wmove(WINDOW *win, int y, int x);
int waddnstr(WINDOW *win, const char *str, int n);
int wattrset(WINDOW *win, int attrs);
int wclrtoeol(WINDOW *win);
int wnoutrefresh(WINDOW *win);
int doupdate(void);
int clearok(WINDOW *win, bool bf);
int leaveok(WINDOW *win, bool bf);
int scrollok(WINDOW *win, bool bf);
int resizeterm(int lines, int columns);
int getmaxx(WINDOW *win);
int getmaxy(WINDOW *win);

char *setlocale(int category, const char *locale);
]]

--- Candidate libraries, most specific first: the homebrew wide build (keg-
--- only, never on the default search path), then whatever the dynamic
--- linker can find. On macOS the plain "ncurses" fallback is the ancient
--- system 5.7, which still supports everything this file declares.
local candidates = {
  "/usr/local/opt/ncurses/lib/libncursesw.dylib",
  "/opt/homebrew/opt/ncurses/lib/libncursesw.dylib",
  "ncursesw",
  "ncurses",
}

local lib, lib_path
for _, name in ipairs(candidates) do
  local ok, loaded = pcall(ffi.load, name)
  if ok then
    lib, lib_path = loaded, name
    break
  end
end
assert(lib, "lupus: could not load ncurses (tried " .. table.concat(candidates, ", ") .. ")")

local nc = {
  C = lib,          -- raw library handle: nc.C.initscr(), ...
  path = lib_path,
}

--- setlocale(LC_ALL, "") so ncursesw interprets output as UTF-8. LC_ALL is
--- 0 on BSD/macOS libc, 6 on glibc.
function nc.init_locale()
  local LC_ALL = (ffi.os == "OSX" or ffi.os == "BSD") and 0 or 6
  ffi.C.setlocale(LC_ALL, "")
end

-- Attribute bits, ncurses ABI: NCURSES_BITS(mask, shift) = mask << (shift + 8).
local function bits(mask, shift)
  return bit.lshift(mask, shift + 8)
end

nc.A = {
  NORMAL = 0,
  STANDOUT = bits(1, 8),
  UNDERLINE = bits(1, 9),
  REVERSE = bits(1, 10),
  BLINK = bits(1, 11),
  DIM = bits(1, 12),
  BOLD = bits(1, 13),
  ITALIC = bits(1, 23),
}

--- The attribute selecting color pair n (COLOR_PAIR(n)).
function nc.color_pair(n)
  return bits(n, 0)
end

return nc
