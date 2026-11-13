################################################################################
#                                                                              #
#                This file is part of the Buildbotics firmware.                #
#                                                                              #
#                  Copyright (c) 2015 - 2018, Buildbotics LLC                  #
#                             All rights reserved.                             #
#                                                                              #
#     This file ("the software") is free software: you can redistribute it     #
#     and/or modify it under the terms of the GNU General Public License,      #
#      version 2 as published by the Free Software Foundation. You should      #
#      have received a copy of the GNU General Public License, version 2       #
#     along with the software. If not, see <http://www.gnu.org/licenses/>.     #
#                                                                              #
#     The software is distributed in the hope that it will be useful, but      #
#          WITHOUT ANY WARRANTY; without even the implied warranty of          #
#      MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU       #
#               Lesser General Public License for more details.                #
#                                                                              #
#       You should have received a copy of the GNU Lesser General Public       #
#                License along with the software.  If not, see                 #
#                       <http://www.gnu.org/licenses/>.                        #
#                                                                              #
#                For information regarding this software email:                #
#                  "Joseph Coffland" <joseph@buildbotics.com>                  #
#                                                                              #
################################################################################

import os
import json
import threading
import pkg_resources
from pkg_resources import Requirement, resource_filename


def get_resource(path):
    return resource_filename(Requirement.parse('bbctrl'), 'bbctrl/' + path)


# Settings that only list files, not how a program is planned
FILE_LIST_KEYS = ('gcode_list', 'non_macros_list', 'macros_list')

def plans_same(old, new):
    if not isinstance(old, dict) or not isinstance(new, dict): return False
    strip = lambda c: {k: v for k, v in c.items() if k not in FILE_LIST_KEYS}
    return strip(old) == strip(new)


