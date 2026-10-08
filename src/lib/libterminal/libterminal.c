/*
** Terminal for Byte: process handling from lite-xl-terminal v1.09
** (https://github.com/adamharrison/lite-xl-terminal), emulation by libvterm
** (src/lib/libvterm, https://www.leonerd.org.uk/code/libvterm/).
*/

#if _WIN32
  // https://devblogs.microsoft.com/commandline/windows-command-line-introducing-the-windows-pseudo-console-conpty/
  #if __MINGW32__ || __MINGW64__ // https://stackoverflow.com/questions/66419746/is-there-support-for-winpty-in-mingw-w64
    #define NTDDI_VERSION 0x0A000006 //NTDDI_WIN10_RS5
    #undef _WIN32_WINNT
    #define _WIN32_WINNT 0x0A00 // _WIN32_WINNT_WIN10
  #endif
  #include <windows.h>
  #include <wincon.h>
#else
  #include <unistd.h>
  #include <fcntl.h>
  #include <sys/ioctl.h>
  #include <sys/types.h>
  #include <sys/wait.h>
  #include <signal.h>
  #if __APPLE__
    #include <util.h>
  #else
    #include <pty.h>
  #endif
#endif
#include <stdint.h>
#include <stdio.h>
#include <assert.h>
#include <errno.h>
#include <stdlib.h>
#include <ctype.h>
#include <time.h>
#include <string.h>
#include <math.h>
#include <sys/stat.h>

#include "../lua/lua.h"
#include "../lua/lauxlib.h"
#include "../lua/lualib.h"

#ifndef min
  static int min(int a, int b) { return a < b ? a : b; }
  static int max(int a, int b) { return a > b ? a : b; }
#endif

#include "../libvterm/vterm.h"
#include "../libvterm/vterm_internal.h" // for the DEC modes the Lua side asks about

#define LIBTERMINAL_CHUNK_SIZE 4096
#define LIBTERMINAL_MAX_CHUNKS_PROCESSED 64
#define LIBTERMINAL_NAME_MAX 256

// Colors handed to Lua are 32-bit numbers: attributes << 24 | r << 16 | g << 8 | b,
// where an indexed color keeps its index in the r byte.
typedef enum attributes_e {
  ATTRIBUTE_UNSET_COLOR = 0,
  ATTRIBUTE_INVERSE_COLOR = 1,
  ATTRIBUTE_INDEX_COLOR = 2,
  ATTRIBUTE_RGB_COLOR = 3,
  ATTRIBUTE_BOLD = 8,
  ATTRIBUTE_ITALIC = 16,
  ATTRIBUTE_UNDERLINE = 32,
  ATTRIBUTE_WIDE = 64,                               // A double-width character, padded with a space so it spans two columns.
} attributes_e;

// A cell as stored in the scrollback and handed to Lua; colors are encoded as above, before reverse video.
typedef struct cell_t {
  uint32_t chars[2];                                 // Base character and one combining character (e.g. an emoji variation selector).
  uint32_t fg, bg;
  uint8_t width;                                     // 1, 2, or 0 for the right half of a wide character.
  uint8_t reverse;
} cell_t;

typedef struct scrollback_line_t {
  int columns;
  int continuation;                                  // Whether this line wraps into the next one.
  cell_t cells[];
} scrollback_line_t;

typedef enum mode_e {
  MODE_PTY,
  MODE_DUMMY
} mode_e;

typedef struct {
  int debug;                                         // If true, dumps output to working directory in a file called `terminal.log`.
  VTerm* vt;
  VTermScreen* screen;
  VTermState* state;
  int columns, lines;
  scrollback_line_t** scrollback;                    // Ring buffer of lines scrolled off the top, newest at (scrollback_head - 1).
  int scrollback_limit, scrollback_head, scrollback_count;
  int scrollback_position;                           // How many lines the view is scrolled back.
  int shifts;                                        // Lines pushed into the scrollback since the last update.
  int cursor_x, cursor_y, cursor_visible, cursor_blink;
  int alt_screen;
  int mouse_mode;                                    // VTERM_PROP_MOUSE_*
  mode_e mode;
  char name[LIBTERMINAL_NAME_MAX];                   // Window title, set with an OSC 0/2.
  int name_length;
  #if _WIN32
    PROCESS_INFORMATION process_information;
    HPCON hpcon;
    HANDLE topty;
    HANDLE frompty;
    char nonblocking_buffer[LIBTERMINAL_CHUNK_SIZE];
    int nonblocking_buffer_length;
    HANDLE nonblocking_buffer_mutex;
    HANDLE nonblocking_thread;
    int closing;
  #else
    int master;                                      // FD for pty.
    pid_t pid;                                       // pid for shell.
  #endif
} terminal_t;


static int codepoint_to_utf8(unsigned int codepoint, char* target) {
  if (codepoint < 128) {
    *(target++) = codepoint;
    return 1;
  } else if (codepoint < 2048) {
    *(target++) = 0xC0 | (codepoint >> 6);
    *(target++) = 0x80 | ((codepoint >> 0) & 0x3F);
    return 2;
  } else if (codepoint < 65536) {
    *(target++) = 0xE0 | (codepoint >> 12);
    *(target++) = 0x80 | ((codepoint >> 6) & 0x3F);
    *(target++) = 0x80 | ((codepoint >> 0) & 0x3F);
    return 3;
  }
  *(target++) = 0xF0 | (codepoint >> 18);
  *(target++) = 0x80 | ((codepoint >> 12) & 0x3F);
  *(target++) = 0x80 | ((codepoint >> 6) & 0x3F);
  *(target++) = 0x80 | ((codepoint >> 0) & 0x3F);
  return 4;
}


// --- conversions between libvterm cells and our cells

