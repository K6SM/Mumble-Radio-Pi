# The radio-end Raspberry Pi

`radio-pi-setup.sh` turns a Raspberry Pi into the computer that sits at the
radio in a remote station. It installs and configures three things, and
arranges for all three to be running by the time the Pi has finished booting:

| | |
| --- | --- |
| **`rigctld`** | Hamlib's rig control daemon, driving the transceiver you pick from the list of radios your Hamlib supports. This is what `ham-rig` and the QSO logger talk to. |
| **Mumble server** | The meeting point for the audio, tuned for a radio link rather than for a chat room. |
| **Mumble client** | The radio's own client: its microphone is the receiver, its speaker is the transmitter's audio input, and it transmits continuously because there is nobody there to key it. |

Nothing else has to be running. Emacs at the operator's end connects to the
first and joins the second; the Pi does its job whether or not anyone is
logged into it.

```
   your desk                              the radio
  ┌──────────────┐                      ┌────────────────────────────┐
  │ Mumble       │ ◄──── audio ───────► │ Mumble client  (continuous)│
  │ client       │      port 64738      │   in  = receiver audio     │
  │ (headset)    │                      │   out = transmitter audio  │
  │              │                      │                            │
  │ Emacs        │ ◄─── rig control ──► │ rigctld        port 4532   │
  │ ham-rig      │                      │                            │
  │ ham-remote   │                      │ Mumble server  port 64738  │
  └──────────────┘                      └────────────────────────────┘
                                          Raspberry Pi, console only
```

The Pi is also left set up as a machine you can sit down at: plug in a screen
and a keyboard and you get a terminal, with Emacs and the K6SM packages on it
if you asked for them, logging through the same `rigctld` the remote operator
uses.

## Contents

