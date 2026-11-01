"""
USB Cam relay (Windows / macOS / Linux, no extra packages).
Talks to the iPhone through usbmuxd (Apple Mobile Device Service) over the USB cable,
then re-serves the H.264 stream on tcp://127.0.0.1:5000 for OBS.
"""
import plistlib, socket, struct, sys, threading, time

PHONE_PORT = 5005       # port the app listens on (on the iPhone)
OBS_PORT = 5000         # port OBS connects to (on this PC)

_tag = 0
_last_status = None
clients = []            # [socket, got_keyframe]
lock = threading.Lock()


def status(msg):
    global _last_status
    if msg != _last_status:
        print(msg, flush=True)
        _last_status = msg


def mux_open():
    if sys.platform == "win32":
        s = socket.create_connection(("127.0.0.1", 27015), timeout=3)
    else:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(3)
        s.connect("/var/run/usbmuxd")
    return s


def recv_exact(s, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return bytes(buf)


def mux_send(s, msg):
    global _tag
    _tag += 1
    body = plistlib.dumps(msg)
    s.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, _tag) + body)


def mux_recv(s):
    length = struct.unpack("<IIII", recv_exact(s, 16))[0]
    return plistlib.loads(recv_exact(s, length - 16))


def find_device():
    s = mux_open()
    try:
        mux_send(s, {"MessageType": "ListDevices", "ClientVersionString": "usbcam", "ProgName": "usbcam"})
        r = mux_recv(s)
    finally:
        s.close()
    for d in r.get("DeviceList", []):
        props = d.get("Properties", {})
        if props.get("ConnectionType", "USB") == "USB":
            return d.get("DeviceID", props.get("DeviceID"))
    return None


def connect_phone(dev_id, port):
    s = mux_open()
    mux_send(s, {"MessageType": "Connect", "ClientVersionString": "usbcam", "ProgName": "usbcam",
                 "DeviceID": dev_id, "PortNumber": ((port & 0xFF) << 8) | (port >> 8)})
    r = mux_recv(s)
    if r.get("Number") != 0:
        s.close()
        raise ConnectionError("mux error %s" % r.get("Number"))
    s.settimeout(None)
    return s


def obs_accept_loop():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", OBS_PORT))
    srv.listen(4)
    while True:
        c, _ = srv.accept()
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        with lock:
            clients.append([c, False])
        print("OBS connected", flush=True)


def broadcast(is_key, payload):
    with lock:
        for entry in clients[:]:
            if not entry[1]:
                if not is_key:
                    continue          # new OBS client must start on a keyframe
                entry[1] = True
            try:
                entry[0].sendall(payload)
            except OSError:
                clients.remove(entry)
                entry[0].close()
                print("OBS disconnected", flush=True)


def main():
    threading.Thread(target=obs_accept_loop, daemon=True).start()
    print("OBS source URL: tcp://127.0.0.1:%d (input format: h264)" % OBS_PORT, flush=True)
    while True:
        try:
            dev = find_device()
            if dev is None:
                status("Waiting for iPhone... (plug USB, unlock, tap Trust)")
                time.sleep(1)
                continue
            phone = connect_phone(dev, PHONE_PORT)
        except ConnectionRefusedError:
            status("Apple Mobile Device Service not running. Install iTunes or the 'Apple Devices' app.")
            time.sleep(2)
            continue
        except (OSError, ConnectionError):
            status("iPhone found, waiting for the USB Cam app to be open...")
            time.sleep(1)
            continue
        status("Phone connected, streaming")
        try:
            while True:
                flag, n = struct.unpack(">BI", recv_exact(phone, 5))
                broadcast(flag == 1, recv_exact(phone, n))
        except (OSError, ConnectionError):
            pass
        phone.close()
        status("Phone disconnected")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