static uint32_t encode_color(const VTermColor* color, int foreground) {
  if (foreground ? VTERM_COLOR_IS_DEFAULT_FG(color) : VTERM_COLOR_IS_DEFAULT_BG(color))
    return ATTRIBUTE_UNSET_COLOR;
  if (VTERM_COLOR_IS_INDEXED(color))
    return ((uint32_t)ATTRIBUTE_INDEX_COLOR << 24) | ((uint32_t)color->indexed.idx << 16);
  return ((uint32_t)ATTRIBUTE_RGB_COLOR << 24) | ((uint32_t)color->rgb.red << 16) | ((uint32_t)color->rgb.green << 8) | color->rgb.blue;
}

static void decode_color(terminal_t* terminal, uint32_t value, int foreground, VTermColor* color) {
  switch (value >> 24 & 7) {
    case ATTRIBUTE_INDEX_COLOR: vterm_color_indexed(color, (value >> 16) & 0xFF); break;
    case ATTRIBUTE_RGB_COLOR: vterm_color_rgb(color, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF); break;
    default: {
      VTermColor fg, bg;
      vterm_state_get_default_colors(terminal->state, &fg, &bg);
      *color = foreground ? fg : bg;
    } break;
  }
}

static void cell_from_vterm(const VTermScreenCell* in, cell_t* out) {
  out->chars[0] = in->chars[0] == (uint32_t)-1 ? 0 : in->chars[0];
  out->chars[1] = in->chars[0] && in->chars[0] != (uint32_t)-1 ? in->chars[1] : 0;
  out->width = in->chars[0] == (uint32_t)-1 ? 0 : (uint8_t)in->width;
  out->fg = encode_color(&in->fg, 1);
  out->bg = encode_color(&in->bg, 0);
  if (in->attrs.bold) out->fg |= (uint32_t)ATTRIBUTE_BOLD << 24;
  if (in->attrs.italic) out->fg |= (uint32_t)ATTRIBUTE_ITALIC << 24;
  if (in->attrs.underline) out->fg |= (uint32_t)ATTRIBUTE_UNDERLINE << 24;
  out->reverse = in->attrs.reverse;
}

static void cell_to_vterm(terminal_t* terminal, const cell_t* in, VTermScreenCell* out) {
  memset(out, 0, sizeof(*out));
  out->chars[0] = in->width == 0 ? (uint32_t)-1 : in->chars[0];
  out->chars[1] = in->chars[1];
  out->width = in->width ? in->width : 1;
  decode_color(terminal, in->fg, 1, &out->fg);
  decode_color(terminal, in->bg, 0, &out->bg);
  uint32_t attributes = in->fg >> 24;
  out->attrs.bold = !!(attributes & ATTRIBUTE_BOLD);
  out->attrs.italic = !!(attributes & ATTRIBUTE_ITALIC);
  out->attrs.underline = !!(attributes & ATTRIBUTE_UNDERLINE);
  out->attrs.reverse = in->reverse;
}


// --- scrollback

static scrollback_line_t* terminal_scrollback_line(terminal_t* terminal, int index) { // index 0 is the newest
  if (index < 0 || index >= terminal->scrollback_count)
    return NULL;
  int i = (terminal->scrollback_head - 1 - index + terminal->scrollback_limit) % terminal->scrollback_limit;
  return terminal->scrollback[i];
}

static void terminal_clear_scrollback_buffer(terminal_t* terminal) {
  for (int i = 0; i < terminal->scrollback_limit && terminal->scrollback; ++i) {
    free(terminal->scrollback[i]);
    terminal->scrollback[i] = NULL;
  }
  terminal->scrollback_head = terminal->scrollback_count = terminal->scrollback_position = 0;
}

static int terminal_scrollback(terminal_t* terminal, int target) {
  terminal->scrollback_position = max(0, min(target, terminal->scrollback_count));
  return terminal->scrollback_position;
}

static int on_sb_pushline(int cols, const VTermScreenCell* cells, void* user) {
  terminal_t* terminal = user;
  if (terminal->scrollback_limit <= 0)
    return 0;
  scrollback_line_t* line = malloc(sizeof(scrollback_line_t) + sizeof(cell_t) * cols);
  if (!line)
    return 0;
  line->columns = cols;
  const VTermLineInfo* info = vterm_state_get_lineinfo(terminal->state, 1);
  line->continuation = terminal->lines > 1 && info && info->continuation;
  for (int i = 0; i < cols; ++i)
    cell_from_vterm(&cells[i], &line->cells[i]);
  free(terminal->scrollback[terminal->scrollback_head]);
  terminal->scrollback[terminal->scrollback_head] = line;
  terminal->scrollback_head = (terminal->scrollback_head + 1) % terminal->scrollback_limit;
  if (terminal->scrollback_count < terminal->scrollback_limit)
    terminal->scrollback_count++;
  else if (terminal->scrollback_position > 0)
    terminal->scrollback_position = min(terminal->scrollback_position, terminal->scrollback_count);
  terminal->shifts++;
  return 1;
}

// When the screen grows, libvterm pulls lines back down from the scrollback.
static int on_sb_popline(int cols, VTermScreenCell* cells, void* user) {
  terminal_t* terminal = user;
  if (terminal->scrollback_count == 0)
    return 0;
  terminal->scrollback_head = (terminal->scrollback_head - 1 + terminal->scrollback_limit) % terminal->scrollback_limit;
  scrollback_line_t* line = terminal->scrollback[terminal->scrollback_head];
  terminal->scrollback[terminal->scrollback_head] = NULL;
  terminal->scrollback_count--;
  terminal->scrollback_position = min(terminal->scrollback_position, terminal->scrollback_count);
  cell_t blank = { { 0, 0 }, 0, 0, 1, 0 };
  for (int i = 0; i < cols; ++i)
    cell_to_vterm(terminal, i < line->columns ? &line->cells[i] : &blank, &cells[i]);
  free(line);
  return 1;
}

