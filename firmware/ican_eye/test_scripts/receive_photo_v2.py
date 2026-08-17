"""
receive_photo_v2.py — iCan Eye BLE Photo Receiver (V2 — Profile Selection)

Connects to the XIAO ESP32-S3 'XIAO_Camera' BLE device and lets you choose
a quality profile before capturing. Supports multiple captures in one session.

Profiles:
    0 = FAST      320x240   ~3-5 KB    ~2s
    1 = BALANCED  640x480   ~15-25 KB  ~8s
    2 = QUALITY   800x600   ~30-50 KB  ~15s
    3 = MAX       1600x1200 ~80-150 KB ~45s

Requirements:
    pip install bleak

Usage:
    python receive_photo_v2.py
    python receive_photo_v2.py --profile 2              # start with QUALITY profile
    python receive_photo_v2.py --profile 3 --once       # single MAX capture then exit
    python receive_photo_v2.py --address AA:BB:CC:DD:EE:FF  # connect directly by MAC
"""

import asyncio
import argparse
import struct
import zlib
import os
import sys
from datetime import datetime
from bleak import BleakClient, BleakScanner

# Must match UUIDs in ble_camera_v2.ino
SERVICE_UUID  = "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
DATA_CHAR     = "beb5483e-36e1-4688-b7f5-ea07361b26a8"
CONTROL_CHAR  = "beb5483f-36e1-4688-b7f5-ea07361b26a8"

SEQ_HEADER_SIZE = 2
MAX_RETRIES = 2

PROFILE_NAMES = {
    0: "FAST     (320x240)",
    1: "BALANCED (640x480)",
    2: "QUALITY  (800x600)",
    3: "MAX      (1600x1200)",
}

# The Bleak client automatically negotiates the largest MTU supported by the 
# OS and the device. Data chunk parsing is dynamic based on len(data).


# ---------- Transfer state ----------
class TransferState:
    def __init__(self):
        self.reset()

    def reset(self):
        self.expected_size = 0
        self.expected_crc = None
        self.expected_chunks = 0
        self.profile_info = ""
        self.chunks = {}
        self.receiving = False
        self.transfer_done = False


state = TransferState()


