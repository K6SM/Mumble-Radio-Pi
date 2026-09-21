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
- [Latency and power](#latency-and-power)
- [Running the script again](#running-the-script-again)
- [Security](#security)
- [When it does not work](#when-it-does-not-work)
- [What the script changes](#what-the-script-changes)
- [What this does not do](#what-this-does-not-do)

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

It takes fifteen to forty minutes, most of it `apt` fetching Mumble. It
installs Hamlib first, then asks its questions, then installs the rest, so the
questions come early and the long wait is unattended.

Answers are saved in `/etc/ham-radio-pi/setup.conf`. Every file it replaces is
copied to `/etc/ham-radio-pi/backups/` first.

| Option | |
| --- | --- |
| `--unattended` | Ask nothing; use the saved answers. For re-running after a software upgrade. |
| `--reset-password` | Put the login password back to the documented default. |
| `--skip-apt` | Change no packages; only rewrite the configuration and restart the services. |

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
| Journal in RAM | | The journal is the steadiest writer on an idle station, and each flush spins the card up. `journalctl` still shows the current boot; it starts empty after a reboot. |
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

is the whole upgrade procedure. `--unattended` uses the answers saved last
time; leave it off to be asked again, with your previous answers as the
defaults.

Two things a re-run does **not** do:

- It does not reset your login password. Use `--reset-password` for that.
- It does not regenerate the Mumble certificate or the SuperUser password.

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
| `Unknown PCM` and `snd_pcm_open(...): No such file or directory` | The device name in `Mumble.conf` must be **quoted** &mdash; see below. |
| `ALSA lib ... cannot open` | The capture or playback device in `Mumble.conf` is not what `arecord -l` lists. |

When it works, it prints nothing much and stays running. Stop it with `C-c`
and `sudo systemctl start mumble-radio`.

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
~/.config/Mumble/Mumble.conf                  the radio-end client
~/Documents/MumbleAutomaticCertificateBackup.p12
```

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
`mumble-server`, `rigctld`, `mumble-radio`.

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

---

For the operator's end, see the `ham.el` README, in particular *Operating
remotely*, and `M-x ham-remote-show-mumble-setup`.
