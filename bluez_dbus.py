"""Aide D-Bus pour piloter BlueZ (bluetoothd) directement, sans passer par
bluetoothctl.

bluetoothctl est un outil interactif pensé pour un humain, pas pour être
scripté : ses réponses sont du texte asynchrone à parser, et chaque
invocation démarre son propre agent SSP par défaut — deux instances
lancées en parallèle (ex: une session de scan en tâche de fond + une
commande "pair" séparée) peuvent se disputer la confirmation
d'appairage, provoquant des échecs intermittents (AuthenticationCanceled,
AuthenticationFailed...) difficiles à diagnostiquer depuis du texte
scrapé.

Ici, chaque opération (Pair/Connect/RemoveDevice) est un appel de méthode
D-Bus qui lève une vraie exception BlueZ (PairingError, avec le nom d'erreur
D-Bus d'origine) en cas d'échec, et un seul agent SSP est enregistré,
explicitement, pour toute la durée de vie du script.

Le modèle agent + boucle GLib asynchrone est celui des scripts de référence
du dépôt BlueZ (test/simple-agent, test/test-device) : Pair()/Connect() sont
appelés en mode asynchrone (reply_handler/error_handler) pendant qu'une
boucle GLib tourne, parce qu'un appel strictement bloquant empêcherait notre
propre agent de répondre aux callbacks (RequestConfirmation, etc.) que
bluetoothd peut nous envoyer PENDANT la négociation SSP.
"""
from __future__ import annotations

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

BUS_NAME = "org.bluez"
ADAPTER_IFACE = "org.bluez.Adapter1"
DEVICE_IFACE = "org.bluez.Device1"
AGENT_IFACE = "org.bluez.Agent1"
AGENT_MANAGER_IFACE = "org.bluez.AgentManager1"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
AGENT_PATH = "/fr/raspberry_bluetooth_autoconnect/agent"


class PairingError(Exception):
    """Erreur BlueZ levée par Pair()/Connect(), avec le nom D-Bus d'origine
    (ex: "org.bluez.Error.AuthenticationFailed") pour un diagnostic précis."""

    def __init__(self, dbus_error_name: str, message: str):
        self.dbus_error_name = dbus_error_name
        super().__init__(message)


