import os
import shutil
import tempfile
import bbctrl
import glob
import tornado
from tornado import gen
from tornado.web import HTTPError
from tornado.escape import url_unescape


def safe_remove(path):
    try:
        os.unlink(path)
    except OSError:
        pass


@tornado.web.stream_request_body
class FileHandler(bbctrl.APIHandler):
    # P-01: deleting programs is an admin operation; uploading and
    # downloading them is normal machine use and stays open on the LAN.
    ADMIN_ONLY = True
    ADMIN_METHODS = ('DELETE',)

    # P-11: uploads were accepted up to 1 GiB with no disk-space or
    # size check, on an SD card shared with plans, logs and
    # checkpoints.  Real G-code is tens of MB at most.
    MAX_UPLOAD_BYTES = 100 * 2 ** 20
    MIN_FREE_AFTER = 64 * 2 ** 20

    def prepare(self):
        # Not APIHandler.prepare: an upload body is not JSON.  Run only
        # the base admin gate (P-01).
        bbctrl.RequestHandler.prepare(self)
        if self.request.method == 'PUT':
            self.request.connection.set_max_body_size(
                self.MAX_UPLOAD_BYTES + 2 ** 20)

            # Refuse before spooling if the card could not hold the
            # largest allowed upload and still keep a working reserve.
            try:
                free = shutil.disk_usage(
                    self.get_upload() if os.path.exists(self.get_upload())
                    else '.').free
            except OSError:
                free = None
            if free is not None and free < self.MAX_UPLOAD_BYTES + self.MIN_FREE_AFTER:
                raise HTTPError(507, 'Not enough free space on the controller')

            filename = self.request.path.split('/')[-1]
            self.uploadFilename = url_unescape(filename) \
                .encode("ascii", errors="replace") \
                .decode() \
                .replace('\\', '_') \
                .replace('/', '_') \
                .replace('#', '-') \
                .replace('?', '-')

            self.uploadFile = tempfile.NamedTemporaryFile("wb")
            self._upload_bytes = 0

    def data_received(self, data):
        if self.request.method == 'PUT':
            self._upload_bytes += len(data)
            if self._upload_bytes > self.MAX_UPLOAD_BYTES:
                # Abort the stream and drop the spooled temp file
                # (on_finish also cleans up if this is bypassed).
                try:
                    name = self.uploadFile.name
                    self.uploadFile.close()
                    os.unlink(name)
                except Exception: pass
                del self.uploadFile
                raise HTTPError(413, 'Program is too large (max %d MB)' %
                                (self.MAX_UPLOAD_BYTES // 2 ** 20))
            self.uploadFile.write(data)


    def on_finish(self):
        # P-11: an exception between prepare() and put_ok() used to
        # orphan the spooled temp file on the SD card.
        f = getattr(self, 'uploadFile', None)
        if f is not None:
            try:
                f.close()
                os.unlink(f.name)
            except Exception: pass
            del self.uploadFile

    def delete_ok(self, filename):
        allFiles = self.get_ctrl().state.return_files()

        if filename.startswith('/EgZjaHJvbWUqCggBEAAYsQMYgAQyBggAEEUYOTIKCAE'):
            exceptionList=filename.replace('/EgZjaHJvbWUqCggBEAAYsQMYgAQyBggAEEUYOTIKCAE','').split(',')

            for filename in [item for item in allFiles if item not in exceptionList]:
                filename = os.path.basename(filename)
                safe_remove(self.get_upload(filename))
                self.get_ctrl().preplanner.delete_plans(filename)
                self.get_ctrl().state.remove_file(filename)
        
        elif filename.startswith('/DINCAIQABiDARixAxiABDIHCAMQABiABDIHCAQQABiABDIH'):
            deletionList=filename.replace('/DINCAIQABiDARixAxiABDIHCAMQABiABDIHCAQQABiABDIH','').split(',')
            
            for filename in [item for item in allFiles if item in deletionList]:
                filename = os.path.basename(filename)
                safe_remove(self.get_upload(filename))
                self.get_ctrl().preplanner.delete_plans(filename)
                self.get_ctrl().state.remove_file(filename)


        elif not filename:
            # Delete everything
            for path in glob.glob(self.get_upload('*')):
                self.get_log('FileHandler').info('path ' + path)
                safe_remove(path)
            self.get_ctrl().preplanner.delete_all_plans()
            self.get_ctrl().state.clear_files()

        else:
            # Delete a single file
            filename = os.path.basename(filename)
            safe_remove(self.get_upload(filename))
            self.get_ctrl().preplanner.delete_plans(filename)
            self.get_ctrl().state.remove_file(filename)

    def put_ok(self, *args):
        if not os.path.exists(self.get_upload()):
            os.mkdir(self.get_upload())

        if self.uploadFilename.startswith('EgZjaHJvbWUqCggBEAAYsQMYgAQyBggAEEUYOTIKCAE'):#macros
            self.uploadFilename=self.uploadFilename.replace('EgZjaHJvbWUqCggBEAAYsQMYgAQyBggAEEUYOTIKCAE','')
            filename = self.get_upload(self.uploadFilename).encode('utf8')
            safe_remove(filename)
            os.link(self.uploadFile.name, filename)

            self.uploadFile.close()

            del (self.uploadFile)

            self.get_ctrl().preplanner.invalidate(self.uploadFilename)
            self.get_ctrl().state.add_file('EgZjaHJvbWUqCggBEAAYsQMYgAQyBggAEEUYOTIKCAE'+self.uploadFilename)

        else:
            filename = self.get_upload(self.uploadFilename).encode('utf8')
            safe_remove(filename)
            os.link(self.uploadFile.name, filename)

            self.uploadFile.close()

            del (self.uploadFile)

            self.get_ctrl().preplanner.invalidate(self.uploadFilename)
            self.get_ctrl().state.add_file(self.uploadFilename)

            # Start the G-code check now, in the worker process (1.31.2), so
            # it is ready (or under way) when a screen asks.  In the
            # background (1.31.4): a screen's own work goes first.
            try:
                path = self.get_upload(self.uploadFilename)
                bbctrl.Lint.lint_file_async(path, background = True)
                # and the quick dry run's copy (1.33.0), so Dry run starts at once
                bbctrl.DryRun.prepare_async(path, background = True)
            except Exception as e:
                self.get_log('FileHandler').warning('G-code check not started: %s' % e)

        del (self.uploadFilename)

    @gen.coroutine
    def get(self, filename):
        filebasename=filename
        if not filename:
            raise HTTPError(400, 'Missing filename')
        if filename.startswith('/EgZjaHJvbWUqCggBEAAYsQMYgAQyBggAEEUYOTIKCAE'):
            filebasename = os.path.basename(url_unescape(filename.replace("EgZjaHJvbWUqCggBEAAYsQMYgAQyBggAEEUYOTIKCAE", "")))
        else:
            filebasename = os.path.basename(url_unescape(filename))
        
        try:
            # P-09: stream the program out in chunks instead of reading
            # it whole into RAM on the IOLoop.
            with open(self.get_upload(filebasename).encode('utf8'), 'rb') as f:
                while True:
                    chunk = f.read(1024 * 64)
                    if not chunk: break
                    self.write(chunk)
                    yield self.flush()
        except Exception:
            self.get_ctrl().state.select_file('')
            raise HTTPError(
                400, "Unable to read file - doesn't appear to be GCode.")
        if not filename.startswith('/EgZjaHJvbWUqCggBEAAYsQMYgAQyBggAEEUYOTIKCAE'):
            self.get_ctrl().state.select_file(filebasename)
