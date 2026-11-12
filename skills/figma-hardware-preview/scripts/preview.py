#!/usr/bin/env python3
"""Package a Figma export and send it to the Android hardware viewer over USB."""

import argparse
import hashlib
import json
import re
import shlex
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile
import zlib
from pathlib import Path
from urllib.request import urlopen

PACKAGE = "dev.local.figmapreview"
VIEWER_APK = "figma-hardware-preview.apk"
VIEWER_URL = ("https://github.com/liry-go/codex-skills/releases/download/"
              "figma-hardware-preview-v1.0.0/" + VIEWER_APK)
VIEWER_SHA256 = "96893678317791f58d301d4231aef9569d9b30ba5cb95ffe6286b16485a1bec9"
MAX_APK = 8 * 1024 * 1024
PNG_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,91}\.png")
MAX_BUNDLE = 24 * 1024 * 1024
MAX_MANIFEST = 64 * 1024
MAX_EDGE = 4096
MAX_PIXELS = 24 * 1024 * 1024
MAX_BUTTONS = 64


def require(condition, message):
    if not condition:
        raise ValueError(message)


def within(value, low, high):
    return type(value) is int and low <= value <= high


def png_size(data, name):
    require(
        len(data) >= 45 and data.startswith(b"\x89PNG\r\n\x1a\n")
        and data[8:16] == b"\x00\x00\x00\x0dIHDR",
        f"{name}: expected a PNG image",
    )
    width, height = struct.unpack_from(">II", data, 16)
    require(0 < width <= MAX_EDGE and 0 < height <= MAX_EDGE,
            f"{name}: dimensions must be within 1–{MAX_EDGE}px")
    position = 8
    has_pixels = False
    while position + 12 <= len(data):
        length, kind = struct.unpack_from(">I4s", data, position)
        end = position + 8 + length
        require(end + 4 <= len(data), f"{name}: truncated PNG chunk")
        crc = struct.unpack_from(">I", data, end)[0]
        require(zlib.crc32(data[position + 4:end]) == crc, f"{name}: invalid PNG checksum")
        require(kind != b"acTL", f"{name}: export a static PNG")
        has_pixels |= kind == b"IDAT"
        position = end + 4
        if kind == b"IEND":
            require(has_pixels and length == 0 and position == len(data),
                    f"{name}: invalid PNG ending")
            return width, height
    raise ValueError(f"{name}: missing PNG ending")


def validate(manifest, read):
    require(isinstance(manifest, dict) and set(manifest) == {"schema", "buttons"}
            and within(manifest["schema"], 1, 1), "Expected a version 1 preview manifest")
    buttons = manifest["buttons"]
    require(isinstance(buttons, list) and len(buttons) <= MAX_BUTTONS,
            f"Expected a list of up to {MAX_BUTTONS} buttons")
    width, height = png_size(read("screen.png"), "screen.png")
    sizes = {"screen.png": (width, height)}
    rectangles = []

    for index, button in enumerate(buttons, 1):
        prefix = f"Button {index}"
        require(isinstance(button, dict), f"{prefix}: expected an object")
        label = button.get("label")
        require(isinstance(label, str) and 0 < len(label.strip()) <= 100,
                f"{prefix}: provide a short label")
        rect = button.get("rect")
        require(isinstance(rect, list) and len(rect) == 4
                and all(type(value) is int for value in rect),
                f"{prefix}: rect must be four integer pixel values")
        x, y, w, h = rect
        require(x >= 0 and y >= 0 and w > 0 and h > 0
                and x + w <= width and y + h <= height, f"{prefix}: rect leaves the frame")
        for left, top, right, bottom in rectangles:
            require(x >= right or x + w <= left or y >= bottom or y + h <= top,
                    f"{prefix}: rect overlaps another button")
        rectangles.append((x, y, x + w, y + h))

        common = {"label", "rect", "mode", "press_ms", "release_ms"}
        mode = button.get("mode")
        if mode == "patch":
            tiles = ("pressed",)
        elif mode == "sink":
            tiles = ("underlay", "face")
            require(within(button.get("depth"), 1, h - 1), f"{prefix}: invalid sink depth")
            common.add("depth")
        else:
            raise ValueError(f"{prefix}: expected mode patch or sink")
        require(set(button) <= common.union(tiles), f"{prefix}: unknown property")
        for key in ("press_ms", "release_ms"):
            require(within(button.get(key, 0), 0, 1000), f"{prefix}: invalid {key}")
        for key in tiles:
            name = button.get(key)
            require(isinstance(name, str) and PNG_NAME.fullmatch(name) and name != "screen.png",
                    f"{prefix}: {key} must name a flat PNG file")
            if name not in sizes:
                sizes[name] = png_size(read(name), name)
            require(sizes[name] == (w, h), f"{prefix}: {name} must be {w} × {h}px")

    require(sum(w * h for w, h in sizes.values()) <= MAX_PIXELS, "Preview uses too much bitmap memory")
    return set(sizes)