static int on_sb_clear(void* user) {
  terminal_clear_scrollback_buffer((terminal_t*)user);
  return 1;
}

static int on_movecursor(VTermPos pos, VTermPos oldpos, int visible, void* user) {
  terminal_t* terminal = user;
  terminal->cursor_x = pos.col;
  terminal->cursor_y = pos.row;
  return 1;
}

static int on_settermprop(VTermProp prop, VTermValue* val, void* user) {
  terminal_t* terminal = user;
  switch (prop) {
    case VTERM_PROP_CURSORVISIBLE: terminal->cursor_visible = val->boolean; break;
    case VTERM_PROP_CURSORBLINK: terminal->cursor_blink = val->boolean; break;
    case VTERM_PROP_ALTSCREEN: terminal->alt_screen = val->boolean; break;
    case VTERM_PROP_MOUSE: terminal->mouse_mode = val->number; break;
    case VTERM_PROP_TITLE: {
      if (val->string.initial)
        terminal->name_length = 0;
      size_t n = min((int)val->string.len, (int)sizeof(terminal->name) - 1 - terminal->name_length);
      memcpy(&terminal->name[terminal->name_length], val->string.str, n);
      terminal->name_length += n;
      terminal->name[terminal->name_length] = 0;
    } break;
    default: break;
  }
  return 1;
}

static VTermScreenCallbacks screen_callbacks = {
  .movecursor = on_movecursor,
  .settermprop = on_settermprop,
  .sb_pushline = on_sb_pushline,
  .sb_popline = on_sb_popline,
  .sb_clear = on_sb_clear,
};


// --- I/O

static void terminal_input(terminal_t* terminal, const char* str, int len) {
  if (terminal->mode == MODE_PTY) {
    #ifdef _WIN32
      WriteFile(terminal->topty, str, len, NULL, NULL);
    #else
      while (len > 0) {
        ssize_t written = write(terminal->master, str, len);
        if (written < 0) {
          if (errno == EAGAIN || errno == EINTR) { usleep(1000); continue; }
          break;
        }
        str += written;
        len -= written;
      }
    #endif
  } else if (terminal->vt) {
    vterm_input_write(terminal->vt, str, len);
  }
}

// replies from libvterm (device attributes, cursor reports, mouse and focus events) go to the program
static void on_output(const char* s, size_t len, void* user) {
  terminal_t* terminal = user;
  if (terminal->mode == MODE_PTY)
    terminal_input(terminal, s, (int)len);
}

static void terminal_output(terminal_t* terminal, const char* str, int len) {
  if (terminal->debug) {
    FILE* file = fopen("terminal.log", "ab");
    if (file) {
      fwrite(str, sizeof(char), len, file);
      fclose(file);
    }
  }
  vterm_input_write(terminal->vt, str, len);
  vterm_screen_flush_damage(terminal->screen);
}

#ifdef _WIN32
  static DWORD windows_nonblocking_thread_callback(void* data) {
    terminal_t* terminal = (terminal_t*)data;
    char chunk_buffer[LIBTERMINAL_CHUNK_SIZE];
    while (1) {
      DWORD bytes_read;
      if (sizeof(chunk_buffer) - terminal->nonblocking_buffer_length > 0 || terminal->closing) {
        if (terminal->closing) {
          while (1) {
            if (!ReadFile(terminal->frompty, chunk_buffer, sizeof(chunk_buffer), &bytes_read, NULL) || bytes_read == 0)
              break;
          }
          return 0;
        }
        if (!ReadFile(terminal->frompty, chunk_buffer, sizeof(chunk_buffer) - terminal->nonblocking_buffer_length, &bytes_read, NULL))
          break;
        if (bytes_read > 0) {
          WaitForSingleObject(terminal->nonblocking_buffer_mutex, INFINITE);
          memcpy(&terminal->nonblocking_buffer[terminal->nonblocking_buffer_length], chunk_buffer, bytes_read);
          terminal->nonblocking_buffer_length += bytes_read;
          ReleaseMutex(terminal->nonblocking_buffer_mutex);
        }
      }
      Sleep(1);
    }
    return 0;
  }
#endif

static int terminal_update(terminal_t* terminal, void (*callback)(char*, int, void*), void* data, int* total_shifts) {
  if (terminal->mode == MODE_DUMMY)
    return 0;
  char chunk[LIBTERMINAL_CHUNK_SIZE];
  int at_least_one = 0;
  terminal->shifts = 0;
  #ifdef _WIN32
    WaitForSingleObject(terminal->nonblocking_buffer_mutex, INFINITE);
    if (terminal->nonblocking_buffer_length > 0) {
      int len = terminal->nonblocking_buffer_length;
      memcpy(chunk, terminal->nonblocking_buffer, len);
      terminal->nonblocking_buffer_length = 0;
      ReleaseMutex(terminal->nonblocking_buffer_mutex);
      terminal_output(terminal, chunk, len);
      if (callback)
        callback(chunk, len, data);
      at_least_one = 1;
    } else
      ReleaseMutex(terminal->nonblocking_buffer_mutex);
  #else
    for (int chunks = 0; chunks < LIBTERMINAL_MAX_CHUNKS_PROCESSED; ++chunks) {
      int len = read(terminal->master, chunk, sizeof(chunk));
      if (len <= 0)
        break; // EAGAIN: nothing more for now; 0 / EIO: the program exited
      terminal_output(terminal, chunk, len);
      if (callback)
        callback(chunk, len, data);
      at_least_one = 1;
    }
  #endif
  *total_shifts += terminal->shifts;
  return at_least_one;
}

