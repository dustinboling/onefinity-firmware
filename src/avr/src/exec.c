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

#include "exec.h"

#include "stepper.h"
#include "motor.h"
#include "axis.h"
#include "util.h"
#include "command.h"
#include "switch.h"
#include "seek.h"
#include "estop.h"
#include "state.h"
#include "spindle.h"
#include "config.h"
#include "SCurve.h"

#include <util/atomic.h>


static struct {
  // AVR-12: cb and the scalar motion state below are shared between
  // the LO exec ISR, other interrupt contexts and the main loop (var
  // getters).  They are volatile so the compiler cannot cache them
  // across contexts.  position[] is written in the LO ISR and read from
  // the main loop; its accessors copy it under ATOMIC_BLOCK
  // (exec_get_position()/exec_get_axis_position()).  The seg fields are
  // owned by the LO exec context (exec_segment/_segment_exec).
  volatile exec_cb_t cb;

  float position[AXES];
  volatile float velocity;
  volatile float accel;
  volatile float jerk;
  volatile float peak_vel;
  volatile float peak_accel;

  volatile float feed_override;

  struct {
    float target[AXES];
    float time;
    float vel;
    float accel;
    float max_accel;
    float max_jerk;
    power_update_t power_updates[2 * POWER_MAX_UPDATES];
    exec_cb_t cb;
  } seg;
} ex;


static void _limit_switch_cb(switch_id_t sw, bool active) {
  if (sw == seek_get_switch()) return;
  if (ex.velocity && active) estop_trigger(STAT_ESTOP_SWITCH);
}


static bool _limit_switch_active() {
  // AVR-8: poll for an already-tripped limit.  The callback above only
  // fires on a switch *transition* while moving, so a limit that is
  // already active when motion starts (axis parked on its switch,
  // switch held in by a crashed axis, restart after a hold) was
  // invisible and the machine could be driven straight through it.
  // The active seek switch is excluded: running into it is the point
  // of a seek.
  switch_id_t seek_sw = seek_get_switch();

  for (int sw = SW_MIN_0; sw <= SW_MAX_3; sw++)
    if ((switch_id_t)sw != seek_sw && switch_is_enabled((switch_id_t)sw) &&
        switch_is_active((switch_id_t)sw))
      return true;

  return false;
}


void exec_init() {
  memset(&ex, 0, sizeof(ex));
  ex.feed_override = 1; // TODO implement feed override

  // Set callback for limit switches
  for (int sw = SW_MIN_0; sw <= SW_MAX_3; sw++)
    switch_set_callback((switch_id_t)sw, _limit_switch_cb);
}


void exec_get_position(float p[AXES]) {
  // AVR-12: ex.position[] is updated by the LO exec ISR; copy it
  // atomically so a main-loop reader cannot observe a torn vector.
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE)
    memcpy(p, ex.position, sizeof(ex.position));
}


float exec_get_axis_position(int axis) {
  float p;
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) p = ex.position[axis];
  return p;
}


void exec_set_velocity(float v) {
  ex.velocity = v;
  if (ex.peak_vel < v) ex.peak_vel = v;
}


float exec_get_velocity() {
  // AVR-12: single-float snapshot, taken atomically (see above)
  float v;
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) v = ex.velocity;
  return v;
}


void exec_set_acceleration(float a) {
  ex.accel = a;
  if (ex.peak_accel < a) ex.peak_accel = a;
}


float exec_get_acceleration() {
  float a;
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) a = ex.accel;
  return a;
}
void exec_set_jerk(float j) {ex.jerk = j;}


void exec_set_cb(exec_cb_t cb) {
  // AVR-12: two-byte pointer written from main-loop and LO contexts;
  // store it atomically so the LO ISR never calls a torn pointer.
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) ex.cb = cb;
}