def atomic_write(path, write):
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        write(temporary)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def pack(args):
    buttons = json.loads(args.buttons.read_text(encoding="utf-8")) if args.buttons else []
    manifest = {"schema": 1, "buttons": buttons}
    manifest_bytes = json.dumps(manifest, ensure_ascii=False).encode()
    require(len(manifest_bytes) <= MAX_MANIFEST, "Button manifest exceeds 64 KiB")
    files = {}
    total = len(manifest_bytes)

    def read(name):
        nonlocal total
        path = args.screen if name == "screen.png" else args.buttons.parent / name
        total += path.stat().st_size
        require(total <= MAX_BUNDLE, "Preview exceeds 24 MiB")
        files[name] = path.read_bytes()
        return files[name]

    validate(manifest, read)

    def write(path):
        with zipfile.ZipFile(path, "x") as bundle:
            bundle.writestr("preview.json", manifest_bytes)
            for name, data in files.items():
                bundle.writestr(name, data)
        require(path.stat().st_size <= MAX_BUNDLE, "Preview exceeds 24 MiB including ZIP headers")

    atomic_write(args.out, write)
    print(f"Packed {len(buttons)} button(s) into {args.out}")


def verify_bundle(path):
    require(0 < path.stat().st_size <= MAX_BUNDLE, "Expected a preview ZIP under 24 MiB")
    with zipfile.ZipFile(path) as bundle:
        entries = bundle.infolist()
        names = {entry.filename for entry in entries}
        require(len(entries) == len(names) and len(names) <= 2 + MAX_BUTTONS * 2
                and sum(entry.file_size for entry in entries) <= MAX_BUNDLE,
                "Invalid preview ZIP entries")
        require(bundle.getinfo("preview.json").file_size <= MAX_MANIFEST, "Manifest exceeds 64 KiB")
        manifest = json.loads(bundle.read("preview.json"))
        require(names == validate(manifest, bundle.read) | {"preview.json"},
                "Preview ZIP contains unused files")


def adb_run(command, *, data=None, timeout=60, check=True):
    result = subprocess.run(["adb", *command], input=data, capture_output=True, timeout=timeout)
    if check and result.returncode:
        details = (result.stderr or result.stdout).decode(errors="replace").strip()
        raise ValueError(details or f"ADB exited with code {result.returncode}")
    return result


def usb_device(serial):
    devices = {}
    lines = adb_run(["devices", "-l"]).stdout.decode(errors="replace").splitlines()
    for line in lines:
        columns = line.split()
        if len(columns) >= 2 and any(column.startswith("usb:") for column in columns[2:]):
            devices[columns[0]] = columns[1]
    ready = [name for name, state in devices.items() if state == "device"]
    if serial:
        require(serial in ready, "Selected device must be connected over USB and authorized for ADB")
        return serial
    if not ready:
        raise ValueError("No authorized USB Android device. Check the cable and accept USB debugging.")
    require(len(ready) == 1, "Multiple USB devices. Choose --serial from: " + ", ".join(ready))
    return ready[0]


def app_shell(serial, command, **kwargs):
    return adb_run(["-s", serial, "shell", "-T", "run-as", PACKAGE, "sh", "-c",
                    shlex.quote(command)], **kwargs)