static int terminal_close(terminal_t* terminal) {
  terminal_clear_scrollback_buffer(terminal);
  if (terminal->vt) {
    vterm_free(terminal->vt);
    terminal->vt = NULL;
    terminal->screen = NULL;
    terminal->state = NULL;
  }
  if (terminal->mode == MODE_PTY) {
    #if _WIN32
      terminal->closing = 1;
      if (terminal->hpcon) {
        ClosePseudoConsole(terminal->hpcon);
        terminal->hpcon = NULL;
      }
      if (terminal->nonblocking_thread) {
        TerminateThread(terminal->nonblocking_thread, 0);
        terminal->nonblocking_thread = NULL;
      }
      if (terminal->topty) {
        CloseHandle(terminal->topty);
        terminal->topty = NULL;
      }
      if (terminal->frompty) {
        CloseHandle(terminal->frompty);
        terminal->frompty = NULL;
      }
      if (terminal->nonblocking_buffer_mutex) {
        CloseHandle(terminal->nonblocking_buffer_mutex);
        terminal->nonblocking_buffer_mutex = NULL;
      }
      if (terminal->process_information.hProcess) {
        TerminateProcess(terminal->process_information.hProcess, 1);
        terminal->process_information.hProcess = NULL;
      }
    #else
      if (terminal->pid) {
        if (terminal->master) {
          close(terminal->master);
          terminal->master = 0;
          kill(terminal->pid, SIGHUP);
        }
        int status;
        if (waitpid(terminal->pid, &status, WNOHANG))
          terminal->pid = 0;
        else
          return -1;
      }
    #endif
  }
  return 0;
}

static void terminal_free(terminal_t* terminal) {
  terminal_close(terminal);
  #ifdef _WIN32
  #else
    if (terminal->pid)
      kill(terminal->pid, SIGKILL);
  #endif
  free(terminal->scrollback);
  free(terminal);
}

static void terminal_resize(terminal_t* terminal, int columns, int lines) {
  columns = max(columns, 1);
  lines = max(lines, 1);
  if (terminal->columns == columns && terminal->lines == lines)
    return;
  terminal->columns = columns;
  terminal->lines = lines;
  if (terminal->vt) {
    vterm_set_size(terminal->vt, lines, columns);
    vterm_screen_flush_damage(terminal->screen);
  }
  if (terminal->mode == MODE_PTY) {
    #ifdef _WIN32
      COORD size = { columns, lines };
      ResizePseudoConsole(terminal->hpcon, size);
    #else
      struct winsize size = { .ws_row = lines, .ws_col = columns, .ws_xpixel = 0, .ws_ypixel = 0 };
      ioctl(terminal->master, TIOCSWINSZ, &size);
    #endif
  }
  terminal->scrollback_position = min(terminal->scrollback_position, terminal->scrollback_count);
}

static int terminal_init_vterm(terminal_t* terminal, int columns, int lines, int scrollback_limit) {
  terminal->columns = max(columns, 1);
  terminal->lines = max(lines, 1);
  terminal->scrollback_limit = max(scrollback_limit, 1);
  terminal->scrollback = calloc(terminal->scrollback_limit, sizeof(scrollback_line_t*));
  terminal->cursor_visible = 1;
  terminal->vt = vterm_new(terminal->lines, terminal->columns);
  if (!terminal->scrollback || !terminal->vt)
    return -1;
  vterm_set_utf8(terminal->vt, 1);
  vterm_output_set_callback(terminal->vt, on_output, terminal);
  terminal->state = vterm_obtain_state(terminal->vt);
  terminal->screen = vterm_obtain_screen(terminal->vt);
  vterm_screen_set_callbacks(terminal->screen, &screen_callbacks, terminal);
  vterm_screen_enable_altscreen(terminal->screen, 1);
  vterm_screen_enable_reflow(terminal->screen, true);
  vterm_screen_reset(terminal->screen, 1);
  return 0;
}

static char error_step[64];
static int set_error_step(const char* step) { strncpy(error_step, step, sizeof(error_step)); return 1; }
#if _WIN32
  long long last_error_code;
  static const char* terminal_get_last_error() {
    static char error_buffer[2048];
    strcpy(error_buffer, error_step);
    int len = strlen(error_buffer);
    error_buffer[len++] = ':';
    error_buffer[len++] = ' ';
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, last_error_code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), (LPSTR)&error_buffer[len], sizeof(error_buffer) - (len + 1), NULL);
    return error_buffer;
  }
#else
  // TODO, non-windows error handling, but less important because windows will be failing lots more, 'cause it's shit.
  static const char* terminal_get_last_error() { return error_step; }
#endif