void exec_move_to_target(const float target[]) {
  ESTOP_ASSERT(isfinite(target[AXIS_X]) && isfinite(target[AXIS_Y]) &&
               isfinite(target[AXIS_Z]) && isfinite(target[AXIS_A]) &&
               isfinite(target[AXIS_B]) && isfinite(target[AXIS_C]),
               STAT_BAD_FLOAT);

  // Prep power updates
  st_prep_power(ex.seg.power_updates);

  // Shift power updates
  for (unsigned i = 0; i < POWER_MAX_UPDATES; i++) {
    ex.seg.power_updates[i] = ex.seg.power_updates[i + POWER_MAX_UPDATES];
    ex.seg.power_updates[i + POWER_MAX_UPDATES].state = POWER_IGNORE;
  }

  // Update position
  copy_vector(ex.position, target);

  // Call the stepper prep function
  st_prep_line(target);
}


stat_t _segment_exec() {
  float t = ex.seg.time;
  float v = ex.seg.vel;
  float a = ex.seg.accel;

  // Handle pause
  if (state_get() == STATE_STOPPING) {
    a = SCurve::nextAccel(SEGMENT_TIME, 0, ex.velocity, ex.accel,
                          ex.seg.max_accel, ex.seg.max_jerk);
    v = ex.velocity + SEGMENT_TIME * a;

    // AVR-16: take the stopped path *before* dividing by v; v crosses
    // zero during deceleration and float division by zero here produced
    // inf/NaN segment times exactly while the operator was stopping.
    if (v < MIN_VELOCITY || seek_switch_found()) {
      t = v = 0;
      ex.seg.cb = 0;
      command_reset_position();
      state_holding();
      seek_end();
      spindle_update_speed();

    } else t *= ex.seg.vel / v;
  }

  // Wait for next seg if time is too short and we are still moving
  if (t < SEGMENT_TIME && (!t || v)) {
    if (!v) {
      exec_set_velocity(0);
      exec_set_acceleration(0);
      exec_set_jerk(0);
      ex.seg.time = 0;
    }
    ex.cb = ex.seg.cb;
    return STAT_AGAIN;
  }

  // Update velocity and accel
  exec_set_velocity(v);
  exec_set_acceleration(a);

  if (t <= SEGMENT_TIME) {
    // Move
    exec_move_to_target(ex.seg.target);
    ex.seg.time = 0;

  } else {
    // Compute next target
    float ratio = SEGMENT_TIME / t;
    float target[AXES];
    for (int axis = 0; axis < AXES; axis++) {
      float diff = ex.seg.target[axis] - ex.position[axis];
      target[axis] = ex.position[axis] + ratio * diff;
    }

    // Move
    exec_move_to_target(target);

    // Update time
    if (t == ex.seg.time) ex.seg.time -= SEGMENT_TIME;
    // AVR-16: ex.seg.vel can be 0 (zero-velocity segment); dividing by
    // it made ex.seg.time NaN and the segment bookkeeping never
    // converged.  With no segment velocity there is no scaling to do.
    else if (ex.seg.vel) ex.seg.time -= SEGMENT_TIME * v / ex.seg.vel;
    else ex.seg.time -= SEGMENT_TIME;
  }

  // Check switch
  if (seek_switch_found()) state_seek_hold();

  return STAT_OK;
}


stat_t exec_segment(float time, const float target[], float vel, float accel,
                    float maxAccel, float maxJerk,
                    const power_update_t power_updates[]) {
  // Copy power updates in to the correct position given the time offset
  float nextT = ex.seg.time + time;
  const float stepT = 1.0 / 60000; // 1ms in mins
  float t = 0.5 / 60000; // 0.5ms in mins
  unsigned j = 0;
  // AVR-6: i is the write index, so it must be bounded by the array size
  // (2 * POWER_MAX_UPDATES), not just by j.  A larger than expected
  // residual segment time otherwise writes past power_updates[] into
  // ex.seg.cb and the following exec state.
  for (unsigned i = 0; t < nextT && j < POWER_MAX_UPDATES &&
         i < 2 * POWER_MAX_UPDATES; i++) {
    if (ex.seg.time < t) ex.seg.power_updates[i] = power_updates[j++];
    t += stepT;
  }

  // Power updates remain that could not be placed within the window:
  // the segment time is far outside what the planner should produce.
  if (j < POWER_MAX_UPDATES && t < nextT && ex.seg.time < t)
    estop_trigger(STAT_LONG_SEG_TIME);

  copy_vector(ex.seg.target, target);
  ex.seg.time = nextT;
  ex.seg.vel = vel;
  ex.seg.accel = accel;
  ex.seg.max_accel = maxAccel;
  ex.seg.max_jerk = maxJerk;
  ex.seg.cb = ex.cb;
  ex.cb = _segment_exec;

  // TODO To be precise, seek_end() should not be called until the current
  // segment has completed execution.
  if (!ex.seg.cb) seek_end(); // No callback when at line end

  return _segment_exec();
}


