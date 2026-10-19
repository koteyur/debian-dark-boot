#!/usr/bin/python3 -I
"""Drive a running QEMU through its monitor and serial sockets.

Usage: vmctl.py SCRATCH SHOTDIR ACTION...
Actions:
  wait=SECONDS          sleep
  key=KEY               QEMU sendkey (ret, esc, down, ...)
  type=TEXT             type text with sendkey (letters, digits, space)
  shot=NAME             screenshot to SHOTDIR/NAME.png
  shothead=NAME:DEV:N   screenshot of head N of the display device DEV
  burst=NAME:SECS:STEP  screenshots every STEP seconds for SECS seconds
  login                 log in as root on the serial console
  run=COMMAND           run a shell command on the serial console, print output
  runt=SECS:COMMAND     the same, with a time limit of SECS seconds
  send=COMMAND          send a command on the serial console, do not wait
  waitfor=TEXT:SECS     wait until TEXT shows on the serial console
  waitpixel=X:Y:RRGGBB:SECS:NAME[:ROW]   wait until the screen pixel X,Y has
                        the color RRGGBB, then save that screen as NAME.
                        ROW is the real row width in pixels, for a skewed
                        screenshot (see unskew.py).
"""

import os
import socket
import subprocess
import sys
import time

KEYS = {" ": "spc", "-": "minus", "=": "equal", ".": "dot", "/": "slash",
        ",": "comma", ";": "semicolon", "_": "shift-minus", ":": "shift-semicolon",
        ">": "shift-dot", "|": "shift-backslash", "'": "apostrophe",
        '"': "shift-apostrophe", "*": "shift-8", "$": "shift-4", "&": "shift-7",
        "\n": "ret", "+": "shift-equal", "(": "shift-9", ")": "shift-0"}


class Vm:
    def __init__(self, scratch, shots):
        self.scratch = scratch
        self.shots = shots
        self.serial_buf = b""
        self.ser = None

    def mon(self, cmd):
        s = socket.socket(socket.AF_UNIX)
        s.connect(os.path.join(self.scratch, "mon.sock"))
        s.settimeout(5)
        s.recv(4096)
        s.sendall(cmd.encode() + b"\n")
        time.sleep(0.15)
        out = b""
        try:
            out = s.recv(65536)
        except socket.timeout:
            pass
        s.close()
        return out.decode(errors="replace")

    def shot(self, name, where=""):
        ppm = os.path.join(self.scratch, "shot-%s.ppm" % name)
        self.mon("screendump " + ppm + where)
        for _ in range(50):
            if os.path.exists(ppm) and os.path.getsize(ppm) > 0:
                break
            time.sleep(0.1)
        time.sleep(0.2)
        return ppm

    def save(self, ppm, name):
        out = os.path.join(self.shots, name + ".png")
        subprocess.run(["convert", ppm, out], check=True)
        os.unlink(ppm)
        print("saved", out, flush=True)

    def burst(self, name, secs, step):
        files = []
        start = time.time()
        end = start + secs
        i = 0
        while time.time() < end:
            t0 = time.time()
            files.append((t0 - start, self.shot("%s-%03d" % (name, i))))
            i += 1
            time.sleep(max(0, step - (time.time() - t0)))
        with open(os.path.join(self.shots, name + "-times.txt"), "w") as f:
            for i, (t, ppm) in enumerate(files):
                f.write("%s-%03d.png %.2f\n" % (name, i, t))
                self.save(ppm, "%s-%03d" % (name, i))

    def wait_pixel(self, x, y, color, secs, name, row=0):
        want = bytes.fromhex(color)
        end = time.time() + secs
        while time.time() < end:
            ppm = self.shot("wait")
            with open(ppm, "rb") as f:
                data = f.read()
            # Binary PPM: "P6\n<w> <h>\n255\n" and then RGB bytes.
            parts = data.split(b"\n", 3)
            width = row or int(parts[1].split()[0])
            pos = (y * width + x) * 3
            if parts[3][pos:pos + 3] == want:
                self.save(ppm, name)
                return
            os.unlink(ppm)
            time.sleep(0.2)
        raise SystemExit("timeout waiting for pixel %d,%d = %s" % (x, y, color))

    def type(self, text):
        for ch in text:
            if ch.isalnum():
                key = ("shift-" + ch.lower()) if ch.isupper() else ch
            else:
                key = KEYS[ch]
            self.mon("sendkey " + key)

    def serial(self):
        if self.ser is None:
            self.ser = socket.socket(socket.AF_UNIX)
            self.ser.connect(os.path.join(self.scratch, "ser.sock"))
            self.ser.settimeout(0.5)
        return self.ser

    def read_until(self, text, secs):
        end = time.time() + secs
        while time.time() < end:
            if text.encode() in self.serial_buf:
                i = self.serial_buf.index(text.encode()) + len(text)
                out, self.serial_buf = self.serial_buf[:i], self.serial_buf[i:]
                return out.decode(errors="replace")
            try:
                data = self.serial().recv(65536)
                self.serial_buf += data
            except socket.timeout:
                pass
        raise SystemExit("timeout waiting for %r; got %r" % (text, self.serial_buf[-500:]))

    def send(self, text):
        self.serial().sendall(text.encode())

    def login(self):
        self.send("\r")
        self.read_until("login:", 120)
        self.send("root\r")
        self.read_until("Password:", 20)
        self.send("test\r")
        self.read_until("# ", 20)
        self.send("export TERM=dumb PS1='B''S# '\r")
        self.read_until("BS# ", 10)

    def run(self, cmd, secs=120):
        self.send(cmd + "\r")
        out = self.read_until("BS# ", secs)
        print(out.replace("\r", ""), flush=True)


def main():
    vm = Vm(sys.argv[1], sys.argv[2])
    for action in sys.argv[3:]:
        name, _, arg = action.partition("=")
        if name == "wait":
            time.sleep(float(arg))
        elif name == "key":
            vm.mon("sendkey " + arg)
            time.sleep(0.2)
        elif name == "type":
            vm.type(arg)
        elif name == "shot":
            vm.save(vm.shot(arg), arg)
        elif name == "mon":
            print(vm.mon(arg), flush=True)
        elif name == "shothead":
            n, dev, head = arg.split(":")
            vm.save(vm.shot(n, " %s %s" % (dev, head)), n)
        elif name == "burst":
            n, secs, step = arg.split(":")
            vm.burst(n, float(secs), float(step))
        elif name == "login":
            vm.login()
        elif name == "send":
            vm.send(arg + "\r")
        elif name == "run":
            vm.run(arg)
        elif name == "runt":
            secs, cmd = arg.split(":", 1)
            vm.run(cmd, float(secs))
        elif name == "waitpixel":
            x, y, color, secs, n, *row = arg.split(":")
            vm.wait_pixel(int(x), int(y), color, float(secs), n, int(row[0]) if row else 0)
        elif name == "waitfor":
            text, secs = arg.rsplit(":", 1)
            vm.read_until(text, float(secs))
        else:
            raise SystemExit("unknown action " + action)


if __name__ == "__main__":
    main()