static terminal_t* terminal_new(int columns, int lines, int scrollback_limit, const char* term_env, const char* pathname, const char** argv, const char** environment) {
  terminal_t* terminal = calloc(sizeof(terminal_t), 1);
  terminal->mode = pathname && strcmp(pathname, "DUMMY") != 0 ? MODE_PTY : MODE_DUMMY;
  if (terminal->mode == MODE_PTY) {
    #ifdef _WIN32
      last_error_code = 0;
      HRESULT result = S_OK;
      SECURITY_ATTRIBUTES no_sec = { .nLength = sizeof(SECURITY_ATTRIBUTES), .bInheritHandle = TRUE, .lpSecurityDescriptor = NULL };
      HANDLE out_pipe_pseudo_console_side, in_pipe_pseudo_console_side;
      COORD size = { columns, lines };
      if ((!CreatePipe(&in_pipe_pseudo_console_side, &terminal->topty, &no_sec, 0) || !CreatePipe(&terminal->frompty, &out_pipe_pseudo_console_side, &no_sec, 0)) && set_error_step("create pipes"))
        goto error;
      result = CreatePseudoConsole(size, in_pipe_pseudo_console_side, out_pipe_pseudo_console_side, 0, &terminal->hpcon);
      if (FAILED(result) && set_error_step("create pseudoconsole"))
        goto error;
      terminal->nonblocking_buffer_mutex = CreateMutex(NULL, FALSE, NULL);
      if (!terminal->nonblocking_buffer_mutex && set_error_step("create mutex"))
        goto error;

      HANDLE handles_to_inherit[] = { in_pipe_pseudo_console_side, out_pipe_pseudo_console_side };
      STARTUPINFOEXW si_ex = {0};
      si_ex.StartupInfo.cb = sizeof(STARTUPINFOEXW);
      si_ex.StartupInfo.dwFlags |= STARTF_USESTDHANDLES;
      si_ex.StartupInfo.hStdInput = NULL;
      si_ex.StartupInfo.hStdOutput = NULL;
      si_ex.StartupInfo.hStdError = NULL;
      size_t list_size;
      // Create the appropriately sized thread attribute list
      InitializeProcThreadAttributeList(NULL, 2, 0, &list_size);
      si_ex.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(list_size);
      BOOL success = InitializeProcThreadAttributeList(si_ex.lpAttributeList, 2, 0, (PSIZE_T)&list_size) &&
        UpdateProcThreadAttribute(si_ex.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, terminal->hpcon, sizeof(HPCON), NULL, NULL);
        UpdateProcThreadAttribute(si_ex.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles_to_inherit, sizeof(handles_to_inherit), NULL, NULL);
      if (!success && set_error_step("update proc attribute list")) {
        DeleteProcThreadAttributeList(si_ex.lpAttributeList);
        free(si_ex.lpAttributeList);
        goto error;
      }

      int len = MultiByteToWideChar(CP_UTF8, 0, pathname, -1, NULL, 0);
      wchar_t* commandline = malloc(sizeof(wchar_t)*(len+1));
      len = MultiByteToWideChar(CP_UTF8, 0, pathname, -1, commandline, len);
      success = CreateProcessW(NULL, commandline, NULL, NULL, TRUE, EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, (void*)environment[0], NULL, &si_ex.StartupInfo, &terminal->process_information);
      DeleteProcThreadAttributeList(si_ex.lpAttributeList);
      free(si_ex.lpAttributeList);
      free(commandline);
      if (!success && set_error_step("create process"))
        goto error;
      terminal->nonblocking_thread = CreateThread(NULL, 0, windows_nonblocking_thread_callback, terminal, 0, NULL);
      if (!terminal->nonblocking_thread && set_error_step("create thread"))
        goto error;
      error:
      if (!terminal->nonblocking_thread) {
        last_error_code = FAILED(result) ? HRESULT_CODE(result) : GetLastError();
        terminal_close(terminal);
        free(terminal);
        return NULL;
      }
    #else
      struct termios term = {0};
      term.c_cc[VINTR] = 3;
      term.c_cc[VSTART] = '\x13';
      term.c_cc[VSTOP] = '\x11';
      term.c_cc[VSUSP] = 26;
      term.c_cc[VERASE] = '\x7F';
      term.c_cc[VEOL] = 0;
      term.c_cc[VEOF] = 4;
      term.c_lflag |= ISIG | ECHO | ICANON | IEXTEN | ECHOE | ECHOK | ECHOCTL | ECHOKE;
      term.c_cflag |= CS8 | CREAD;
      term.c_iflag |= IUTF8 | ICRNL | IXON;
      term.c_oflag |= OPOST | ONLCR | NL0 | CR0 | TAB0 | BS0 | VT0 | FF0;
      terminal->pid = forkpty(&terminal->master, NULL, &term, NULL);
      if (terminal->pid == -1 && set_error_step("forkpty")) {
        free(terminal);
        return NULL;
      }
      if (!terminal->pid) {
        setenv("TERM", term_env, 1);
        for (int i = 0; i < 256 && environment[i]; i += 2)
          setenv(environment[i], environment[i+1], 1);
        execvp(pathname,  (char** const)argv);
        exit(-1);
        return NULL;
      }
      int flags = fcntl(terminal->master, F_GETFD, 0);
      fcntl(terminal->master, F_SETFL, flags | O_NONBLOCK);
    #endif
  }
  if (terminal_init_vterm(terminal, columns, lines, scrollback_limit) && set_error_step("libvterm")) {
    terminal_free(terminal);
    return NULL;
  }
  #ifndef _WIN32
    if (terminal->mode == MODE_PTY) {
      struct winsize size = { .ws_row = terminal->lines, .ws_col = terminal->columns, .ws_xpixel = 0, .ws_ypixel = 0 };
      ioctl(terminal->master, TIOCSWINSZ, &size);
    }
  #endif
  return terminal;
}


