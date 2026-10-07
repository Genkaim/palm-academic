"""Burst-capture the device screen over DVT while the user drives the UI by hand.

Usage:
    python burst_shot.py <out_dir> <count> <interval_seconds>

Why this exists: pymobiledevice3 cannot synthesise taps on this device. The native
com.apple.mobile.screenshotr service is refused outright on iOS 27 beta
(InvalidServiceError), screenshots only work through the DVT instruments channel, and
DVT's condition inducers expose no tap/button profile. So the split is: the user
taps, this captures.

DVT is a developer service, so it needs a tunnel on iOS 17+. The CLI establishes a
no-root userspace tunnel implicitly (cli_common.default_transport_preference); a
standalone script has to open one itself, and only one per process (PyTCP's stack is
a process-global singleton).
"""
import asyncio
import sys
from pathlib import Path

from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot


async def main(out_dir: str, count: int, interval: float) -> None:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    async with UserspaceRsdTunnel(serial=None, autopair=True) as rsd:
        async with DvtProvider(rsd) as dvt, Screenshot(dvt) as screen:
            for i in range(1, count + 1):
                path = out / f"shot-{i:02d}.png"
                path.write_bytes(await screen.get_screenshot())
                print(f"{path}  {path.stat().st_size} bytes", flush=True)
                if i < count:
                    await asyncio.sleep(interval)


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], int(sys.argv[2]), float(sys.argv[3])))
