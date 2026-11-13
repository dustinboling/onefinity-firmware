# Focused tests for the 2026 audit fixes (findings/python.md):
# P-01 admin gate presence, P-02 diagnostics handler removal, P-03
# firmware package validation presence, P-06 atomic/locked Config,
# P-07 checkpoint writer race, P-17 config value conversion,
# P-18 plug address validation.
#   python3 src/py/tests/test_audit_fixes.py
import os, sys, json, time, threading, tempfile, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
BBCTRL = os.path.join(HERE, '..', 'bbctrl')

ok = True
def check(name, cond, msg=''):
    global ok; print(('PASS ' if cond else 'FAIL ') + name, msg); ok &= bool(cond)

def load(mod, filename):
    spec = importlib.util.spec_from_file_location(mod, os.path.join(BBCTRL, filename))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m

class Log:
    def get(self, name=None): return self
    def info(self, *a, **k): pass
    def warning(self, *a, **k): pass
    def error(self, *a, **k): pass
    def exception(self, *a, **k): pass

# ---------------------------------------------------------------- P-18
Plugs = load('Plugs', 'Plugs.py')
for good in ('192.168.4.173', '10.0.0.9', 'shelly.local', 'plug1', 'a-b.lan'):
    check('P-18 accepts %r' % good, Plugs.valid_plug_host(good))
for bad in ('', '1.2.3.4/rpc', 'a?b=1', 'a@b', 'a:8080', 'a/b', 'a..b',
            '-bad', 'bad-', 'a b', 'http://x', '999.1.1.1/'):
    check('P-18 rejects %r' % bad, not Plugs.valid_plug_host(bad))

# ---------------------------------------------------------------- P-06/P-17
Config = load('Config', 'Config.py')

tmp = tempfile.mkdtemp()
class Preplanner:
    def invalidate_all(self): pass
class Ctrl:
    def __init__(s):
        s.log = Log(); s.preplanner = Preplanner()
    def get_path(s, name=None):
        return os.path.join(tmp, name) if name else tmp

ctrl = Ctrl()
cfg = Config.Config.__new__(Config.Config)
cfg.ctrl = ctrl; cfg.log = Log(); cfg.values = {}
cfg._lock = threading.RLock(); cfg._loaded = None
cfg.version = '1.38.0'; cfg.template = {}

cfg.save({'version': '1.38.0', 'settings': {'a': 1}})
path = os.path.join(tmp, 'config.json')
check('P-06 save writes config.json', os.path.isfile(path))
check('P-06 no .tmp left behind', not os.path.exists(path + '.tmp'))
with open(path) as f: saved = json.load(f)
check('P-06 saved content round-trips', saved.get('settings', {}).get('a') == 1)

cfg.save({'settings': {'b': 2}})   # no 'version' key at all
with open(path) as f: saved = json.load(f)
check('P-17 save without version does not crash',
      saved.get('version') == '1.38.0' and saved['settings'].get('b') == 2)

okv, v = cfg._convert_value({'type': 'bool'}, 'false')
check('P-17 bool string false converts to False', okv and v is False)
okv, v = cfg._convert_value({'type': 'float'}, '2.5')
check('P-17 float string converts to float', okv and v == 2.5)
okv, v = cfg._convert_value({'type': 'int'}, 'not-a-number')
check('P-17 bad int rejected', not okv)

conf = {'n': '50'}
tmpl = {'n': {'type': 'int', 'default': 1, 'min': 0, 'max': 10}}
# __defaults is name-mangled; call it through the class
cfg._Config__defaults(conf, 'n', tmpl['n'])
check('P-17 string number stored converted and clamped', conf['n'] == 10)

# Concurrent set() calls must not drop each other's keys
cfg._loaded = {'version': '1.38.0'}
def setter(k):
    for i in range(10): cfg.set('key%d' % k, i)
threads = [threading.Thread(target=setter, args=(k,)) for k in range(4)]
[t.start() for t in threads]; [t.join() for t in threads]
with open(path) as f: saved = json.load(f)
check('P-06 concurrent set() keeps every key',
      all(('key%d' % k) in saved for k in range(4)))

# ---------------------------------------------------------------- P-07
Checkpoint = load('Checkpoint', 'Checkpoint.py')
cpdir = tempfile.mkdtemp()
class State:
    def add_listener(self, f): pass
    def get(self, k, d=None): return d
class CCtrl:
    def __init__(s):
        s.log = Log(); s.state = State()
    def get_path(s, name=None):
        return os.path.join(cpdir, name) if name else cpdir
    def get_upload(s, name=None): return os.path.join(cpdir, name or '')

cp = Checkpoint.Checkpoint(CCtrl())
N = 60
def enqueue_many(n):
    for i in range(n):
        with cp.lock: cp.seq += 1; seq = cp.seq
        cp._enqueue({'v': 1, 'seq': seq, 'status': 'running'})
threads = [threading.Thread(target=enqueue_many, args=(N,)) for _ in range(4)]
[t.start() for t in threads]; [t.join() for t in threads]
deadline = time.time() + 10
while time.time() < deadline and (cp.writing or cp.latest is not None):
    time.sleep(0.02)
best = cp._read_best()
check('P-07 writer drains and stops', not cp.writing and cp.latest is None)
check('P-07 newest record was persisted, not stranded',
      best is not None and best.get('seq') == cp.seq,
      'best=%r seq=%r' % (best and best.get('seq'), cp.seq))

cp.current = {'v': 1, 'seq': cp.seq, 'status': 'running'}
cp.mark('parked')
deadline = time.time() + 10
while time.time() < deadline and (cp.writing or cp.latest is not None):
    time.sleep(0.02)
best = cp._read_best()
check('P-07 mark() persists through the same path',
      best is not None and best.get('status') == 'parked')

# ------------------------------------------------- P-01 / P-02 / P-03 (source)
web = open(os.path.join(BBCTRL, 'Web.py')).read()
rh = open(os.path.join(BBCTRL, 'RequestHandler.py')).read()
fh = open(os.path.join(BBCTRL, 'FileHandler.py')).read()
check('P-02 diagnostics handler class gone',
      'class RemoteDiagnosticsHandler' not in web)
check('P-02 diagnostics route gone', 'remote-diagnostics' not in web)
check('P-02 no urlopen left in Web.py', 'urlopen' not in web)
check('P-01 admin gate implemented in RequestHandler',
      'verify_os_password' in rh and 'ADMIN_ONLY' in rh and
      'X-Admin-Password' in rh)
check('P-01 admin subset marked in Web.py', web.count('ADMIN_ONLY = True') >= 10,
      'count=%d' % web.count('ADMIN_ONLY = True'))
check('P-01 file delete gated', "ADMIN_METHODS = ('DELETE',)" in fh)
check('P-03 package validator present',
      '_validate_package' in web and 'scripts/install.sh' in web
      and 'sha256' in web)

print('ALL PASS' if ok else 'SOME FAILED'); sys.exit(0 if ok else 1)