// Pushes one line as { fg, bg, text, fg, bg, text, ... }; text holds one codepoint per column
// (a wide character is followed by a padding space) and the last run ends in "\n" unless the line wraps.
static void output_line(lua_State* L, const cell_t* cells, int count, int continuation) {
  static char* text_buffer = NULL;
  static size_t text_buffer_size = 0;
  size_t needed = (size_t)count * 5 + 8;
  if (needed > text_buffer_size) {
    char* grown = realloc(text_buffer, needed);
    if (!grown)
      luaL_error(L, "out of memory");
    text_buffer = grown;
    text_buffer_size = needed;
  }
  // trailing blanks with the default background are dropped
  int end = count;
  while (end > 0 && cells[end - 1].chars[0] == 0 && (cells[end - 1].reverse ? cells[end - 1].fg : cells[end - 1].bg) >> 24 == ATTRIBUTE_UNSET_COLOR && cells[end - 1].width != 0)
    --end;
  lua_newtable(L);
  int group = 0, length = 0, run_open = 0;
  uint32_t run_fg = 0, run_bg = 0;
  for (int i = 0; i <= end; ++i) {
    const cell_t* cell = i < end ? &cells[i] : NULL;
    if (cell && cell->width == 0)
      continue; // right half of a wide character
    uint32_t fg = 0, bg = 0;
    if (cell) {
      fg = cell->fg; bg = cell->bg;
      if (cell->reverse) {
        uint32_t styling = fg & 0xFF000000 & ~((uint32_t)7 << 24);
        uint32_t new_fg = (bg >> 24 & 7) == ATTRIBUTE_UNSET_COLOR ? ((uint32_t)ATTRIBUTE_INVERSE_COLOR << 24) : bg;
        uint32_t new_bg = (fg >> 24 & 7) == ATTRIBUTE_UNSET_COLOR ? ((uint32_t)ATTRIBUTE_INVERSE_COLOR << 24) : (fg & ~((uint32_t)0xF8 << 24));
        fg = new_fg | styling;
        bg = new_bg;
      }
      if (cell->width == 2)
        fg |= (uint32_t)ATTRIBUTE_WIDE << 24;
    }
    int wide = cell && cell->width == 2;
    // a wide character always gets a run of its own, so Lua can tell
    if (run_open && (!cell || wide || fg != run_fg || bg != run_bg || (run_fg >> 24 & ATTRIBUTE_WIDE))) {
      lua_pushnumber(L, (double)run_fg); lua_rawseti(L, -2, ++group);
      lua_pushnumber(L, (double)run_bg); lua_rawseti(L, -2, ++group);
      lua_pushlstring(L, text_buffer, length);
      if (!cell && !continuation) { lua_pushliteral(L, "\n"); lua_concat(L, 2); }
      lua_rawseti(L, -2, ++group);
      run_open = 0;
      length = 0;
    }
    if (!cell)
      break;
    if (!run_open) {
      run_open = 1;
      run_fg = fg;
      run_bg = bg;
    }
    // one codepoint per column: Lua measures text by codepoints, so combining marks are left out
    length += codepoint_to_utf8(cell->chars[0] ? cell->chars[0] : ' ', &text_buffer[length]);
    if (wide)
      text_buffer[length++] = ' ';
  }
  if (group == 0) { // empty line
    lua_pushnumber(L, 0); lua_rawseti(L, -2, ++group);
    lua_pushnumber(L, 0); lua_rawseti(L, -2, ++group);
    if (continuation) lua_pushliteral(L, ""); else lua_pushliteral(L, "\n");
    lua_rawseti(L, -2, ++group);
  }
}

static void output_screen_line(lua_State* L, terminal_t* terminal, int row) {
  static cell_t* cells = NULL;
  static int cells_size = 0;
  if (terminal->columns > cells_size) {
    cell_t* grown = realloc(cells, sizeof(cell_t) * terminal->columns);
    if (!grown)
      luaL_error(L, "out of memory");
    cells = grown;
    cells_size = terminal->columns;
  }
  for (int x = 0; x < terminal->columns; ++x) {
    VTermScreenCell cell;
    VTermPos pos = { .row = row, .col = x };
    if (vterm_screen_get_cell(terminal->screen, pos, &cell))
      cell_from_vterm(&cell, &cells[x]);
    else
      cells[x] = (cell_t){ { 0, 0 }, 0, 0, 1, 0 };
  }
  const VTermLineInfo* next = row + 1 < terminal->lines ? vterm_state_get_lineinfo(terminal->state, row + 1) : NULL;
  output_line(L, cells, terminal->columns, next && next->continuation);
}


static terminal_t* lua_toterminal(lua_State* L, int index) {
  lua_getfield(L, index, "__terminal");
  terminal_t* terminal = (terminal_t*)lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (!terminal || !terminal->vt)
    luaL_error(L, "terminal is closed");
  return terminal;
}

// lines([start [, end]]): rows from start to end inclusive; negative rows are scrollback (-1 is the newest)
static int f_terminal_lines(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  int scrollback = terminal->alt_screen ? 0 : terminal->scrollback_position;
  int start = -scrollback;
  if (lua_gettop(L) >= 2)
    start = (int) luaL_checknumber(L, 2);
  int end = start + terminal->lines;
  if (lua_gettop(L) >= 3)
    end = (int) luaL_checknumber(L, 3) + 1;
  lua_newtable(L);
  int total_lines = 0;
  for (int row = start; row < end; ++row) {
    if (row < 0) {
      scrollback_line_t* line = terminal->alt_screen ? NULL : terminal_scrollback_line(terminal, -row - 1);
      if (!line)
        continue;
      output_line(L, line->cells, line->columns, line->continuation);
    } else if (row < terminal->lines) {
      output_screen_line(L, terminal, row);
    } else
      break;
    lua_rawseti(L, -2, ++total_lines);
  }
  return 1;
}


#if _WIN32
static LPCWSTR lua_tolutf16(lua_State* L, const char* str, size_t utf8len) {
  if (str && str[0] == 0)
    return L"";
  int len = MultiByteToWideChar(CP_UTF8, 0, str, utf8len, NULL, 0);
  if (len > 0) {
    LPWSTR output = (LPWSTR) malloc(sizeof(WCHAR) * len);
    if (output) {
      len = MultiByteToWideChar(CP_UTF8, 0, str, -1, output, len);
      if (len > 0) {
        lua_pushlstring(L, (char*)output, len * 2);
        free(output);
        return (LPCWSTR)lua_tostring(L, -1);
      }
      free(output);
    }
  }
  return NULL;
}

