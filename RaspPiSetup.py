sudo bash -lc 'SUPABASE_EDGE_URL="https://zekbonbxwccgsfagrrph.functions.supabase.co/handle-device"; SUPABASE_AUTH_TOKEN="27250d319212d0d3f35ab39af8415345cca8d7d114fac1c5b3b30ae3c9e1be9d"; set -euo pipefail; mkdir -p /opt/evvos; mkdir -p /etc/evvos; chmod 700 /etc/evvos; cat > /opt/evvos/evvos_ble_provision.py <<'"'PY'"'
#!/usr/bin/env python3
# EVVOS BLE GATT provisioning daemon
# - Advertises name EVVOS_0001
# - Exposes a writable characteristic that accepts JSON payload (ssid, password, device_name, user_id?)
# - On write: saves credentials, tries Wi-Fi, encrypts payload and POSTs to Supabase Edge Function
import sys
import os
import json
import time
import base64
import subprocess
from pathlib import Path

# D-Bus / BlueZ imports
try:
    import dbus
    import dbus.mainloop.glib
    from gi.repository import GLib
except Exception as e:
    print("Missing D-Bus or GLib Python bindings:", e)
    raise

# Optional python packages
try:
    import requests
    from cryptography.fernet import Fernet
except Exception as e:
    print("Missing python pip packages (requests, cryptography). Install with pip3.")
    raise

APP_DIR = Path("/opt/evvos")
CRED_FILE = Path("/etc/evvos/credentials.json")
KEY_FILE = Path("/etc/evvos/secret.key")
CONFIG_FILE = Path("/etc/evvos/config.json")
BT_DEVICE_NAME = "EVVOS_0001"
WPA_SUPPLICANT_CONF = Path("/etc/wpa_supplicant/wpa_supplicant.conf")
CHECK_INTERNET_HOST = "8.8.8.8"
PING_TIMEOUT = 3

# BlueZ D-Bus constants
BLUEZ_SERVICE_NAME = "org.bluez"
DBUS_OM_IFACE = "org.freedesktop.DBus.ObjectManager"
GATT_MANAGER_IFACE = "org.bluez.GattManager1"
ADVERTISING_MANAGER_IFACE = "org.bluez.LEAdvertisingManager1"

# Our GATT UUIDs (stable)
SERVICE_UUID = "12345678-1234-5678-1234-56789abcdef0"
CHAR_UUID = "12345678-1234-5678-1234-56789abcdef1"

def run_cmd(cmd, check=True):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check, text=True)

def ensure_dirs():
    APP_DIR.mkdir(parents=True, exist_ok=True)
    Path("/etc/evvos").mkdir(parents=True, exist_ok=True)
    os.chmod("/etc/evvos", 0o700)

def load_config():
    cfg = {"supabase_edge_url": os.environ.get("SUPABASE_EDGE_URL",""), "supabase_auth_token": os.environ.get("SUPABASE_AUTH_TOKEN","")}
    try:
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE,"r") as f:
                j = json.load(f)
                cfg.update(j)
    except Exception:
        pass
    return cfg

def generate_key_if_missing():
    if not KEY_FILE.exists():
        key = Fernet.generate_key()
        KEY_FILE.write_bytes(key)
        os.chmod(KEY_FILE, 0o600)
    return KEY_FILE.read_bytes()

