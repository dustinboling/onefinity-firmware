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

import subprocess
import traceback
import bbctrl

from tornado.web import HTTPError
import tornado.web


# P-01 — authentication design decision.
#
# This controller is a local-network appliance whose interface has, by
# product design, always been open to anyone on the LAN: the operator's
# screens (including the on-device touchscreen) jog, home and run the
# machine without logging in, and changing that wholesale would break
# every existing screen and pendant.  The audit's minimum acceptable
# step is therefore what is implemented here: the destructive / admin
# subset of the API is gated behind the controller's existing OS
# password, while normal machine operation stays open on the LAN.
#
# A handler joins the gated subset by setting ADMIN_ONLY = True (and,
# if only some of its methods are admin, ADMIN_METHODS).  Gated
# requests must either
#   * come from the device itself (loopback) — the touchscreen is
#     physical presence at the machine, which is the authorisation, or
#   * carry the OS password in the X-Admin-Password header, verified
#     against /etc/shadow exactly as Web.check_password does.
# A custom header (not a cookie) is used, so no session state is added
# and cross-site request forgery cannot trigger a gated endpoint: a
# malicious page cannot set custom headers without a CORS preflight,
# and this server enables no CORS.  Full authentication of the whole
# API remains the recommended long-term direction; it needs the web UI
# to grow a login flow first, which is outside this change.

def _shadow_entry():
    out = subprocess.check_output(['getent', 'shadow', _username()])
    return out.decode('utf-8').strip().split(':')


def _username():
    out = subprocess.check_output(['getent', 'passwd', '1001'])
    return out.decode('utf-8').split(':')[0]


def verify_os_password(password):
    '''True if `password` matches the controller OS user's password.
    Mirrors Web.check_password (MD5-crypt in /etc/shadow).'''
    try:
        if not password: return False
        current = _shadow_entry()[1].split('$')
        if len(current) < 2 or current[1] != '1': return False
        cmd = ['openssl', 'passwd', '-salt', current[2], '-1', password]
        out = subprocess.check_output(cmd).decode('utf-8').strip()
        return out.split('$') == current
    except Exception:
        return False


class RequestHandler(tornado.web.RequestHandler):
    # P-01: see the design note above.  Subclasses opt in per class.
    ADMIN_ONLY = False
    ADMIN_METHODS = ('PUT', 'POST', 'DELETE')

    def __init__(self, app, request, **kwargs):
        super().__init__(app, request, **kwargs)
        self.app = app


    def prepare(self):
        if not self.ADMIN_ONLY: return
        if self.request.method not in self.ADMIN_METHODS: return
        if self.request.remote_ip in ('127.0.0.1', '::1'): return
        if verify_os_password(self.request.headers.get(
                'X-Admin-Password', '')): return
        raise HTTPError(401, 'Admin password required for this operation')


    def get_ctrl(self): return self.app.get_ctrl(self.get_cookie('client-id'))
    def get_log(self, name = 'API'): return self.get_ctrl().log.get(name)


    def get_path(self, path = None, filename = None):
        return self.get_ctrl().get_path(path, filename)


    def get_upload(self, filename = None):
        return self.get_ctrl().get_upload(filename)


    # Override exception logging
    def log_exception(self, typ, value, tb):
        if (isinstance(value, HTTPError) and
            400 <= value.status_code and value.status_code < 500): return

        log = self.get_log()
        # P-22: this used to permanently raise the API logger to DEBUG
        # on any 500 (compounding the P-10 hot-path logging cost) and
        # never restore it.  Log at the existing level.
        log.error(str(value))
        trace = ''.join(traceback.format_exception(typ, value, tb))
        log.error(trace)