static const char* lua_toutf8(lua_State* L, LPCWSTR str) {
  int len = WideCharToMultiByte(CP_UTF8, 0, str, -1, NULL, 0, NULL, NULL);
  if (len > 0) {
    char* output = (char *) malloc(sizeof(char) * len);
    if (output) {
      len = WideCharToMultiByte(CP_UTF8, 0, str, -1, output, len, NULL, NULL);
      if (len) {
        lua_pushlstring(L, output, len - 1);
        free(output);
        return lua_tostring(L, -1);
      }
      free(output);
    }
  }
  return NULL;
}
#endif

static int f_terminal_new(lua_State* L) {
  int x = (int) luaL_checknumber(L, 1);
  int y = (int) luaL_checknumber(L, 2);
  int scrollback_limit = (int) luaL_checknumber(L, 3);
  const char* term_env = luaL_checkstring(L, 4);
  const char* path = luaL_checkstring(L, 5);
  char* arguments[256] = {0};
  char* environment[256] = {0};
  arguments[0] = (char*)path;
  arguments[1] = NULL;
  if (lua_type(L, 6) == LUA_TTABLE) {
    for (int i = 0; i < 255; ++i) {
      lua_rawgeti(L, 6, i+1);
      if (!lua_isnil(L, -1)) {
        const char* str = luaL_checkstring(L, -1);
        arguments[i+1] = strdup(str);
        lua_pop(L, 1);
      } else {
        lua_pop(L, 1);
        arguments[i+1] = NULL;
        break;
      }
    }
  }
  #if _WIN32
    size_t envlen;
    const char* env = luaL_checklstring(L, 7, &envlen);
    if (lua_tolutf16(L, env, envlen)) {
      size_t utf16len;
      const char* utf16 = lua_tolstring(L, -1, &utf16len);
      environment[0] = malloc(utf16len);
      memcpy(environment[0], utf16, utf16len);
      lua_pop(L, 1);
    }
  #else
    luaL_checktype(L, 7, LUA_TTABLE);
    lua_pushnil(L);
    int i = 0;
    while (lua_next(L, 7) != 0 && i < 255) {
      environment[i] = strdup(lua_tostring(L, -2));
      environment[i+1] = strdup(lua_tostring(L, -1));
      i = i + 2;
      lua_pop(L, 1);
    }
  #endif
  int debug = lua_toboolean(L, 8);
  terminal_t* terminal = terminal_new(x, y, scrollback_limit, term_env, path, (const char**)arguments, (const char**)environment);
  for (int i = 1; i < 256 && arguments[i]; ++i)
    free(arguments[i]);
  for (int i = 0; i < 256 && environment[i]; ++i)
    free(environment[i]);
  if (!terminal)
    return luaL_error(L, "error creating terminal: %s", terminal_get_last_error());
  terminal->debug = debug;
  lua_newtable(L);
  lua_pushlightuserdata(L, terminal);
  lua_setfield(L, -2, "__terminal");
  luaL_setmetatable(L, "libterminal");
  return 1;
}

#if _WIN32
static int f_terminal_getenv(lua_State* L) {
  LPWCH system_env = GetEnvironmentStringsW(), envp = system_env;
  lua_newtable(L);
  int table = lua_gettop(L);
  while (wcslen(envp) > 0) {
    const char* str = lua_toutf8(L, envp);
    if (str) {
      const char* equal = strstr(str, "=");
      lua_pushlstring(L, str, equal - str);
      lua_pushstring(L, equal + 1);
      lua_rawset(L, table);
      lua_pop(L, 1);
    }
    envp += wcslen(envp) + 1;
  }
  FreeEnvironmentStringsW(system_env);
  return 1;
}
#endif

static int f_terminal_exited(lua_State* L) {
  lua_getfield(L, 1, "__terminal");
  terminal_t* terminal = (terminal_t*)lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (!terminal) {
    lua_pushinteger(L, -1);
    return 1;
  }
  #if _WIN32
    DWORD exit_code;
    if (GetExitCodeProcess(terminal->process_information.hProcess, &exit_code) && exit_code != STILL_ACTIVE) {
      lua_pushinteger(L, exit_code);
    } else
      lua_pushboolean(L, 0);
  #else
    int status;
    if (waitpid(terminal->pid, &status, WNOHANG) > 0) {
      lua_pushinteger(L, WIFEXITED(status) ? WEXITSTATUS(status) : -1);
      lua_pushinteger(L, WIFSIGNALED(status) ? WTERMSIG(status) : -1);
      return 2;
    } else
      lua_pushboolean(L, 0);
  #endif
  return 1;
}


static int f_terminal_gc(lua_State* L) {
  lua_getfield(L, 1, "__terminal");
  terminal_t* terminal = (terminal_t*)lua_touserdata(L, -1);
  if (terminal)
    terminal_free(terminal);
  lua_pushnil(L);
  lua_setfield(L, 1, "__terminal");
  return 0;
}

static int f_terminal_close(lua_State* L) {
  lua_getfield(L, 1, "__terminal");
  terminal_t* terminal = (terminal_t*)lua_touserdata(L, -1);
  lua_pushinteger(L, terminal ? terminal_close(terminal) : 0);
  return 1;
}

static void chunk_update(char* buf, int len, void* L) {
  lua_pushvalue(L, 2);
  lua_pushlstring(L, buf, len);
  lua_call(L, 1, 0);
}

// update([callback]): reads pending output; returns the lines pushed into the scrollback, or false if nothing arrived
static int f_terminal_update(lua_State* L) {
  int status, total_shifts = 0;
  terminal_t* terminal = lua_toterminal(L, 1);
  if (lua_type(L, 2) == LUA_TFUNCTION)
    status = terminal_update(terminal, chunk_update, L, &total_shifts);
  else
    status = terminal_update(terminal, NULL, NULL, &total_shifts);
  if (status != 0)
    lua_pushinteger(L, total_shifts);
  else
    lua_pushboolean(L, 0);
  return 1;
}

