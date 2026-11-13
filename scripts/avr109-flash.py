#!/usr/bin/env python3

import sys
import time
import serial
import binascii


dev = '/dev/ttyAMA0'
baud = 921600
boot_id = 'bbctrl '
verbose = False


def crc16(data):
    crc = 0xffff

    for x in data:
        crc = crc ^ int(x)
        for bit in range(8):
            if crc & 1: crc = (crc >> 1) ^ 0xa001
            else: crc = crc >> 1

    return crc


def avr_crc32(data, length):
    mem = [0xff] * length

    for addr, chunk in data:
        for x in chunk:
            mem[addr] = x
            addr += 1

    return binascii.crc32(bytes(mem))


def read_intel_hex(f):
    base = 0
    pos = 0
    start = 0
    chunk = None

    for lineno, line in enumerate(f, 1):
        line = line.strip()
        if not line or line[0] != ':': continue

        # Validate the record before trusting any of it (Scripts-8):
        # the record must be well-formed hex, its byte count must
        # match its length, and its checksum -- the two's complement
        # of the sum of all preceding bytes in the record -- must
        # verify, so the sum of the whole record is zero mod 256.
        try:
            raw = binascii.unhexlify(bytes(line[1:], 'utf8'))
        except Exception:
            raise ValueError('line %d: not valid hex' % lineno)

        if len(raw) < 5:
            raise ValueError('line %d: record too short' % lineno)

        count = raw[0]
        addr = (raw[1] << 8) | raw[2]
        type = raw[3]
        data = raw[4:4 + count]
        checksum = raw[4 + count] if len(raw) > 4 + count else None

        if len(raw) != count + 5:
            raise ValueError(
                'line %d: byte count %d does not match record length %d'
                % (lineno, count, len(raw) - 5))
        if sum(raw) & 0xff != 0:
            raise ValueError('line %d: checksum mismatch' % lineno)

        if type == 0:
            addr += base

            if chunk is None or pos != addr:
                if chunk is not None: yield (start, chunk)
                start = addr
                chunk = data

            else: chunk += data

            pos = addr + len(data)

        elif type == 1: # End of file
            break

        elif type == 2: # Extended segment address
            base = int.from_bytes(data, 'big') * 16

        elif type == 4: # Extended linear address
            base = int.from_bytes(data, 'big') << 16

    if chunk is not None: yield (start, chunk)


def send(data):
    if verbose: print('Sending:', data)
    sp.write(bytes(data, 'utf8'))


def send_int(x, size):
    if verbose: print('Sending: %d', x)
    sp.write((x).to_bytes(size, byteorder = 'big'))


def recv(count):
    data = sp.read(count).decode('utf8')
    if count and verbose: print('Received:', data)
    return data


def recv_int(size):
    x = int.from_bytes(sp.read(size), byteorder = 'big')
    if verbose: print('Received:', x)
    return x


if len(sys.argv) != 2:
    sys.exit('Usage: %s <firmware.hex>' % sys.argv[0])

# Read firmware hex file (record checksums are validated while
# reading; a corrupt image is rejected here, before the AVR is
# erased -- Scripts-8)
data = list(read_intel_hex(open(sys.argv[1], 'r')))
if not data: sys.exit('No data found in %s' % sys.argv[1])

# Open serial  port
sp = serial.Serial(dev, baud, timeout = 10)

# Reset AVR
import RPi.GPIO as gpio
gpio.setwarnings(False)
gpio.setmode(gpio.BCM)
gpio.setup(27, gpio.OUT)
gpio.output(27, 0)
gpio.output(27, 1)
gpio.setup(27, gpio.IN, pull_up_down = gpio.PUD_UP)
time.sleep(0.1)

# Sync
for i in range(10): send('\x1b')

# Flush serial
try:
    recv(sp.in_waiting)
except: pass

# Get bootloader ID
send('S')
if boot_id != recv(len(boot_id)):
    raise Exception('Failed to communicate with bootloader')

# Get version
send('V')
major = int(recv(1))
minor = int(recv(1))
print('Bootloader version: %d.%d' % (major, minor))

# If bootloader is new enough compare checksums
new_crc = None
if 0 < major or 1 < minor:
    # Get flash length
    send('n')
    flash_len = recv_int(3)

    # Get current flash CRC
    send('X')
    new_crc = avr_crc32(data, flash_len)
    old_crc = recv_int(4)
    if old_crc == new_crc:
        print('Flash already up to date')
        sys.exit(0)

    print('CRC: old=0x%08x new=0x%08x' % (old_crc, new_crc))

    # Erase
    send('e')
    if recv(1) != '\r': raise Exception('Flash erase failed')

# Get page size
send('b')
if recv(1) != 'Y': raise Exception('Cannot get page size')
page_size = recv_int(2)
print('Page size:', page_size)


# Program
print('Programming', end = '')
count = 0
retry = 0
for addr, chunk in data:
    # Set address
    send('H')
    send_int(addr, 3)
    if recv(1) != '\r': raise Exception('Failed to set address')

    while len(chunk):
        sys.stdout.flush()
        page = chunk[0:512]

        # Block command
        send('B')

        # Send block size
        send_int(len(page), 2)

        # Send memory type
        send('F')

        # Send block
        sp.write(page)

        if recv(1) != '\r': raise Exception('Failed to write block')

        # Get and check block CRC
        send('i')
        crc = recv_int(2)
        expect = crc16(page)
        if crc != expect:
            retry += 1
            if retry == 5:
                raise Exception('CRC mismatch %d != %d' % (crc, expect))

            print('x', end = '')
            continue

        count += len(page)
        chunk = chunk[512:]
        retry = 0
        print('.', end = '')


print('done')
print('Wrote %d bytes' % count)

# Verify the finished flash (Scripts-8): ask the bootloader for the
# CRC32 of the whole application section and compare it with the CRC
# of the image we intended to write.  The per-block CRCs above only
# prove the device received the bytes we sent; this proves the flash
# now contains the image.  Bootloaders too old to report a CRC were
# detected earlier (new_crc is None) and cannot be verified this way.
if new_crc is not None:
    send('X')
    verified_crc = recv_int(4)
    if verified_crc != new_crc:
        raise Exception(
            'Post-flash CRC mismatch: flash=0x%08x expected=0x%08x'
            % (verified_crc, new_crc))
    print('Flash verified: CRC32 0x%08x' % verified_crc)
else:
    print('WARNING: bootloader does not support CRC verification; '
          'flash was not verified')

# Exit bootloader
send('E')
