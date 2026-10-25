# lgmon command line tool

Everything the menu bar app does, plus picture modes and on-screen notifications, from the terminal. Python 3.9+.

```bash
cd lgmon/cli && ./install.sh      # venv + `lgmon` in ~/.local/bin + pairing
```

```console
$ lgmon
brightness 60  volume 21  input hdmi1

$ lgmon brightness 40         # or +10 / -10, alias: lgmon b
$ lgmon volume +5             # alias: lgmon v
$ lgmon mute

$ lgmon input
  DisplayPort_1  PC
* HDMI_1         Mac          connected
  HDMI_2         PC
  USB-C_1        PC
$ lgmon input usbc            # hdmi1, hdmi2, dp, usbc, or the label

$ lgmon screen off            # panel off, audio keeps going
$ lgmon off                   # standby
$ lgmon on                    # Wake-on-LAN back from standby

$ lgmon app youtube           # list with `lgmon app`
$ lgmon mode                  # picture mode; `lgmon mode game` to change it
$ lgmon notify "Render done"  # toast on the monitor

$ lgmon discover              # find webOS devices on the network
$ lgmon use 192.168.1.50      # pin one if you have several
```

It shares `~/.config/lgmon/device.json` with the app. Environment: `LGMON_HOST` (fixed IP, skips discovery), `LGMON_CONFIG` (config folder). Remove with `./uninstall.sh`.

Built on [bscpylgtv](https://github.com/chros73/bscpylgtv).
