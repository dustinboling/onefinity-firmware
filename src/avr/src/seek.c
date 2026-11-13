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

#include "seek.h"

#include "command.h"
#include "switch.h"
#include "estop.h"
#include "util.h"
#include "state.h"

#include <stdint.h>

#include "motor.h"

enum {
  SEEK_ACTIVE = 1 << 0,
  SEEK_ERROR  = 1 << 1,
  SEEK_FOUND  = 1 << 2,
};


typedef struct {
  bool active;
  switch_id_t sw;
  uint8_t flags;
} seek_t;


static seek_t seek = {false, SW_INVALID, 0};


// AVR-3: motor currently switched to stall microsteps, or -1.  Recorded
// when the seek executes so seek_end()/seek_cancel() can restore exactly
// that one motor.
static int stall_motor = -1;


static int _stall_motor_for_switch(switch_id_t sw) {
  switch (sw) {
  case SW_STALL_0: return 0;
  case SW_STALL_1: return 1;
  case SW_STALL_2: return 2;
  case SW_STALL_3: return 3;
  default: return -1;
  }
}


static void _restore_stall_microstep() {
  if (0 <= stall_motor) {
    disable_stall_microstep(stall_motor);
    stall_motor = -1;
  }
}


switch_id_t seek_get_switch() {return seek.active ? seek.sw : SW_INVALID;}

bool seek_active() {
  return seek.active;
}

bool seek_switch_found() {
  if (!seek.active) return false;

  bool inactive = !(seek.flags & SEEK_ACTIVE);

  if (switch_is_active(seek.sw) ^ inactive) {
    seek.flags |= SEEK_FOUND;
    return true;
  }

  return false;
}


void seek_end() {
  if (!seek.active) return;

  if (!(SEEK_FOUND & seek.flags) && (SEEK_ERROR & seek.flags))
    STATUS_WARNING(STAT_SEEK_NOT_FOUND, "", 0);

  _restore_stall_microstep();

  seek.active = false;
}


void seek_cancel() {
  // Also used on queue flush: if a stall seek had already executed (and
  // so switched microsteps) its restore must not be lost with the queue.
  _restore_stall_microstep();

  seek.active = false;
}


// Command callbacks
stat_t command_seek(char *cmd) {
  switch_id_t sw = (switch_id_t)decode_hex_nibble(cmd[1]);
  if (sw <= 0) return STAT_INVALID_ARGUMENTS; // Don't allow seek to ESTOP
  if (!switch_is_enabled(sw)) return STAT_SEEK_NOT_ENABLED;

  uint8_t flags = decode_hex_nibble(cmd[2]);
  if (flags & 0xfc) return STAT_INVALID_ARGUMENTS;

  // AVR-3: do NOT enable stall microsteps here.  This function runs at
  // parse/queue time while earlier moves may still be executing in the
  // old step space; switching steps_per_unit now would invalidate them.
  // The switch happens in command_seek_exec() instead.  A seek that is
  // flushed before executing therefore never disturbs the configuration.

  seek_t seek = {true, sw, flags};
  command_push(*cmd, &seek);

  return STAT_OK;
}


unsigned command_seek_size() {return sizeof(seek_t);}
void command_seek_exec(void *data) {
    seek = *(seek_t *)data;

    // AVR-3: switch to stall microsteps now, at execution time, when all
    // previously queued moves have completed in the old step space.
    stall_motor = _stall_motor_for_switch(seek.sw);
    if (0 <= stall_motor) enable_stall_microstep(stall_motor);
}