def is_internet_up():
    try:
        subprocess.check_call(["ping","-c","1","-W","%d" % PING_TIMEOUT, CHECK_INTERNET_HOST],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except subprocess.CalledProcessError:
        return False

def attempt_connect_from_local_credentials():
    if not CRED_FILE.exists():
        return False
    try:
        data = json.loads(CRED_FILE.read_text())
        ssid = data.get("ssid")
        psk = data.get("password")
        if not ssid:
            return False
        write_wpa_conf(ssid, psk)
        reconfigure_wpa()
        for _ in range(12):
            if is_internet_up():
                return True
            time.sleep(2)
        return False
    except Exception as e:
        print("Error using local credentials:", e)
        return False

def write_wpa_conf(ssid, psk):
    try:
        conf = WPA_SUPPLICANT_CONF.read_text() if WPA_SUPPLICANT_CONF.exists() else ""
    except Exception:
        conf = ""
    network_block = 'network={\\n    ssid="%s"\\n    psk="%s"\\n    key_mgmt=WPA-PSK\\n}\\n' % (ssid, psk or "")
    if ssid not in conf:
        with open(WPA_SUPPLICANT_CONF, "a") as f:
            f.write("\\n# evvos auto-added\\n")
            f.write(network_block)
        os.chmod(WPA_SUPPLICANT_CONF, 0o600)

def reconfigure_wpa():
    try:
        run_cmd(["wpa_cli", "-i", "wlan0", "reconfigure"], check=False)
    except Exception:
        try:
            run_cmd(["ifdown", "wlan0"], check=False)
            run_cmd(["ifup", "wlan0"], check=False)
        except Exception:
            pass

def encrypt_payload_and_send(payload_obj, cfg, fernet):
    raw = json.dumps(payload_obj)
    token = fernet.encrypt(raw.encode("utf-8"))
    b64 = base64.b64encode(token).decode("utf-8")
    body = {
        "device_name": payload_obj.get("device_name"),
        "encrypted_payload": b64,
        "device_id": payload_obj.get("device_id", payload_obj.get("device_name"))
    }
    url = cfg.get("supabase_edge_url")
    headers = {"Authorization": "Bearer " + cfg.get("supabase_auth_token",""), "Content-Type": "application/json"}
    try:
        r = requests.post(url, json=body, headers=headers, timeout=10)
        print("Edge function response:", r.status_code, r.text)
        return r.status_code >= 200 and r.status_code < 300
    except Exception as e:
        print("Failed to POST to edge:", e)
        return False

# BlueZ D-Bus GATT server helper classes (adapted from BlueZ examples)
class Application(dbus.service.Object):
    PATH_BASE = "/org/evvos/gatt"
    def __init__(self, bus):
        self.path = self.PATH_BASE
        dbus.service.Object.__init__(self, bus, self.path)
        self.services = []

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_service(self, service):
        self.services.append(service)

    @dbus.service.method(DBUS_OM_IFACE, out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        response = {}
        for service in self.services:
            response[service.get_path()] = service.get_properties()
            chrcs = service.get_characteristics()
            for chrc in chrcs:
                response[chrc.get_path()] = chrc.get_properties()
        return response

class Service(dbus.service.Object):
    def __init__(self, bus, index, uuid, primary):
        self.path = Application.PATH_BASE + "/service" + str(index)
        self.bus = bus
        self.uuid = uuid
        self.primary = primary
        self.characteristics = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self):
        return {
            "org.bluez.GattService1": {
                "UUID": self.uuid,
                "Primary": self.primary,
                "Includes": dbus.Array([], signature='o')
            }
        }

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_characteristic(self, chrc):
        self.characteristics.append(chrc)

    def get_characteristics(self):
        return self.characteristics

class Characteristic(dbus.service.Object):
    def __init__(self, bus, index, uuid, flags, service, write_callback):
        self.path = service.get_path() + "/char" + str(index)
        self.bus = bus
        self.uuid = uuid
        self.flags = flags
        self.service = service
        self.write_callback = write_callback
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self):
        return {
            "org.bluez.GattCharacteristic1": {
                "Service": self.service.get_path(),
                "UUID": self.uuid,
                "Flags": dbus.Array(self.flags, signature='s')
            }
        }

    def get_path(self):
        return dbus.ObjectPath(self.path)

    @dbus.service.method("org.bluez.GattCharacteristic1", in_signature="aya{sv}")
    def WriteValue(self, value, options):
        try:
            raw = bytes(bytearray(value)).decode("utf-8", errors="ignore")
        except Exception:
            raw = ""
        print("Characteristic WriteValue called; payload length:", len(raw))
        if raw:
            try:
                j = json.loads(raw)
            except Exception as e:
                print("Invalid JSON payload:", e)
                return
            try:
                CRED_FILE.write_text(json.dumps(j))
                os.chmod(CRED_FILE, 0o600)
                print("Saved credentials to", str(CRED_FILE))
            except Exception as e:
                print("Failed to save credentials:", e)
            try:
                ssid = j.get("ssid")
                psk = j.get("password","")
                if ssid:
                    write_wpa_conf(ssid, psk)
                    reconfigure_wpa()
                    for _ in range(15):
                        if is_internet_up():
                            print("Internet is up after provisioning")
                            key = generate_key_if_missing()
                            fernet = Fernet(key)
                            cfg = load_config()
                            ok = encrypt_payload_and_send(j, cfg, fernet)
                            print("Sent to edge:", ok)
                            break
                        time.sleep(2)
                    else:
                        print("Unable to connect to Wi-Fi after provisioning attempt")
            except Exception as e:
                print("Error during provisioning attempt:", e)

    @dbus.service.method("org.bluez.GattCharacteristic1", in_signature="", out_signature="ay")
    def ReadValue(self):
        return dbus.Array([dbus.Byte(c) for c in b"EVVOS_PROVISION_CHAR"], signature='y')