// Called by stepper.c from low-level interrupt
stat_t exec_next() {
  // Hold if we've reached zero velocity between commands and stopping
  if (!ex.cb && !exec_get_velocity() && state_get() == STATE_STOPPING)
    state_holding();

  if (state_get() == STATE_HOLDING) return STAT_NOP;
  if (!ex.cb && !command_exec()) return STAT_NOP; // Queue empty
  if (!ex.cb) return STAT_AGAIN; // Non-exec command

  // AVR-8: never start or continue a move while a non-seek limit switch
  // is already tripped, regardless of velocity.  Returning the status
  // lets the stepper ISR raise the estop.  Checked only when a move is
  // actually about to execute, so an idle machine parked on a switch
  // can still receive commands (e.g. a seek, whose switch is excluded).
  if (_limit_switch_active()) return STAT_ESTOP_SWITCH;

  return ex.cb(); // Exec
}


// Variable callbacks
float get_axis_position(int axis) {return exec_get_axis_position(axis);}
float get_velocity() {return exec_get_velocity() / VELOCITY_MULTIPLIER;}
float get_acceleration() {
  return exec_get_acceleration() / ACCEL_MULTIPLIER;
}
float get_jerk() {
  float j;
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) j = ex.jerk;
  return j / JERK_MULTIPLIER;
}
float get_peak_vel() {
  float v;
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) v = ex.peak_vel;
  return v / VELOCITY_MULTIPLIER;
}
void set_peak_vel(float x) {ex.peak_vel = 0;}
float get_peak_accel() {
  float a;
  ATOMIC_BLOCK(ATOMIC_RESTORESTATE) a = ex.peak_accel;
  return a / ACCEL_MULTIPLIER;
}
void set_peak_accel(float x) {ex.peak_accel = 0;}
uint16_t get_feed_override() {return ex.feed_override * 1000;}
void set_feed_override(uint16_t value) {ex.feed_override = value / 1000.0;}


// Command callbacks
typedef struct {
  uint8_t axis;
  float position;
} set_axis_t;


stat_t command_set_axis(char *cmd) {
  cmd++; // Skip command name

  // Decode axis
  int axis = axis_get_id(*cmd++);
  // AVR-2: axis_get_id() returns 6..8 for U/V/W, but there are only AXES
  // axes.  Accepting them writes past cmd.position[]/ex.position[].
  if (axis < 0 || AXES <= axis) return STAT_INVALID_ARGUMENTS;

  // Decode position
  float position;
  if (!decode_float(&cmd, &position)) return STAT_BAD_FLOAT;

  // Check for end of command
  if (*cmd) return STAT_INVALID_ARGUMENTS;

  // Update command
  command_set_axis_position((uint8_t)axis, position);

  // Queue
  set_axis_t set_axis = {(uint8_t)axis, position};
  command_push(COMMAND_set_axis, &set_axis);

  return STAT_OK;
}


unsigned command_set_axis_size() {return sizeof(set_axis_t);}


void command_set_axis_exec(void *data) {
  set_axis_t *cmd = (set_axis_t *)data;

  // AVR-2: defence in depth, in case a queued command was crafted by
  // another path than command_set_axis().
  if (AXES <= cmd->axis) return;

  // Update exec
  ex.position[cmd->axis] = cmd->position;

  // Update motors
  for (int motor = 0; motor < MOTORS; motor++)
    if (motor_get_axis(motor) == cmd->axis)
      motor_set_position(motor, cmd->position);
}