class Config(object):
    def __init__(self, ctrl):
        self.ctrl = ctrl
        self.log = ctrl.log.get('Config')

        self.values = {}
        # P-06: one lock serialises every read-modify-write of
        # config.json, and _loaded caches the last loaded/saved config
        # so set() mutates memory instead of re-reading the file.
        self._lock = threading.RLock()
        self._loaded = None

        try:
            self.version = "1.38.0"

            # Load config template
            with open(get_resource('http/config-template.json'), 'r',
                      encoding = 'utf-8') as f:
                self.template = json.load(f)

        except Exception: self.log.exception('Internal error: Failed to load config template')

    def load(self):
        path = self.ctrl.get_path('config.json')

        try:
            if os.path.exists(path):
                with open(path, 'r') as f: config = json.load(f)
            else: config = {'version': self.version}

            try:
                self._upgrade(config)
            except Exception: self.log.exception('Internal error: Failed to upgrade config')

        except Exception as e:
            self.log.warning('%s', e)
            config = {'version': self.version}

        self._defaults(config)
        self._loaded = config
        return config


    def reload(self):
        self._update(self.load(), True)


    def get(self, name, default = None):
        return self.values.get(name, default)
    
    def set(self, name, default = None):
        path = self.ctrl.get_path('config.json')

        try:
            with self._lock:
                # P-06: mutate the in-memory config under the lock; the
                # old code re-read the file unlocked, so two set() calls
                # could interleave and drop each other's change.
                if self._loaded is not None: config_data = self._loaded
                elif os.path.exists(path):
                    with open(path, 'r') as f: config_data = json.load(f)
                else: config_data = {'version': self.version}

                self._set_locked(config_data, name, default)
        except Exception: self.log.exception('Internal error: Failed to upgrade config')


    def _set_locked(self, config_data, name, default):
            if name in config_data:
                existing_value = config_data[name]
                if isinstance(existing_value, dict) and isinstance(default, dict):
                    config_data[name] = {**existing_value, **default}
                    # existing_value.update(default)
                elif isinstance(existing_value, list) and isinstance(default, list):
                    config_data[name].extend(default)
                elif isinstance(existing_value, list):
                    config_data[name].append(default)
                else:
                    config_data[name] = default
            else:
                config_data[name] = default

            self.save(config_data)

    def save(self, config):
        with self._lock:
            self._save_locked(config)


    def _save_locked(self, config):
        # P-17: save() used to call _upgrade unwrapped, so a config
        # without a usable 'version' (hand-edited, older, restored)
        # crashed the save with KeyError.  _upgrade now tolerates it.
        try:
            self._upgrade(config)
        except Exception:
            self.log.exception('Internal error: Failed to upgrade config')
            config['version'] = self.version.split('b')[0]
            config['full_version'] = self.version
        self._update(config, False)

        path = self.ctrl.get_path('config.json')
        try:
            with open(path, 'r') as f: old = json.load(f)
        except Exception: old = None

        # P-06: write atomically — tmp file, fsync, os.replace, fsync
        # the directory (the NextStoreHandler/Work.FileCache pattern).
        # The old in-place truncate-and-dump left a torn config.json
        # behind whenever power went mid-write, silently reverting the
        # machine to template defaults on the next boot.
        tmp = path + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(config, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        try:
            dfd = os.open(os.path.dirname(path) or '.', os.O_RDONLY)
            try: os.fsync(dfd)
            finally: os.close(dfd)
        except OSError: pass

        self._loaded = config

        # The Files tab saves its folder lists right after every upload. Those
        # lists don't change any plan, so keep the plans (1.31.3): dropping
        # them restarted the new program's preview for nothing.
        if not plans_same(old, config):
            self.ctrl.preplanner.invalidate_all()
        self.log.info('Saved')


    def reset(self):
        with self._lock:
            if os.path.exists('config.json'): os.unlink('config.json')
            self._loaded = None
            self.reload()
            self.ctrl.preplanner.invalidate_all()


    def _convert_value(self, template, value):
        '''P-17: return (True, converted value) or (False, None).  The
        old _valid_value converted only a local copy, so the stored
        value kept its original type — a string 'false' stayed truthy,
        and a string number later crashed the min/max comparison with
        int < str.'''
        type = template['type']

        try:
            if type == 'int':   value = int(value)
            if type == 'float': value = float(value)
            if type == 'text':  value = str(value)
            if type == 'bool':
                if isinstance(value, str):
                    value = value.strip().lower() in ('true', '1', 'yes', 'on')
                else: value = bool(value)
        except Exception:
            return False, None

        if 'values' in template and value not in template['values']:
            return False, None

        return True, value


    def _valid_value(self, template, value):
        return self._convert_value(template, value)[0]


    def __defaults(self, config, name, template):
        if 'type' in template:
            ok, converted = (False, None)
            if name in config:
                ok, converted = self._convert_value(template, config[name])

            if not ok:
                config[name] = template['default']

            else:
                # Store the converted value, then clamp it (both are
                # now the template's type, so the comparison is safe).
                config[name] = converted

                if 'max' in template and template['max'] < config[name]:
                    config[name] = template['max']

                elif 'min' in template and config[name] < template['min']:
                    config[name] = template['min']

            if template['type'] == 'list':
                if 'index' in template:
                    config = config[name]

                    for i in range(len(template['index'])):
                        if len(config) <= i: config.append({})

                        for name, tmpl in template['template'].items():
                            self.__defaults(config[i], name, tmpl)

        else:
            for name, tmpl in template.items():
                self.__defaults(config, name, tmpl)


    def _defaults(self, config):
        for name, tmpl in self.template.items():
            if not 'type' in tmpl:
                if not name in config: config[name] = {}
                conf = config[name]
            else: conf = config

            self.__defaults(conf, name, tmpl)


    def _upgrade(self, config):
        # P-17: a missing or unparsable version means "treat as
        # current", not KeyError/ValueError out of save()/load().
        raw = config.get('version') or self.version
        try:
            version = str(raw).split('b')[0] # Strip off any "beta" suffix
            version = version.split('-')[0]
            version = tuple(map(int, version.split('.'))) # Break it into a tuple of integers
        except Exception:
            version = tuple(map(int, self.version.split('.')))

        # The old-version blocks below index these blindly.
        for key in ('settings', 'probe'):
            if not isinstance(config.get(key), dict): config[key] = {}
        if not isinstance(config.get('motors'), list): config['motors'] = []

        if version < (1, 0, 7):
            config['settings']['max-deviation'] = 0.001
            config['settings']['junction-accel'] = 200000
            config['settings']['probing-prompts'] = True
            config['probe']['probe-fast-seek'] = 75
            config['probe']['probe-slow-seek'] = 25
            for motor in config['motors']:
                motor['stall-microstep'] = 8
                motor['stall-current'] = 1
                motor['idle-current'] = 1
                motor['max-accel'] = 750
                motor['latch-backoff'] = 5
                if motor['axis'] == 'X' or motor['axis'] == 'Y':
                    motor['search-velocity'] = 1.688
                    motor['max-velocity'] = 10
                    motor['max-jerk'] = 1000
                    motor['zero-backoff'] = 1.5
                if motor['axis'] == 'Z':
                    motor['search-velocity'] = 0.675
                    motor['max-velocity'] = 3
                    motor['max-jerk'] = 1000
                    motor['zero-backoff'] = 1

        if version < (1, 0, 8):
            config['settings']['max-deviation'] = 0.05
            config['settings']['junction-accel'] = 200000

        if version < (1, 0, 9):
            with open(get_resource('http/onefinity_defaults.json'), 'r', encoding = 'utf-8') as f:
                defaults = json.load(f)
                config['selected-tool-settings'] = defaults['selected-tool-settings'];

        config['version'] = self.version.split('b')[0]
        config['full_version'] = self.version


    def _encode(self, name, index, config, tmpl, with_defaults):
        # Handle category
        if not 'type' in tmpl:
            for name, entry in tmpl.items():
                if 'type' in entry and config is not None:
                    conf = config.get(name, None)
                else: conf = config
                self._encode(name, index, conf, entry, with_defaults)
            return

        # Handle defaults
        if config is not None: value = config
        elif with_defaults: value = tmpl['default']
        else: return

        # Handle list
        if tmpl['type'] == 'list':
            if 'index' in tmpl:
                for i in range(len(tmpl['index'])):
                    if config is not None and i < len(config): conf = config[i]
                    else: conf = None
                    self._encode(name, index + tmpl['index'][i], conf,
                                tmpl['template'], with_defaults)
            else:
                self.values[name]=value
                self.ctrl.state.config(name,value)
            return

        # Update config values
        if index:
            if not name in self.values: self.values[name] = {}
            self.values[name][index] = value

        else: self.values[name] = value

        # Update state variable
        if not 'code' in tmpl: return

        if tmpl['type'] == 'enum':
            if value in tmpl['values']: value = tmpl['values'].index(value)
            else: value = tmpl['default']

        elif tmpl['type'] == 'bool': value = 1 if value else 0
        elif tmpl['type'] == 'percent': value /= 100.0

        self.ctrl.state.config(index + tmpl['code'], value)


    def _update(self, config, with_defaults):
        for name, tmpl in self.template.items():
            conf = config.get(name, None)
            self._encode(name, '', conf, tmpl, with_defaults)