- [What you need](#what-you-need)
- [Before you run the script](#before-you-run-the-script)
- [Running the script](#running-the-script)
- [What it asks](#what-it-asks)
- [The default password](#the-default-password)
- [Setting up the operator's end](#setting-up-the-operators-end)
- [Checking it works](#checking-it-works)
- [Setting the audio levels](#setting-the-audio-levels)
- [Using the Pi at the radio](#using-the-pi-at-the-radio)
- [Hamlib, built from source](#hamlib-built-from-source)
- [Keeping the Wi-Fi up](#keeping-the-wi-fi-up)
- [Latency and power](#latency-and-power)
- [Running the script again](#running-the-script-again)
- [Security](#security)
- [When it does not work](#when-it-does-not-work)
- [What the script changes](#what-the-script-changes)
- [What this does not do](#what-this-does-not-do)
- [Versions](#versions)

## What you need

**A Raspberry Pi.** A Zero 2W is enough and is what the settings here are
tuned for: the Mumble server forwards packets rather than mixing or
transcoding them, so its load is networking and crypto, not audio work. A Pi
3, 4 or 5 has more room and runs everything the same way.

**Raspberry Pi OS Lite**, 64-bit, Bookworm or later. The Lite image, not the
desktop one. The script switches a desktop image to console mode and turns off
the login manager, but on a Zero 2W's 512MB the desktop image's leftovers are
memory you would rather give to Mumble.

**An SD card of 8GB or more.** Mumble brings its Qt libraries with it, which
want about 1GB.

**A sound device at the radio.** Most modern transceivers present a USB sound
device that is both the receiver output and the transmitter input. Otherwise
an interface such as a SignaLink sits between the Pi and the radio.

**A CAT connection.** Usually the same USB cable, or a separate USB serial
adapter.

**A network the Pi can reach and you can reach.** Your own LAN, or a VPN. See
[Security](#security) before you put any of this on the open internet.

## Before you run the script

1. **Write the image** with Raspberry Pi Imager. In its settings, set the
   hostname to `radio`, enable SSH, and create the first user. If you name
   that user `radio` the script will use it; if you let the script create the
   account instead, it gets the password in
   [The default password](#the-default-password).

2. **Wire the radio up and switch it on** before running the script. It needs
   to see the serial port and the sound card to offer them to you, and it
   reads the radio's frequency at the end to prove the whole chain works.

3. **Get onto the Pi**, over SSH or on a screen and keyboard:

   ```
   ssh radio@radio.local
   ```

4. **Put the script on it and run it.** It asks questions, so give it a file
   rather than piping it from `curl`:

   ```
   sudo bash radio-pi-setup.sh
   ```

## Running the script

The first run is long: Hamlib is compiled from source, which on a Pi Zero 2W
takes three-quarters of an hour or more, and then `apt` fetches Mumble. Hamlib has
to come first, because the list of radios the script offers is that Hamlib's
own list, so the questions come after the build. Once you have answered them
the rest runs unattended. A re-run skips the build unless Hamlib has
published a new stable release since.

Answers are saved in `/etc/ham-radio-pi/setup.conf`. Every file it replaces is
copied to `/etc/ham-radio-pi/backups/` first.

**Every run is logged**, in full, to
`/var/log/ham-radio-pi/setup-<date>-<time>.log`; the newest twenty are kept. The
last line of every run names its log. You do not need `tee`.

**However a run ends, it says how.**

| It ends with | Meaning |
| --- | --- |
| `Ready.` | It finished, and every check passed. |
| `Some checks did not pass` | It finished; the `!` lines above say which. |
| `Error: ...` | It stopped for a reason it understood, and says what to do. |
| `Stopped: line N failed ...` | A command failed that it did not expect to. Nothing after that point was done. Send the log. |
| `Interrupted.` | You pressed Ctrl-C. Everything it does is safe to repeat, so run it again to finish. |

A Ctrl-C during the Hamlib build leaves the Hamlib already installed exactly
as it was; the new one only replaces it at the very end of a successful build.

**A dropped SSH connection does not stop it.** The run, and a Hamlib build in
it, carries on to the end, and the log records how it went; reconnect and look
at the newest file in `/var/log/ham-radio-pi/`. `tmux` is still the more
comfortable way to run it (`sudo apt install tmux`, then `tmux new -s setup`,
and `tmux attach -t setup` after reconnecting), because it also gives you the
screen back.

**Which version is this?**

```
head -2 radio-pi-setup.sh              # radio-pi-setup.sh  version 0.5.1
sudo bash radio-pi-setup.sh --version
sudo grep LAST_SETUP_VERSION /etc/ham-radio-pi/setup.conf   # which version last ran
```

| Option | |
| --- | --- |
| `--unattended` | Ask nothing; use the saved answers. For re-running after a software upgrade. |
| `--reset-password` | Put the login password back to the documented default. |
| `--skip-apt` | Change no packages and build nothing; only rewrite the configuration and restart the services. |
| `--rebuild-hamlib` | Build Hamlib again even though the wanted version is installed. |
| `--version` | Print the script's version and stop. |

## What it asks

**The station.** The hostname, which becomes the name the Pi answers to on the
network — `radio` gives you `radio.local`, which is what `ham-remote`'s
default configuration looks for. And the login account for the operator.

**The radio.** Type part of a maker or model — `FTDX10`, `IC-7300`,
`Elecraft` — and pick from what matches. Every radio your Hamlib build
supports is in the list, which is the same list `rigctl -l` prints. If you
already know the Hamlib model number, type it. Model 1 is Hamlib's dummy
radio, if you want to set the station up before the radio arrives.

Then the serial port. Prefer the `/dev/serial/by-id/...` name the script
offers: it names the adapter itself, so it still points at the radio after a
reboot or after something else is plugged into another USB socket.
`/dev/ttyUSB0` is whichever adapter enumerated first that time.

Serial speed can usually be left blank, which lets the Hamlib backend use the
radio's own default. Set it if you have changed the speed in the radio's menu.
The CI-V address matters only for Icom radios sharing a bus, and PTT type only
if the radio does not key over CAT.

**Where `rigctld` can be reached from.** This is the one answer worth
thinking about:

| | |
| --- | --- |
| `localhost` | Only from the Pi itself. The operator reaches it through an SSH tunnel or a VPN. **This is the default and the safe answer.** |
| `lan` | From anywhere that can route to the Pi. |

`rigctld` has no password and no encryption of any kind. Anyone who can reach
its port can key your transmitter.

**Audio.** The capture device is what the receiver's audio goes into; the
playback device is what feeds the transmitter. The script lists the sound
cards it can see and writes the choice as a `plughw:CARD=...` name, which
survives the cards being numbered differently after a reboot.

**Mumble.** Port, how many clients to admit, the bandwidth ceiling, and the
name the radio end joins under. Leave the server password blank on a home LAN
or behind a VPN.

**Keeping the Wi-Fi up.** Whether to run the Wi-Fi watchdog, and whether it
may reboot as a last resort. Both default to yes; see
[Keeping the Wi-Fi up](#keeping-the-wi-fi-up).

**Power and latency.** Covered in [Latency and power](#latency-and-power).
The defaults are: Wi-Fi power saving off, `ondemand` governor, screen blanking
after five minutes, Bluetooth off, LEDs off, automatic login on an attached
screen.

**Emacs.** Whether to install the terminal build, and whether to fetch the
K6SM `ham.el` and QSO logger packages from GitHub.

## The default password

When the script creates the login account itself, it sets the password to:

> **`ChangeMe73`**

with the account name you chose, `radio` by default. So:

```
ssh radio@radio.local
```

with password `ChangeMe73`.

**This password is printed here, so everybody has it.** It exists to get you
onto a machine that has never been logged into, and nothing else. Change it
the first time you log in:

```
ssh radio@radio.local
passwd
```

`passwd` asks for the current password, then twice for the new one.

Two things to know about it:

- **The script does not touch the password of an account that already
  exists.** If you created the user in Raspberry Pi Imager, or you have
  already changed it, your password stands — including when you re-run the
  script. Only `--reset-password` puts it back, and only when you ask.
- The summary the script prints at the end says which of these happened.

Once you are in, SSH keys are better than any password. From the machine you
operate from:

```
ssh-copy-id radio@radio.local
```

and then, on the Pi, turn passwords off altogether:

```
sudoedit /etc/ssh/sshd_config.d/99-ham-radio-pi.conf
```

change `PasswordAuthentication yes` to `no`, and `sudo systemctl reload ssh`.
Do this only once you have confirmed the key works, in a second terminal you
keep open.

There is also a **Mumble SuperUser password**, generated at random and saved
in `/etc/ham-radio-pi/mumble-superuser-password`, readable only by root. You
need it only if you want to administer the Mumble server from inside a client.

```
sudo cat /etc/ham-radio-pi/mumble-superuser-password
```

## Setting up the operator's end

The script prints this at the end, filled in with your answers:

```elisp
(setq ham-remote-host "radio.local"
      ham-remote-transport "mumble"
      ham-remote-mumble-user "K6SM"      ; your callsign, not "radio"
      ham-remote-mumble-port 64738
      ham-remote-mumble-run 'client
      ham-rig-host "radio.local"
      ham-rig-port 4532)
```

The Mumble name must differ from the radio end's, or the two clients collide
on the server. Your callsign is the useful thing to put there.

`ham-remote-mumble-run` stays `client` at your end: the server is on the Pi
and is started by the Pi, which is the point of having one.

**If you left `rigctld` on localhost**, tunnel it from the machine you operate
from:

```
ssh -N -L 4532:127.0.0.1:4532 radio@radio.local
```

and set `ham-rig-host` to `"127.0.0.1"`. Leave that running while you operate.
A VPN is better if you do this often; see [Security](#security).

**Your own Mumble client** still needs setting up by hand, once —
`ham-remote` cannot reach into Mumble's settings. `M` in the `ham-remote`
panel, or `M-x ham-remote-show-mumble-setup`, lists them. The ones that
matter:

| Setting | Value |
| --- | --- |
| Echo cancellation | off |
| Noise suppression | off |
| Amplification | minimum |
| Transmit | Push To Talk |
| Audio per packet | 10 ms |
| Quality | 72 kb/s |
| Jitter buffer | 20 ms, then raise if the audio breaks up |
| Text to speech, sounds | off |

Push To Talk is not optional: it is what lets `ham-remote-mumble-follow-ptt`
hold your microphone closed except while the rig is keyed. The panel's `MIC`
line shows whether it is working.

The radio end already has the equivalent of all of these — the script wrote
them — except that it transmits continuously instead of on PTT.

## Checking it works

The script runs these itself and reports what it found. To run them again
later:

```
systemctl status rigctld mumble-server mumble-radio
```

All three should say `active (running)`.

```
rigctl -m 2 -r 127.0.0.1:4532 f
```

should print the frequency the radio is on, in Hz. Model 2 is "NET rigctl":
this is `rigctl` talking to `rigctld` over the network, exactly as Emacs does.
If this works, rig control works.

```
ss -lntu | grep 64738
```

should show the Mumble server listening on both TCP and UDP.

Then, from the operator's end:

1. `M-x ham-remote`, then `s`. The panel should show `Mumble running`.
2. You should hear the band. If not, the trouble is at the radio end's input.
3. `M-x ham-rig`, connect, and key with `t`. `MIC` should go from `shut` to
   `open` and the radio should transmit your voice.
4. Unkey. `MIC` goes back to `shut`.

## Setting the audio levels

Two levels, and one of them can put a bad signal on the air.

**Receiver into the Pi.** On the Pi:

```
alsamixer -c 1        # or whichever card number the radio is
```

`F4` shows the capture controls. Bring the level up until normal signals are
well clear of the noise but strong ones do not reach the top. Mumble's
automatic gain control cannot be switched off, only held to unity gain, which
is what the script does — so what ALSA captures is what crosses the link, and
setting it here is the only place it gets set.

**Pi into the transmitter.** Set this with the rig's ALC meter, not by ear.
Bring the playback level up in `alsamixer` until ALC just begins to move, and
stop there. More is not louder at the far end; it is distortion.

`sudo alsactl store` saves the mixer settings so they survive a reboot.

## Using the Pi at the radio

Plug in a screen and a USB keyboard. The Pi boots to a text console — there is
no desktop, and the script disabled the login manager if the image had one.

If you left automatic login on, you get a shell without typing anything. If
not, log in as usual.

```
emacs
```

opens Emacs in the terminal. If you asked the script to fetch the K6SM
packages, `M-x ham-rig` and `M-x qso-log-form` are ready, already pointed at
this Pi's own `rigctld` on `127.0.0.1:4532` — which works whichever way you
answered the "reachable from" question, because that answer only governs the
network.

So the same station logs locally at the radio and remotely from the house,
through the same `rigctld`, with no change to anything. Hamlib is why: one
daemon owns the serial port and everything else shares it.

The screen blanks after five minutes and comes back on a keypress. That is
power saving, not a screensaver; nothing is logged out.

## Hamlib, built from source

The Pi runs **the latest stable release of Hamlib on GitHub**
(<https://github.com/Hamlib/Hamlib>), built from source, rather than Debian's,
which lags by years: Bookworm ships 4.5.4, and fixes in `rigctld` and in
individual radio backends since then are exactly what `ham-rig` runs into.

**The version is looked up when the script runs**, not written into it.
GitHub's "latest release" is the newest release that is neither a draft nor a
pre-release, which is what stable means here. So:

- the first run builds whatever that is today;
- a re-run after Hamlib publishes a new release builds the new one;
- a re-run with no new release does nothing.

The summary says which it did:

```
   Hamlib       4.7.2 -- latest stable release on GitHub
```

**If GitHub cannot be reached** &mdash; which, given this station's Wi-Fi, is
worth planning for &mdash; the script keeps the Hamlib already installed, says
so, and carries on. A station that works is never broken by an upgrade that
could not happen. Only a first run, with no Hamlib yet, has to stop.

**Checking what is downloaded.** The script cannot hold a checksum for a
release that did not exist when it was written. Instead it compares the
tarball from GitHub with the copy Hamlib publishes separately on SourceForge:
two independent hosts serving identical bytes is good evidence neither has
been tampered with, and if they differ nothing is built. Releases already
checked by hand (4.7.2 is) are also compared against their known checksum. A
release too new to have reached SourceForge is built from the GitHub copy,
fetched over HTTPS from the repository above, with a warning saying so.

It goes into `/usr/local`, and `rigctld` is linked with a run path to its own
library. That matters: Debian's `libhamlib.so.4` and ours have the same name,
and without the run path the dynamic linker's search order, not you, would
decide which one `rigctld` loaded. The script checks, after building, that it
loads its own.

Once the build works, Debian's `libhamlib-utils` is removed so there is one
`rigctld` on the machine, not two. Debian's library stays only if something
else needs it &mdash; fldigi or WSJT-X, say &mdash; which is harmless, since our
`rigctld` does not use it.

```
rigctld --version                              # the version built
ldd /usr/local/bin/rigctld | grep hamlib       # /usr/local/lib/libhamlib.so.4
```

**Model numbers do not change** between Hamlib versions: the FTDX-10 is 1042
in 4.5.4 and in 4.7.2, so a station keeps its saved answers across upgrades.

**To stay on one version** instead of following new releases, name it in
`/etc/ham-radio-pi/setup.conf`:

```
HAMLIB_VERSION="4.7.2"
```

and, optionally, the tarball's checksum as `HAMLIB_SHA256`. Set it back to
`"latest"` to follow releases again.

**Upgrading is deliberate.** Nothing checks for new Hamlib releases in the
background, and `apt upgrade` never touches this Hamlib: a new release is
built when you re-run the script. That is on purpose &mdash; a build takes up
three-quarters of an hour or more on a Zero 2W and ends by restarting `rigctld`,
which is not something to have happen in the middle of a contact.

**The build and memory.** On a Zero 2W it is memory, not the processor, that
limits the build. The script stops the radio's Mumble client for the length of
the build, which frees the most, and runs one compile per 170 MB free: measured
on 4.7.2, 458 of its 469 compiles need under 60 MB, and the heaviest &mdash; the
Yaesu backend, `newcat.c` &mdash; peaks at 170 MB. The client is started again
afterwards, or when the run ends if it ends early. The summary reports how long
the build took.

If a build fails, the script stops and names the log
(`/usr/local/src/hamlib/build-<version>.log`); nothing is removed, so a
`rigctld` that worked before still does.

## Keeping the Wi-Fi up

A station you cannot walk over to has to put its own network back. The Wi-Fi
watchdog, `ham-radio-pi-wifiwatch`, checks every twenty seconds that the Pi is
really on the network: that the interface exists, is joined to a network, has
an address, and that the router answers. After a minute of failures it treats
it as an outage and does two things, **in this order**:

1. **It writes down the evidence, before touching anything.** Recovering
   destroys most of it &mdash; reloading the driver clears the kernel's own
   account &mdash; so the kernel log, NetworkManager's log, the link and
   address state, the power supply flags, and a scan of which networks are
   still visible all go to one file per outage in
   `/var/log/ham-radio-pi/wifi-incidents/`.

2. **It recovers, in escalating steps, stopping at the first that works:**

   | Step | What it does |
   | --- | --- |
   | reassociate | Asks NetworkManager to rejoin |
   | restart-interface | Turns the Wi-Fi radio off and on |
   | reload-driver | Unloads and reloads the Wi-Fi driver, restarting its firmware |
   | reboot | Last resort: at most three times a day, never in the first half hour after a boot |

**Which step worked is the diagnosis.** After a few outages:

```
sudo ham-radio-pi-wifiwatch --report
```

counts them by what failed and by what fixed it:

| It says | Meaning |
| --- | --- |
| `not-associated`, fixed by `reassociate` | NetworkManager had stopped trying, or the router dropped the Pi and it did not rejoin by itself |
| `not-associated`, fixed by `reload-driver` | The Wi-Fi firmware had stopped |
| `no-interface` | The driver or its firmware crashed and took the interface with it |
| `no-address` | It joined the network but DHCP gave it no address: look at the router |
| `gateway-silent` | Joined, with an address, but traffic stopped: firmware or interference |

Each evidence file opens with the kernel's messages at the moment it failed.
`brcmfmac` is the Pi's Wi-Fi driver; lines from it just before the failure are
the ones to read.

**NetworkManager is also told never to give up.** By default it tries a
failing Wi-Fi connection four times and then stops for good, until something
outside it intervenes &mdash; on an unattended machine, the difference between
a thirty-second drop and a station that is gone until someone visits. The
script sets `autoconnect-retries` to zero, meaning for ever, on every Wi-Fi
connection. If your outages were that, they stop; any that remain are
something else, and the watchdog's report will say what.

To turn the watchdog off, answer no when the script asks, or set
`WIFI_WATCHDOG="no"` in `/etc/ham-radio-pi/setup.conf` and re-run.
`WIFI_WATCHDOG_REBOOT="no"` keeps it but forbids the reboot.

## Latency and power

The brief for these settings is: as little latency as the hardware allows,
and past that, as little current as possible. Where the two conflict, latency
wins, because a link that stutters is not usable and a battery that lasts nine
hours instead of eleven is.

Everything here is a choice you can change. The audio settings live in
`/etc/ham-radio-pi/setup.conf` and the Mumble configuration files; the system
settings are listed in [What the script changes](#what-the-script-changes).

### For latency

| Setting | | |
| --- | --- | --- |
| Audio per packet | 10 ms | The main latency control. Halving it again would double the packet rate for 5 ms. |
| Opus, forced | `opusthreshold=0` | One old client otherwise drops the whole server to CELT, which costs more CPU and sounds worse. On a Zero 2W that is the difference between working and not. |
| Quality 72 kb/s | | Mumble's ceiling, and at or above 64 kb/s Opus uses its low delay mode. |
| Jitter buffer | 20 ms | The one number to raise if audio breaks up. Jitter breaks audio; latency alone does not. |
| ALSA directly | | No PulseAudio, no PipeWire: one less buffer, one less process to schedule, and less current. |
| Wi-Fi power saving off | | The big one. Power saving parks the radio between packets and costs tens of milliseconds, unpredictably, on the first packet of a transmission. |
| `ondemand`, ramped early | `up_threshold=50` | The cores idle down between overs and come back up within milliseconds of the audio thread asking for work. |
| `Nice=-5` | | `rigctld` and the Mumble client get scheduled ahead of everything else, which costs nothing while the board is idle. |

### For power

| Setting | | |
| --- | --- | --- |
| Console only | | No desktop, no login manager, no compositor. |
| Screen blanking | 300 s | An attached monitor powers down and comes back on a keypress. |
| Bluetooth off | | Say no to this if your keyboard is Bluetooth. |
| Activity LEDs off | | A few milliamps, and the Pi is in a shack, not on a desk. |
| Journal, capped and batched | 64 MB, synced every 5 min | The journal is kept on disk so that a fault which stops the machine leaves its account behind (`journalctl -b -1`), but capped, and written in batches rather than line by line. `JOURNAL_STORAGE="volatile"` in `setup.conf` puts it back in RAM, sparing the card at the cost of losing it at every reboot. |
| Later, fewer disk writes | `dirty_writeback_centisecs` | Same reason. |
| Automatic updates off | | `apt` timers fire at unpredictable times, which is both current and a CPU spike in the middle of a contact. Update by hand; see below. |
| Onboard audio off | | Unless you chose it as the radio's sound device. |

**Not** done, deliberately: the CPU is not underclocked and the maximum clock
is not capped. Mumble's Opus encoding on a Zero 2W needs the headroom, and a
board that has to run at its ceiling for longer to finish the same work saves
nothing.

### If battery life matters more than latency

Re-run the script and answer `on` to Wi-Fi power saving, or edit
`/etc/ham-radio-pi/setup.conf` and re-run with `--unattended`. Expect the
first syllable after an over to be late sometimes. The `powersave` governor is
the other lever, and costs more than it is worth on a board this small.

## Running the script again

It is meant to be run again. Everything it does it checks first: packages are
installed only if missing, files are written only when the contents would
differ, service files are replaced rather than added to, and configuration
keys are set rather than appended, so nothing ends up in a file twice.

```
sudo apt update && sudo apt full-upgrade
sudo bash radio-pi-setup.sh --unattended
sudo reboot
```

is the whole upgrade procedure, Hamlib included: if a new stable Hamlib has
been released, this is when it is built. `--unattended` uses the answers saved last
time; leave it off to be asked again, with your previous answers as the
defaults.

Two things a re-run does **not** do:

- It does not reset your login password. Use `--reset-password` for that.
- It does not regenerate the Mumble certificate or the SuperUser password.
- It does not rebuild Hamlib unless there is a new stable release on GitHub
  (or you pass `--rebuild-hamlib`).

One thing it **does** overwrite: the radio-end Mumble client's configuration,
`~/.config/Mumble/Mumble.conf`. Those settings are the station's, not yours;
change them through `/etc/ham-radio-pi/setup.conf` and a re-run rather than by
editing the file, or your edits will go the next time you run it.

Because automatic updates are off, updating is something you do. Doing it
deliberately, with a re-run after it and a listen on the band, is better for a
station that has to work than waking up to a Mumble that changed its audio
defaults overnight.

## Security

Three things on this Pi are reachable over the network, and they are not
equally safe.

| | |
| --- | --- |
| **SSH**, port 22 | Fine to expose, once the default password is gone and preferably with keys only. |
| **Mumble**, port 64738 TCP and UDP | Encrypted, authenticates by certificate. Set a server password before exposing it. |
| **`rigctld`**, port 4532 | **No authentication and no encryption whatsoever.** Anyone who reaches it can key your transmitter, on any frequency the radio will accept. |

So: **do not forward port 4532 from the internet.** The script defaults to
binding it to localhost for this reason.

The right arrangement for a station that is not in your own house is a VPN —
WireGuard suits it better than SSH, whose forwarding is built for TCP while
Mumble's audio is UDP. Put both machines on the VPN, answer `lan` to the
"reachable from" question, and forward nothing at all on the router.

If you do forward Mumble's port, forward **both** TCP and UDP. TCP carries the
control connection and UDP the voice; with UDP blocked Mumble still works but
routes voice over TCP, which is noticeably worse.

The FCC's rules about control of a remotely operated station are yours to
satisfy, and no configuration file satisfies them. You must be able to shut
the transmitter down.

## When it does not work

| Symptom | Usually |
| --- | --- |
| `rigctld` running, radio does not answer | Radio off, wrong serial speed, or the radio's CAT menu set to something else than the Hamlib model expects. `journalctl -u rigctld -n 40`. |
| `rigctld` fails at boot but works by hand | The serial adapter had not enumerated yet. Use the `/dev/serial/by-id/...` name and re-run the script. |
| Mumble client runs but never connects | Usually a missing Qt library: `sudo apt install --reinstall mumble`. See below &mdash; this one looks like nothing at all is wrong. |
| Mumble client restarts over and over | Its sound device is missing or taken. `journalctl -u mumble-radio -n 40`. Check `arecord -l` still lists the card, and that nothing else has it open. |
| No audio either way | The server is not reachable: check port 64738 **TCP and UDP**. |
| Audio breaks up | Raise the jitter buffer 10 ms at a time, at the receiving end. |
| Everything sounds far away and thin | Noise suppression or AGC still on, at the *operator's* end — the radio end's is already off. |
| Weak signals vanish into silence | Noise suppression, same place. |
| Delay grows the longer you talk | Buffering somewhere; restart the client. |
| `MIC open` with the rig unkeyed | Your Mumble is not in Push To Talk mode. |
| First syllable clipped | Same: voice activation instead of Push To Talk. |
| Hum on transmit | A ground loop. That wants an isolating interface, not a software fix. |
| Everything worked, then the Pi got slow | Check free memory. On a Zero 2W, Mumble, Xvfb and Emacs together are most of 512MB. |

### The radio-end client is the part that hides its failures

Everything else here either works or says why. The Mumble client is a
graphical program running where nothing can draw, so its failures are silent:
`systemctl` reports it `active (running)` whether it is carrying audio, sitting
on a dialog nobody can see, or about to exit. The script's own check therefore
waits for the client's connection to appear on the server rather than trusting
`active`, and prints the log if it does not.

To see what it is really doing, stop the service and run the same command in
the foreground, where it prints its errors to your terminal:

```
sudo systemctl stop mumble-radio
grep ExecStart= /etc/systemd/system/mumble-radio.service
sudo -u radio HOME=/home/radio <the ExecStart line, without "ExecStart=">
```

What you are likely to see:

| It says | It means |
| --- | --- |
| `Could not load the Qt platform plugin "xcb"` | A library Mumble's display code needs is missing. `sudo apt install --reinstall mumble`, which pulls the recommended packages a lean install leaves out. |
| `Cannot open display` / `Xvfb failed` | `sudo apt install xvfb`, or set `MUMBLE_DISPLAY="offscreen"` in `/etc/ham-radio-pi/setup.conf` and re-run. |
| Nothing at all, and it does not exit | It is stopped on a wizard. Check `lastupdate=5` is in `~/.config/Mumble/Mumble.conf` and that `~/Documents/MumbleAutomaticCertificateBackup.p12` exists. |
| `Server connection failed` or a rejected name | The server is not up yet, or the name clashes with your own client's. They must differ. |
| Nothing at all after `ServerHandler: TLS cipher preference` | It is stopped on a dialog nobody can see &mdash; the certificate one, or the password one. Both are below. The server's own log says which. |
| `Unknown PCM` and `snd_pcm_open(...): No such file or directory` | The device name in `Mumble.conf` must be **quoted** &mdash; see below. |
| `ALSA lib ... cannot open` | The capture or playback device in `Mumble.conf` is not what `arecord -l` lists. |

When it works, it prints nothing much and stays running. Stop it with `C-c`
and `sudo systemctl start mumble-radio`.

### Trusting the server's certificate

A Mumble server generates its own certificate, and no authority has signed it.
A client meeting it for the first time raises a modal dialog asking whether to
trust it. At your desk you click yes. At the radio there is nobody to click,
and the dialog opens on a display that exists only inside Xvfb, so Mumble waits
on it **forever**.

From outside, all you see is a client that runs, costs no CPU, logs no error
and never appears on the server. The last line in its log is
`ServerHandler: TLS cipher preference is ...` and then nothing. That silence is
the dialog.

The script prevents it by storing the server's certificate digest in Mumble's
own database before the client first runs &mdash; which is what a client that
has already accepted a certificate holds, and what makes Mumble skip the
question. By hand:

```
sudo apt install sqlite3
DIGEST=$(echo | openssl s_client -connect 127.0.0.1:64738 2>/dev/null \
         | openssl x509 -outform DER | sha1sum | awk '{print $1}')

sudo systemctl stop mumble-radio
DB=$(sudo find /home/radio -name 'mumble.sqlite' -o -name '.mumble.sqlite' | head -1)
sudo -u radio sqlite3 "$DB" \
  "CREATE TABLE IF NOT EXISTS cert (id INTEGER PRIMARY KEY AUTOINCREMENT,
     hostname TEXT, port INTEGER, digest TEXT);
   CREATE UNIQUE INDEX IF NOT EXISTS cert_host_port ON cert(hostname,port);
   REPLACE INTO cert (hostname,port,digest) VALUES ('127.0.0.1',64738,'$DIGEST');"
sudo systemctl start mumble-radio
```

The digest is the SHA-1 of the DER form of the certificate, lower case hex,
which is what Mumble compares against.

**Find that database, do not predict it.** Mumble tries its base path, then
Qt's `DataLocation`, then `~/.config/Mumble`, then the home directory, and
uses the first that already holds one. Qt's `DataLocation` is
`<organization>/<application>` and Mumble sets both to "Mumble", so the usual
answer is:

```
~/.local/share/Mumble/Mumble/mumble.sqlite
```

&mdash; one level deeper than it looks. Writing to
`~/.local/share/Mumble/mumble.sqlite` instead creates a second database that
Mumble never opens, and every step of the work reports success while the
client goes on refusing the certificate. The script writes to every
`mumble.sqlite` it can find under the account's home directory for this
reason, and then asks the running client, through `/proc/<pid>/fd`, which
file it actually opened and whether that file holds the digest. Writing it
somewhere is not the same as writing it where the client reads it, and only
the second is worth reporting as success.

If an older run left a stray database the client does not read, it is inert
and can be deleted &mdash; `sudo find /home/radio -name 'mumble.sqlite'` lists
them, and the one the client has open is the one to keep.

Give the server a new certificate and the digest changes, at which point the
radio's client stops connecting until it is stored again. Re-running the script
does that for you.

### A server password, and the other invisible dialog

If you set a server password, the radio's client needs it too &mdash; and a
client that is refused for want of one raises a `QInputDialog` asking for it,
which on this machine nobody can answer. The symptom is identical to the
certificate one: a client that runs and never connects.

The script does **not** put the password in the `mumble://` URL, where every
process list on the machine would show it. It stores it in the client's own
database instead, in the `servers` table, which is where Mumble looks when the
URL carries no password (`Database::fuzzyMatch`).

So the two invisible dialogs have the same shape and the same cure: give the
client, in advance and in its database, the answer it would otherwise stop to
ask for.

### Never edit Mumble.conf while the client is running

Mumble writes its settings back out when it exits. `systemctl restart` stops
it first, so a restart **saves Mumble's in-memory settings over whatever you
just typed**, then reads back the file it has itself overwritten. Your edit
vanishes and nothing says so.

Always:

```
sudo systemctl stop mumble-radio
sudoedit /home/radio/.config/Mumble/Mumble.conf
sudo systemctl start mumble-radio
```

Stop, edit, start &mdash; never restart. The script does the same thing
internally, which is why it stops the service before writing the file.

### Commas in the ALSA device names

The device names are written without a device number:

```
[alsa]
input="plughw:CARD=CODEC"
output="plughw:CARD=CODEC"
```

ALSA defaults `DEV` to 0, so this is the same device as
`plughw:CARD=CODEC,DEV=0` &mdash; but it contains no comma, and a comma is the
one character that causes trouble here. Mumble reads its configuration with
Qt's `QSettings`, which treats an **unquoted comma as a list separator**. A
bare `plughw:CARD=CODEC,DEV=0` comes back as the two-item list
`plughw:CARD=CODEC` and `DEV=0`; Qt converts a list of more than one item to a
string by returning an **empty** string; and Mumble then calls
`snd_pcm_open("")`, which ALSA answers with `Unknown PCM` and no device name
after it.

A device that genuinely is not device 0 keeps its `,DEV=n` and is quoted, as
is `welcometext` in the server's ini. Anything in either file whose value
contains a comma needs quoting.

Two things in the log tell you this has happened:

```
ALSAAudioInput: Initing audiocapture .
ALSA lib pcm.c:(snd_pcm_open_noupdate) Unknown PCM
```

The gap between `audiocapture` and the full stop is where the device name
should be, and `Unknown PCM` has nothing after it. Both are printing an empty
string. If the name were merely wrong rather than empty, it would appear in
both lines &mdash; which is the quickest way to tell a quoting problem from a
genuinely mistaken card name.

The failure is quiet in a way worth knowing about: the client starts, connects
to the server, appears in the user list and reports no problem. It simply
carries silence in both directions, having no capture and no playback device.

### Ask the server, not the client

The client cannot tell you why it was refused &mdash; its own messages go to a
chat window that does not exist here. The server can, and it writes plainly to
a file:

```
sudo tail -40 /var/log/mumble-server/mumble-server.log
```

That log settles in one line what the client's log cannot:

| The server says | Meaning |
| --- | --- |
| `New connection: 127.0.0.1:...` then `Authenticated` | It connected. If you still hear nothing, the trouble is audio, not the link. |
| `New connection` then `Rejected` with a reason | The reason is the answer: a wrong password, a duplicate name, a full server. |
| `New connection: 127.0.0.1:...` then `Connection closed: The remote host closed the connection`, with no `Client version` between them | The client hung up during the handshake: it does not trust the certificate. The digest is missing, wrong, or in a database Mumble is not reading. |
| Nothing from 127.0.0.1 at all | The client never opened a connection &mdash; it is stopped before that, or aimed somewhere else. |

That last case is the one worth knowing: if the server never saw an attempt,
no amount of changing server settings will help.

To watch what the radio end is doing as it happens:

```
journalctl -fu mumble-radio
journalctl -fu rigctld
```

The journal is kept in RAM, so it covers this boot only.

## What the script changes

Everything it replaces is backed up to `/etc/ham-radio-pi/backups/` first,
with the first version kept as `.original`.

**Files it owns**, rewritten on every run:

```
/etc/ham-radio-pi/setup.conf                  your answers
/etc/systemd/system/rigctld.service
/etc/systemd/system/mumble-radio.service
/etc/systemd/system/ham-radio-pi-tuning.service
/usr/local/sbin/ham-radio-pi-tune             governor and Wi-Fi at boot
/etc/ssh/sshd_config.d/99-ham-radio-pi.conf
/etc/sysctl.d/99-ham-radio-pi.conf
/etc/systemd/journald.conf.d/99-ham-radio-pi.conf
/etc/NetworkManager/conf.d/99-ham-radio-pi.conf
/etc/systemd/system/getty@tty1.service.d/autologin.conf
/etc/ham-radio-pi/wifiwatch.conf              the watchdog's settings
/usr/local/sbin/ham-radio-pi-wifiwatch
/etc/systemd/system/ham-radio-pi-wifiwatch.service
~/.config/Mumble/Mumble.conf                  the radio-end client
~/Documents/MumbleAutomaticCertificateBackup.p12
```

**Installed from source**: Hamlib, under `/usr/local` (`bin/rigctld`,
`bin/rigctl`, `lib/libhamlib.so.4` and the rest), with the release tarball
kept in `/usr/local/src/hamlib/`.

**Written as it runs**: `/var/log/ham-radio-pi/wifi-watch.log` and one file
per outage in `/var/log/ham-radio-pi/wifi-incidents/`, the newest hundred kept.

**Settings it changes**: `autoconnect-retries` set to 0 on every Wi-Fi
connection NetworkManager knows about.

**Packages it removes**: Debian's `libhamlib-utils`, and `libhamlib4` if
nothing else uses it.

**Files it edits**, leaving the rest alone:

```
/etc/mumble-server.ini      individual keys set; the packaged paths kept
/boot/firmware/config.txt   one marked block appended
/boot/firmware/cmdline.txt  the consoleblank= token
/etc/hosts                  the 127.0.1.1 line, to match the hostname
```

**Services it turns off**, if they are there: the desktop login manager,
`triggerhappy`, `cups`, `ModemManager`, `packagekit`, Bluetooth if you said
so, and the `apt-daily`, `man-db` and `fstrim` timers.

**Services it makes sure are on**: `ssh`, `avahi-daemon` — which is what
answers to `radio.local`, and why it is not in the list above —
`mumble-server`, `rigctld`, `mumble-radio`, and `ham-radio-pi-wifiwatch`
if you asked for it.

To undo a piece of it: delete the marked block from `config.txt`, remove the
`99-ham-radio-pi` files, `systemctl disable --now` the three services, and
`systemctl enable` whatever you want back.

## What this does not do

**There is no transmit watchdog at the radio.** If the network dies while you
are transmitting, nothing at your end can unkey the radio. This is the same
gap CAT has always had, made likelier by a longer link.

**Enable the transceiver's own transmit timeout.** It is the only thing
standing between a dropped network and a transmitter keyed until someone walks
into the room.

**The Mumble client at the radio runs under a virtual display.** Mumble has no
headless mode — it is a graphical program with no command-line equivalent — so
the script runs it against Xvfb, generates its certificate with `openssl` in
advance so its certificate wizard never opens, and marks its configuration
as already-initialised so the audio wizard does not either. It works, and it
costs about 20MB of RAM. The `offscreen` option uses Qt's own headless
platform instead and saves most of that, at the cost of a path Mumble's
developers do not test.

**Mumble's automatic gain control cannot be turned off**, only held to unity
gain, which the script does. Set the capture level in `alsamixer`.

**Digital voice will not survive this link.** Mumble compresses with Opus,
which is built to model a human voice; a modulated waveform carrying data is
not one. `ham-remote-require-lossless` exists for that, and points at a
transport that does not compress.

**The script does not configure a firewall, a router, or a VPN.** See
[Security](#security).

## Versions

Each script carries its version on its second line, so `head -2` shows it,
and answers `--version`. Each is numbered separately from 0.5.1 on, and goes
up whenever that script changes.

| Script | Version |
| --- | --- |
| `radio-pi-setup.sh` | 0.5.1 |
| `ham-radio-pi-wifiwatch` (installed by setup) | 0.5.1 |
| `radio-pi-health.sh` | 0.5.1 |
| `radio-pi-diagnose.sh` | 0.5.1 |

### radio-pi-setup.sh 0.5.1

- **Fixed:** after removing Debian's `libhamlib-utils`, the run stopped
  without a word when nothing else needed Debian's `libhamlib4` &mdash; the
  usual case. It left Hamlib 4.7.2 built but the `rigctld` service still
  pointed at the removed `/usr/bin/rigctld`, and none of the later steps done.
- **Fixed:** the output "staircased" across the screen after the first
  package install, and could leave the terminal that way. apt no longer takes
  over the terminal, and the terminal's settings are restored at the end.
- **Fixed:** a Ctrl-C during the Hamlib build was reported as the build failing.
- New: a full log of every run in `/var/log/ham-radio-pi/`.
- New: any unexpected failure is reported with its line and command, instead
  of the run simply ending.
- New: a dropped SSH connection no longer stops a run.
- New: the Mumble client is stopped during the Hamlib build to free memory,
  and compiles run in parallel where memory allows (two on a Zero 2W instead
  of one), which should roughly halve the build.
- New: the version is on line 2, `--version` prints it, and `setup.conf`
  records which version last ran.

### Before 0.5.1

Earlier copies all said `VERSION="1.0"` and cannot be told apart. The last
of them (built Hamlib from source, following the latest stable release) is
0.5.0 here.

---

For the operator's end, see the `ham.el` README, in particular *Operating
remotely*, and `M-x ham-remote-show-mumble-setup`.
