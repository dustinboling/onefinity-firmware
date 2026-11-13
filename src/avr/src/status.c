/******************************************************************************\

                 This file is part of the Buildbotics firmware.

                   Copyright (c) 2015 - 2018, Buildbotics LLC
                              All rights reserved.

      This file ("the software") is free software: you can redistribute it
      and/or modify it under the terms of the GNU General Public License,
       version 2 as published by the Free Software Foundation. You should
       have received a copy of the GNU General Public License, version 2
      along with the software. If not, see <http://www.gnu.org/licenses/>.

      The software is distributed in the hope that it will be useful, but
           WITHOUT ANY WARRANTY; without even the implied warranty of
       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
                Lesser General Public License for more details.

        You should have received a copy of the GNU Lesser General Public
                 License along with the software.  If not, see
                        <http://www.gnu.org/licenses/>.

                 For information regarding this software email:
                   "Joseph Coffland" <joseph@buildbotics.com>

\******************************************************************************/

#include "status.h"
#include "estop.h"
#include "usart.h"

#include <stdio.h>
#include <stdarg.h>


#define STAT_MSG(NAME, TEXT) static const char stat_##NAME[] PROGMEM = TEXT;
#include "messages.def"
#undef STAT_MSG


static const char *const stat_msg[] PROGMEM = {
#define STAT_MSG(NAME, TEXT) stat_##NAME,
#include "messages.def"
#undef STAT_MSG
};


const char *status_to_pgmstr(stat_t code) {
  return (const char *)pgm_read_ptr(&stat_msg[code]);
}


const char *status_level_pgmstr(status_level_t level) {
  switch (level) {
  case STAT_LEVEL_INFO: return PSTR("info");
  case STAT_LEVEL_DEBUG: return PSTR("debug");
  case STAT_LEVEL_WARNING: return PSTR("warning");
  default: return PSTR("error");
  }
}


stat_t status_message_P(const char *location, status_level_t level,
                        stat_t code, const char *msg, ...) {
  // AVR-24: this used to print via printf/putchar, i.e. via the
  // blocking usart_putc().  Status messages are also raised from
  // interrupt-adjacent contexts (e.g. seek_end() from the LO exec
  // interrupt), where spinning on a full TX ring stalls the caller for
  // as long as the ring takes to drain -- or worse.  Format the whole
  // line into a bounded buffer, truncating if necessary, and emit it
  // with the non-blocking usart_try_putc(): if the ring fills, the
  // remainder of this message is dropped instead of blocking.
  char buf[192];
  unsigned len = 0;
  va_list args;

#define STATUS_APPEND(...)                                              \
  do {                                                                  \
    if (len < sizeof(buf)) {                                            \
      int n = snprintf_P(buf + len, sizeof(buf) - len, __VA_ARGS__);    \
      if (0 < n) len += (unsigned)n;                                    \
    }                                                                   \
  } while (0)

  // Type and message text
  STATUS_APPEND(PSTR("\n{\"level\":\"%" PRPSTR "\",\"msg\":\"%" PRPSTR),
                status_level_pgmstr(level), status_to_pgmstr(code));

  if (msg && pgm_read_byte(msg)) {
    STATUS_APPEND(PSTR(": "));

    // TODO escape invalid chars
    if (len < sizeof(buf)) {
      va_start(args, msg);
      int n = vsnprintf_P(buf + len, sizeof(buf) - len, msg, args);
      va_end(args);
      if (0 < n) len += (unsigned)n;
    }
  }

  STATUS_APPEND(PSTR("\""));

  // Code
  if (code) STATUS_APPEND(PSTR(",\"code\":%d"), code);

  // Location
  if (location)
    STATUS_APPEND(PSTR(",\"where\":\"%" PRPSTR "\"}"), location);
  else STATUS_APPEND(PSTR("}"));

  STATUS_APPEND(PSTR("\n"));

#undef STATUS_APPEND

  // Emit, dropping the rest of the line if the TX ring fills
  for (const char *p = buf; *p; p++)
    if (!usart_try_putc(*p)) break;

  return code;
}