def handle_control_notification(sender, data: bytearray):
    """Handle control messages: SIZE, CRC, INFO, END, PROFILE_SET."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return

    if text.startswith("SIZE:"):
        state.reset()
        state.expected_size = int(text.split(":")[1])
        state.receiving = True
        print(f"\n  Incoming image: {state.expected_size:,} bytes")

    elif text.startswith("CRC:"):
        state.expected_crc = text.split(":")[1].strip().upper()
        print(f"  Expected CRC32: {state.expected_crc}")

    elif text.startswith("INFO:"):
        state.profile_info = text.split(":")[1].strip()
        print(f"  Profile: {state.profile_info}")

    elif text.startswith("END"):
        parts = text.split(":")
        if len(parts) > 1:
            state.expected_chunks = int(parts[1])
        state.receiving = False
        state.transfer_done = True
        print(f"\n  Transfer complete ({state.expected_chunks} chunks)")

    elif text.startswith("PROFILE_SET:"):
        # Acknowledgement from ESP32: "PROFILE_SET:1:BALANCED"
        parts = text.split(":")
        print(f"  ✓ ESP32 profile set to: {parts[2] if len(parts) > 2 else parts[1]}")

    else:
        print(f"  [CTRL] {text}")


def handle_data_notification(sender, data: bytearray):
    """Handle image data chunks."""
    if not state.receiving:
        return
    if len(data) < SEQ_HEADER_SIZE:
        return

    seq_num = struct.unpack("<H", data[:SEQ_HEADER_SIZE])[0]
    state.chunks[seq_num] = bytes(data[SEQ_HEADER_SIZE:])

    # Progress bar
    received_bytes = sum(len(v) for v in state.chunks.values())
    if state.expected_size > 0:
        pct = min(100, received_bytes * 100 // state.expected_size)
        bar_len = 30
        filled = pct * bar_len // 100
        bar = "█" * filled + "░" * (bar_len - filled)
        print(f"  [{bar}] {pct:3d}%  {received_bytes:,}/{state.expected_size:,} bytes  (chunk #{seq_num})", end="\r")


def assemble_and_validate() -> tuple:
    """Assemble chunks and validate. Returns (image_data, is_valid, message)."""
    if not state.chunks:
        return None, False, "No data received"

    max_seq = max(state.chunks.keys())
    total_expected = state.expected_chunks if state.expected_chunks > 0 else (max_seq + 1)
    missing = [i for i in range(total_expected) if i not in state.chunks]

    # Assemble in order
    image_data = bytearray()
    for i in range(max_seq + 1):
        if i in state.chunks:
            image_data.extend(state.chunks[i])

    errors = []

    if missing:
        errors.append(f"Missing {len(missing)} chunk(s)")

    if state.expected_size > 0 and len(image_data) != state.expected_size:
        errors.append(f"Size: got {len(image_data):,}, expected {state.expected_size:,}")

    # JPEG markers
    if len(image_data) >= 2 and (image_data[0] != 0xFF or image_data[1] != 0xD8):
        errors.append(f"Bad JPEG header: {image_data[:2].hex()}")
    if len(image_data) >= 2 and (image_data[-2] != 0xFF or image_data[-1] != 0xD9):
        errors.append(f"Bad JPEG footer: {image_data[-2:].hex()}")

    # CRC32
    if state.expected_crc:
        actual_crc = format(zlib.crc32(image_data) & 0xFFFFFFFF, "08X")
        if actual_crc != state.expected_crc:
            errors.append(f"CRC: got {actual_crc}, expected {state.expected_crc}")
        else:
            print(f"  CRC32 OK: {actual_crc}")

    if errors:
        return image_data, False, "; ".join(errors)
    return image_data, True, "OK"


def save_image(image_data: bytearray, suffix: str = "") -> str:
    """Save image with timestamped filename."""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    profile_tag = state.profile_info.lower() if state.profile_info else "unknown"
    filename = f"photo_{timestamp}_{profile_tag}{suffix}.jpg"
    with open(filename, "wb") as f:
        f.write(image_data)
    return os.path.abspath(filename)


async def set_profile(client: BleakClient, profile_id: int):
    """Send a PROFILE command to the ESP32."""
    cmd = f"PROFILE:{profile_id}"
    await client.write_gatt_char(CONTROL_CHAR, cmd.encode())
    await asyncio.sleep(0.5)  # wait for acknowledgement


async def capture_once(client: BleakClient) -> bool:
    """Send CAPTURE and wait for the image. Returns True on success."""
    state.reset()
    print("\n  Sending CAPTURE...")
    await client.write_gatt_char(CONTROL_CHAR, b"CAPTURE")

    # Wait for transfer (up to 180s for large images)
    for _ in range(360):
        await asyncio.sleep(0.5)
        if state.transfer_done:
            break

    if not state.transfer_done:
        print("\n  [ERROR] Transfer timed out")
        return False

    print()  # newline after progress bar

    image_data, valid, msg = assemble_and_validate()

    if image_data is None:
        print(f"  ✗ {msg}")
        return False

    if valid:
        path = save_image(image_data)
        print(f"  ✓ Saved: {path} ({len(image_data):,} bytes)")
        return True
    else:
        print(f"  ✗ Validation failed: {msg}")
        path = save_image(image_data, suffix="_BAD")
        print(f"  (corrupt image saved: {path})")
        return False


async def main():
    parser = argparse.ArgumentParser(description="iCan Eye BLE Photo Receiver V2")
    parser.add_argument("--profile", type=int, default=1, choices=[0, 1, 2, 3],
                        help="Quality profile (0=FAST, 1=BALANCED, 2=QUALITY, 3=MAX)")
    parser.add_argument("--once", action="store_true",
                        help="Take one photo and exit (no interactive menu)")
    parser.add_argument("--address", type=str, default=None,
                        help="Connect directly by MAC address e.g. AA:BB:CC:DD:EE:FF (bypasses name scan)")
    args = parser.parse_args()

    print("=" * 55)
    print("  iCan Eye — BLE Photo Receiver V2")
    print("=" * 55)

    print("\nProfiles:")
    for k, v in PROFILE_NAMES.items():
        marker = " ◀" if k == args.profile else ""
        print(f"    {k}: {v}{marker}")

    # --- Scan / connect ---
    device = None

    if args.address:
        # Direct MAC connection — bypasses Windows BT name cache
        print(f"\nConnecting directly to {args.address}...")
        device = args.address  # BleakClient accepts a MAC string directly
    else:
        # Scan by name with retries (Windows sometimes needs 2-3 attempts
        # after a device reflash before it shows up in the scan)
        SCAN_ATTEMPTS = 3
        SCAN_TIMEOUT  = 10  # seconds per attempt
        for attempt in range(1, SCAN_ATTEMPTS + 1):
            print(f"\nScanning for XIAO_Camera... (attempt {attempt}/{SCAN_ATTEMPTS})")
            device = await BleakScanner.find_device_by_name("XIAO_Camera", timeout=SCAN_TIMEOUT)
            if device:
                break
            if attempt < SCAN_ATTEMPTS:
                print("  Not found yet, retrying in 2s...")
                await asyncio.sleep(2)

    if not device:
        print("\n[ERROR] Device not found after all scan attempts.")
        print("  Troubleshooting tips:")
        print("  1. Check Serial Monitor — does it show '[BLE] Advertising as XIAO_Camera'?")
        print("  2. Toggle Bluetooth OFF then ON in Windows settings")
        print("  3. Connect directly by MAC:  python receive_photo_v2.py --address AA:BB:CC:DD:EE:FF")
        print("  4. Try the v1 receiver:      python receive_photo.py")
        return

    if hasattr(device, 'address'):
        print(f"Found: {device.name} ({device.address})")

    async with BleakClient(device) as client:
        print(f"Connected! (MTU: {client.mtu_size})")

        await client.start_notify(DATA_CHAR, handle_data_notification)
        await client.start_notify(CONTROL_CHAR, handle_control_notification)

        # Set initial profile
        print(f"\nSetting profile to {args.profile} ({PROFILE_NAMES[args.profile]})...")
        await set_profile(client, args.profile)

        target_name = "iCan Eye"
        target_address = None
        target_device = None

        if args.once:
            # Single capture mode
            for attempt in range(1, MAX_RETRIES + 2):
                if attempt > 1:
                    print(f"\n--- Retry {attempt - 1}/{MAX_RETRIES} ---")
                if await capture_once(client):
                    break
                elif attempt <= MAX_RETRIES:
                    await asyncio.sleep(2)
        else:
            # Interactive mode
            print("\n" + "-" * 55)
            print("  Interactive Mode")
            print("  Commands:  [Enter]=capture  0-3=change profile  q=quit")
            print("-" * 55)

            while True:
                try:
                    user_input = await asyncio.get_event_loop().run_in_executor(
                        None, lambda: input("\n> ").strip().lower()
                    )
                except (EOFError, KeyboardInterrupt):
                    break

                if user_input in ("q", "quit", "exit"):
                    break
                elif user_input in ("0", "1", "2", "3"):
                    new_profile = int(user_input)
                    print(f"  Switching to {PROFILE_NAMES[new_profile]}...")
                    await set_profile(client, new_profile)
                elif user_input == "" or user_input == "c":
                    for attempt in range(1, MAX_RETRIES + 2):
                        if attempt > 1:
                            print(f"\n--- Retry {attempt - 1}/{MAX_RETRIES} ---")
                        if await capture_once(client):
                            break
                        elif attempt <= MAX_RETRIES:
                            await asyncio.sleep(2)
                elif user_input == "?":
                    print("  Commands:  [Enter]=capture  0-3=change profile  q=quit")
                else:
                    print("  Unknown command. Type ? for help.")

        await client.stop_notify(DATA_CHAR)
        await client.stop_notify(CONTROL_CHAR)

    print("\nDone.")


if __name__ == "__main__":
    asyncio.run(main())