class _Agent(dbus.service.Object):
    """Agent SSP minimal : accepte tout automatiquement ("Just Works"),
    adapté à un usage embarqué sans écran ni clavier."""

    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Release(self):
        pass

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        return

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        return "0000"

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        return dbus.UInt32(0)

    @dbus.service.method(AGENT_IFACE, in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered):
        pass

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        pass

    @dbus.service.method(AGENT_IFACE, in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        return

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        return

    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Cancel(self):
        pass


class BlueZController:
    def __init__(self, adapter_name: str = "hci0"):
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SystemBus()
        self.mainloop = GLib.MainLoop()

        self.adapter_path = f"/org/bluez/{adapter_name}"
        self.adapter = dbus.Interface(
            self.bus.get_object(BUS_NAME, self.adapter_path), ADAPTER_IFACE
        )
        self._adapter_props = dbus.Interface(
            self.bus.get_object(BUS_NAME, self.adapter_path), PROPS_IFACE
        )

        self._agent = _Agent(self.bus, AGENT_PATH)
        agent_manager = dbus.Interface(
            self.bus.get_object(BUS_NAME, "/org/bluez"), AGENT_MANAGER_IFACE
        )
        agent_manager.RegisterAgent(AGENT_PATH, "NoInputNoOutput")
        agent_manager.RequestDefaultAgent(AGENT_PATH)

    # --- Adaptateur ---

    def adapter_powered(self) -> bool:
        return bool(self._adapter_props.Get(ADAPTER_IFACE, "Powered"))

    def set_adapter_powered(self, powered: bool) -> None:
        self._adapter_props.Set(ADAPTER_IFACE, "Powered", dbus.Boolean(powered))

    # --- Découverte ---

    def start_discovery(self, transport: str = "bredr") -> None:
        try:
            self.adapter.SetDiscoveryFilter({"Transport": transport})
        except dbus.exceptions.DBusException:
            pass  # anciennes versions de BlueZ : tant pis, scan par défaut ("auto")
        try:
            self.adapter.StartDiscovery()
        except dbus.exceptions.DBusException as exc:
            if "InProgress" not in str(exc):
                raise

    def stop_discovery(self) -> None:
        try:
            self.adapter.StopDiscovery()
        except dbus.exceptions.DBusException:
            pass

    def list_devices(self) -> list[dict]:
        """Appareils connus de bluetoothd sous cet adaptateur : chacun avec
        son adresse, son nom, et ses états paired/connected actuels."""
        om = dbus.Interface(
            self.bus.get_object(BUS_NAME, "/"), "org.freedesktop.DBus.ObjectManager"
        )
        objects = om.GetManagedObjects()
        devices = []
        for path, ifaces in objects.items():
            if DEVICE_IFACE not in ifaces:
                continue
            if not str(path).startswith(self.adapter_path + "/"):
                continue
            props = ifaces[DEVICE_IFACE]
            devices.append(
                {
                    "path": str(path),
                    "address": str(props.get("Address", "")),
                    "name": str(props.get("Name", props.get("Alias", ""))),
                    "paired": bool(props.get("Paired", False)),
                    "connected": bool(props.get("Connected", False)),
                }
            )
        return devices

    # --- Appareil ---

    def _device_path(self, address: str) -> str:
        return self.adapter_path + "/dev_" + address.replace(":", "_")

    def device_properties(self, address: str) -> dict | None:
        path = self._device_path(address)
        try:
            props_iface = dbus.Interface(self.bus.get_object(BUS_NAME, path), PROPS_IFACE)
            return props_iface.GetAll(DEVICE_IFACE)
        except dbus.exceptions.DBusException:
            return None

    def is_paired(self, address: str) -> bool:
        props = self.device_properties(address)
        return bool(props and props.get("Paired"))

    def is_connected(self, address: str) -> bool:
        props = self.device_properties(address)
        return bool(props and props.get("Connected"))

    def remove_device(self, address: str) -> None:
        path = self._device_path(address)
        try:
            self.adapter.RemoveDevice(path)
        except dbus.exceptions.DBusException:
            pass

    def trust(self, address: str) -> None:
        path = self._device_path(address)
        props_iface = dbus.Interface(self.bus.get_object(BUS_NAME, path), PROPS_IFACE)
        props_iface.Set(DEVICE_IFACE, "Trusted", dbus.Boolean(True))

    def _call_async(self, address: str, method: str, timeout: int) -> None:
        path = self._device_path(address)
        device = dbus.Interface(self.bus.get_object(BUS_NAME, path), DEVICE_IFACE)
        result: dict = {}

        def reply():
            result["ok"] = True
            self.mainloop.quit()

        def error(err):
            result["ok"] = False
            result["error_name"] = err.get_dbus_name()
            result["error_message"] = str(err)
            self.mainloop.quit()

        getattr(device, method)(reply_handler=reply, error_handler=error)

        timeout_id = GLib.timeout_add_seconds(timeout, self._on_timeout)
        self.mainloop.run()
        try:
            GLib.source_remove(timeout_id)
        except Exception:
            pass

        if not result:
            raise PairingError("Timeout", f"{method} : pas de réponse après {timeout}s")
        if not result["ok"]:
            raise PairingError(result["error_name"], result["error_message"])

    def _on_timeout(self) -> bool:
        self.mainloop.quit()
        return False

    def pair(self, address: str, timeout: int = 15) -> None:
        self._call_async(address, "Pair", timeout)

    def connect(self, address: str, timeout: int = 10) -> None:
        self._call_async(address, "Connect", timeout)