def install_viewer(serial, apk):
    result = adb_run(["-s", serial, "install", "-r", str(apk)], timeout=120)
    require(b"Success" in result.stdout, result.stdout.decode(errors="replace"))
    app_shell(serial, "true")
    print(f"Viewer installed on USB device {serial}")


def ensure_viewer(serial):
    try:
        app_shell(serial, "true")
        return
    except ValueError as error:
        result = adb_run(["-s", serial, "shell", "pm", "list", "packages", PACKAGE])
        if f"package:{PACKAGE}".encode() in result.stdout.splitlines():
            raise ValueError(f"The installed viewer on {serial} is not accessible via ADB. {error}") from error

    print(f"Downloading the viewer for USB device {serial} from GitHub Release", flush=True)
    try:
        with urlopen(VIEWER_URL, timeout=30) as response:
            payload = response.read(MAX_APK + 1)
    except OSError as error:
        raise ValueError(f"Could not download the viewer from GitHub: {error}") from error
    require(len(payload) <= MAX_APK and hashlib.sha256(payload).hexdigest() == VIEWER_SHA256,
            "Viewer APK failed SHA-256 verification")

    with tempfile.TemporaryDirectory(prefix="figma-hardware-preview-") as directory:
        apk = Path(directory) / VIEWER_APK
        apk.write_bytes(payload)
        install_viewer(serial, apk)


def deploy(args):
    verify_bundle(args.bundle)
    serial = usb_device(args.serial)
    ensure_viewer(serial)
    payload = args.bundle.read_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    token = uuid.uuid4().hex
    incoming = f"files/incoming-{token}.zip"
    temporary = f"{incoming}.tmp"
    status = f"files/status-{token}"
    try:
        app_shell(serial, f"mkdir -p files && cat > {temporary} && "
                  f"echo '{digest}  {temporary}' | sha256sum -c && mv {temporary} {incoming}",
                  data=payload)
        result = adb_run(["-s", serial, "shell", "am", "start", "-W", "-n",
                          f"{PACKAGE}/.PreviewActivity", "--es", "preview_id", token])
        require(b"Error" not in result.stdout, result.stdout.decode(errors="replace"))
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            result = app_shell(serial, f"cat {status}", check=False, timeout=5)
            if result.returncode == 0:
                response = result.stdout.decode(errors="replace").strip()
                require(response == "ok", response or "Viewer rejected the preview")
                print(f"Preview displayed on USB device {serial}")
                return
            time.sleep(0.25)
        raise ValueError("Viewer did not acknowledge the preview. Check its screen and retry.")
    finally:
        try:
            app_shell(serial, f"rm -f {temporary} {incoming} {status} {status}.tmp",
                      check=False, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            pass


def install(args):
    require(args.apk.is_file(), "Provide the downloaded viewer APK")
    install_viewer(usb_device(args.serial), args.apk)


def capture(args):
    serial = usb_device(args.serial)
    data = adb_run(["-s", serial, "exec-out", "screencap", "-p"]).stdout
    width, height = png_size(data, "device screenshot")
    atomic_write(args.out, lambda path: path.write_bytes(data))
    print(f"Captured {width} × {height} screen from {serial} to {args.out}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(required=True)
    pack_parser = actions.add_parser("pack", help="Create a preview ZIP from local PNGs")
    pack_parser.add_argument("--screen", type=Path, required=True)
    pack_parser.add_argument("--buttons", type=Path)
    pack_parser.add_argument("--out", type=Path, required=True)
    pack_parser.set_defaults(run=pack)

    for name, func, path_option in (("install", install, "--apk"),
                                     ("deploy", deploy, "--bundle"),
                                     ("capture", capture, "--out")):
        action = actions.add_parser(name)
        action.add_argument("--serial")
        action.add_argument(path_option, type=Path, required=True)
        action.set_defaults(run=func)
    args = parser.parse_args()
    try:
        args.run(args)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.TimeoutExpired) as error:
        print(f"Preview error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