class Advertisement(dbus.service.Object):
    PATH_BASE = "/org/evvos/advert"
    def __init__(self, bus, index, adv_type):
        self.path = self.PATH_BASE + str(index)
        self.bus = bus
        self.ad_type = adv_type
        dbus.service.Object.__init__(self, bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def get_properties(self):
        return {
            "org.bluez.LEAdvertisement1": {
                "Type": self.ad_type,
                "LocalName": BT_DEVICE_NAME,
                "ServiceUUIDs": dbus.Array([SERVICE_UUID], signature='s'),
                "Discoverable": dbus.Boolean(True)
            }
        }

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != "org.bluez.LEAdvertisement1":
            raise Exception("Invalid interface")
        return self.get_properties()["org.bluez.LEAdvertisement1"]

    @dbus.service.method("org.bluez.LEAdvertisement1", in_signature="")
    def Release(self):
        print("Advertisement released")

def register_app_and_advert():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    obj_manager = dbus.Interface(bus.get_object(BLUEZ_SERVICE_NAME, "/"), DBUS_OM_IFACE)
    managed = obj_manager.GetManagedObjects()
    adapter_path = None
    for path, ifaces in managed.items():
        if "org.bluez.Adapter1" in ifaces:
            adapter_path = path
            break
    if not adapter_path:
        print("No bluetooth adapter found")
        sys.exit(1)

    adapter_obj = bus.get_object(BLUEZ_SERVICE_NAME, adapter_path)
    adapter_props = dbus.Interface(adapter_obj, "org.freedesktop.DBus.Properties")
    try:
        adapter_props.Set("org.bluez.Adapter1", "Powered", dbus.Boolean(1))
        adapter_props.Set("org.bluez.Adapter1", "Alias", dbus.String(BT_DEVICE_NAME))
        adapter_props.Set("org.bluez.Adapter1", "Discoverable", dbus.Boolean(1))
        adapter_props.Set("org.bluez.Adapter1", "Pairable", dbus.Boolean(1))
    except Exception as e:
        print("Failed to set adapter properties:", e)

    ad_manager = dbus.Interface(bus.get_object(BLUEZ_SERVICE_NAME, adapter_path), ADVERTISING_MANAGER_IFACE)
    ad = Advertisement(bus, 0, "peripheral")
    ad_path = ad.get_path()
    try:
        ad_manager.RegisterAdvertisement(ad_path, {}, reply_handler=lambda: print("Advertisement registered"), error_handler=lambda e: print("Failed to register ad:", e))
    except Exception as e:
        print("RegisterAdvertisement exception:", e)

    service_index = 0
    app = Application(bus)
    service = Service(bus, service_index, SERVICE_UUID, True)
    app.add_service(service)
    ch = Characteristic(bus, 0, CHAR_UUID, ["write","read","write-without-response"], service, None)
    service.add_characteristic(ch)

    gatt_manager = dbus.Interface(bus.get_object(BLUEZ_SERVICE_NAME, adapter_path), GATT_MANAGER_IFACE)
    app_path = app.get_path()
    try:
        gatt_manager.RegisterApplication(app_path, {}, reply_handler=lambda: print("GATT application registered"), error_handler=lambda e: print("Failed to register GATT app:", e))
    except Exception as e:
        print("RegisterApplication exception:", e)

    mainloop = GLib.MainLoop()
    print("EVVOS BLE GATT provisioning daemon running, advertising name:", BT_DEVICE_NAME)
    try:
        mainloop.run()
    except KeyboardInterrupt:
        print("Shutting down")
        try:
            ad_manager.UnregisterAdvertisement(ad_path)
        except Exception:
            pass
        sys.exit(0)

if __name__ == "__main__":
    ensure_dirs()
    cfg = load_config()
    # Save the config file if not present, so the daemon has the correct URL/token available
    try:
        with open(CONFIG_FILE, "w") as f:
            json.dump(cfg, f)
        os.chmod(CONFIG_FILE, 0o600)
    except Exception:
        pass
    if attempt_connect_from_local_credentials():
        print("Connected using local credentials; exiting (no provisioning needed).")
        sys.exit(0)
    register_app_and_advert()
PY
chmod +x /opt/evvos/evvos_ble_provision.py

# write config with provided SUPABASE_EDGE_URL and SUPABASE_AUTH_TOKEN
cat > /etc/evvos/config.json <<'"'CFG"''
{
  "supabase_edge_url": "'"${SUPABASE_EDGE_URL}"'",
  "supabase_auth_token": "'"${SUPABASE_AUTH_TOKEN}"'"
}
CFG
chmod 600 /etc/evvos/config.json

# systemd service
cat > /etc/systemd/system/evvos-ble-provision.service <<'"'UNIT"''
[Unit]
Description=EVVOS BLE GATT Provisioning Service
After=bluetooth.service network-online.target
Requires=bluetooth.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/evvos/evvos_ble_provision.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT

# Install system packages and python deps
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y bluez python3-dbus python3-gi python3-pip libdbus-1-dev libdbus-glib-1-dev
pip3 install requests cryptography

# Enable bluetooth and service
systemctl daemon-reload
systemctl enable bluetooth.service
systemctl enable evvos-ble-provision.service
systemctl start evvos-ble-provision.service

echo "Installed EVVOS BLE provisioning. Edit /etc/evvos/config.json to change URL/token if needed. Check logs with: sudo journalctl -u evvos-ble-provision -f"
'