static int f_terminal_input(lua_State* L) {
  size_t len;
  terminal_t* terminal = lua_toterminal(L, 1);
  const char* str = luaL_checklstring(L, 2, &len);
  terminal_input(terminal, str, (int)len);
  if (terminal->mode == MODE_DUMMY)
    vterm_screen_flush_damage(terminal->screen);
  return 0;
}

static int f_terminal_size(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  if (lua_gettop(L) > 1) {
    int x = (int) luaL_checknumber(L, 2), y = (int) luaL_checknumber(L, 3);
    terminal_resize(terminal, x, y);
  }
  lua_pushinteger(L, terminal->columns);
  lua_pushinteger(L, terminal->lines);
  return 2;
}

static int f_terminal_cursor(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  lua_pushinteger(L, terminal->cursor_x);
  lua_pushinteger(L, terminal->cursor_y);
  if (!terminal->cursor_visible)
    lua_pushliteral(L, "hidden");
  else if (terminal->cursor_blink)
    lua_pushliteral(L, "blinking");
  else
    lua_pushliteral(L, "solid");
  return 3;
}

static int f_terminal_cursor_keys_mode(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  lua_pushstring(L, terminal->state->mode.cursor ? "application" : "normal");
  return 1;
}

static int f_terminal_keypad_keys_mode(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  lua_pushstring(L, terminal->state->mode.keypad ? "application" : "normal");
  return 1;
}

static int f_terminal_scrollback(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  if (!terminal->alt_screen) {
    if (lua_gettop(L) >= 2)
      terminal_scrollback(terminal, (int) luaL_checknumber(L, 2));
    lua_pushinteger(L, terminal->scrollback_position);
    lua_pushinteger(L, terminal->scrollback_count);
  } else {
    lua_pushinteger(L, 0);
    lua_pushinteger(L, 0);
  }
  return 2;
}

// libvterm only reports focus when the program asked for it (DEC mode 1004)
static int f_terminal_focused(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  if (lua_toboolean(L, 2))
    vterm_state_focus_in(terminal->state);
  else
    vterm_state_focus_out(terminal->state);
  return 0;
}

static int f_terminal_paste_mode(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  lua_pushstring(L, terminal->state->mode.bracketpaste ? "bracketed" : "normal");
  return 1;
}

static int f_terminal_name(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  if (terminal->name[0])
    lua_pushstring(L, terminal->name);
  else
    lua_pushnil(L);
  return 1;
}

static int f_terminal_clear(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  terminal_clear_scrollback_buffer(terminal);
  const char* clear = "\x1B[H\x1B[2J";
  vterm_input_write(terminal->vt, clear, strlen(clear));
  vterm_screen_flush_damage(terminal->screen);
  return 0;
}

static int f_terminal_mouse_tracking_mode(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  switch (terminal->mouse_mode) {
    case VTERM_PROP_MOUSE_CLICK: lua_pushliteral(L, "click"); break;
    case VTERM_PROP_MOUSE_DRAG: lua_pushliteral(L, "drag"); break;
    case VTERM_PROP_MOUSE_MOVE: lua_pushliteral(L, "move"); break;
    default: lua_pushnil(L); break;
  }
  return 1;
}

static int f_terminal_mouse(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  const char* action = luaL_checkstring(L, 2);
  int button = (int) luaL_optnumber(L, 3, 0);
  int col = (int) luaL_checknumber(L, 4), row = (int) luaL_checknumber(L, 5);
  const char* mods = luaL_optstring(L, 6, "");
  VTermModifier mod = VTERM_MOD_NONE;
  if (strstr(mods, "shift")) mod |= VTERM_MOD_SHIFT;
  if (strstr(mods, "alt")) mod |= VTERM_MOD_ALT;
  if (strstr(mods, "ctrl")) mod |= VTERM_MOD_CTRL;
  col = max(0, min(col, terminal->columns - 1));
  row = max(0, min(row, terminal->lines - 1));
  vterm_mouse_move(terminal->vt, row, col, mod);
  if (strcmp(action, "press") == 0 || strcmp(action, "release") == 0)
    vterm_mouse_button(terminal->vt, button, strcmp(action, "press") == 0, mod);
  return 0;
}

static const luaL_Reg terminal_api[] = {
  { "__gc",                f_terminal_gc                     },
  { "new",                 f_terminal_new                    },
  { "close",               f_terminal_close                  },
  { "input",               f_terminal_input                  },
  { "clear",               f_terminal_clear                  },
  { "lines",               f_terminal_lines                  },
  { "size",                f_terminal_size                   },
  { "update",              f_terminal_update                 },
  { "exited",              f_terminal_exited                 },
  #if _WIN32
  { "getenv",              f_terminal_getenv                 },
  #endif
  { "cursor",              f_terminal_cursor                 },
  { "focused",             f_terminal_focused                },
  { "mouse",               f_terminal_mouse                  },
  { "mouse_tracking_mode", f_terminal_mouse_tracking_mode    },
  { "cursor_keys_mode",    f_terminal_cursor_keys_mode       },
  { "keypad_keys_mode",    f_terminal_keypad_keys_mode       },
  { "paste_mode",          f_terminal_paste_mode             },
  { "scrollback",          f_terminal_scrollback             },
  { "name",                f_terminal_name                   },
  { NULL,                  NULL                              }
};


#ifndef LIBTERMINAL_VERSION
  #define LIBTERMINAL_VERSION "2.0-byte-libvterm"
#endif

int luaopen_libterminal(lua_State* L) {
  luaL_newmetatable(L, "libterminal");
  luaL_setfuncs(L, terminal_api, 0);
  lua_pushliteral(L, LIBTERMINAL_VERSION);
  lua_setfield(L, -2, "version");
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  return 1;
}
