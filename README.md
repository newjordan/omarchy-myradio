# myradio for Omarchy

Your [myradio](https://myradio.garden) station in the Omarchy bar.

myradio is a radio station that runs on your own graphics card: a music model writes and plays the songs, voice models are the DJs, and your agent can put requests on air. This plugin puts that station in the Omarchy bar: listen, see what is on air, request songs, look up news and give the DJs something to say, from a panel that follows your Omarchy theme.

![The myradio panel in the Omarchy bar](docs/panel.png)

## What it does

- **Listen.** Play starts the station if it is stopped and plays it through your speakers. Stopping listening leaves the station on air.
- **On air now.** The song or DJ clip that is playing, how far in it is, and stop, skip and fade into the next track.
- **Request a song.** Describe it (genre, mood, what it is about). When it has been made, it plays next.
- **News.** Type a topic. The station looks it up, and the DJ you pick reads the sourced headlines on air next, naming each publisher.
- **The DJs.** Pick from the station's hosts. Give one a line to say on air, or ask for a time check, a station ID, a back-announce or an intro for the next song.
- **Autopilot DJ.** One switch: the station writes intros for upcoming songs, station IDs and news on its own, and puts each one in front of the song it belongs to.
- **The queue.** What plays next, with play next and remove.
- **Volume** from the panel, or by scrolling on the bar icon.
- **Dial**, the myradio mascot, shows what the station is doing: asleep when the studio is closed, singing during a song, on air during a DJ break, excited while something is being made.
- **The bar icon** is a small pixel radio. Its antenna lights up while the station is on air, and its screen shows a level meter while you listen.

The song, news and DJ features need a music maker and a DJ voice set up in the studio. News lookups and the autopilot DJ need a myradio with the director extension; on an older myradio those controls are hidden or read your line as a listener update.

## Install

Install myradio first:

```sh
curl -fsSL https://myradio.garden/install.sh | sh
```

Then add the plugin and place it on the bar:

```sh
omarchy plugin add https://github.com/newjordan/omarchy-myradio.git --enable
omarchy bar move newjordan.myradio --after omarchy.weather
```

## Remove

```sh
omarchy plugin remove newjordan.myradio
```

This removes the plugin and its bar entry. Your station, its music and `~/.myradio` are not touched. The plugin's own settings stay in `~/.local/state/omarchy/myradio.json` until you delete that file.

## Controls

| Where | Input | Action |
| --- | --- | --- |
| Bar icon | Click | Open the panel |
| Bar icon | Middle click | Listen / stop listening |
| Bar icon | Right click | Skip |
| Bar icon | Scroll | Volume |
| Panel | Space or Enter | Listen / stop listening, or play the selected queue entry next |
| Panel | j / k or Up / Down | Move through the queue |
| Panel | h / l or Left / Right | Volume |
| Panel | x | Remove the selected queue entry |
| Panel | n | Skip |
| Panel | f | Fade into the next track |
| Panel | / or r | Write a request |
| Panel | d | Switch between Song, News and DJ |
| Panel | , and . | Previous and next DJ |
| Panel | a | Autopilot DJ on or off |
| Panel | o | Open the studio |

From a script or a keybinding:

```sh
omarchy-shell newjordan.myradio toggle
omarchy-shell newjordan.myradio skip
omarchy-shell newjordan.myradio request "slow jazz about a rainy Sunday"
omarchy-shell newjordan.myradio news "Artemis moon mission"
omarchy-shell newjordan.myradio say "Good morning to everyone up early."
omarchy-shell newjordan.myradio dj station_id        # time_check, station_id, song_back_announce, song_intro
omarchy-shell newjordan.myradio autopilot on         # on, off, or anything else to switch it
omarchy-shell newjordan.myradio nowPlaying
```

## A station on another computer

The studio only listens on its own computer. To control a station that runs elsewhere (a Mac mini on your network, say), forward its port over SSH and copy its control code:

```sh
mkdir -p -m 700 ~/.myradio-remote
ssh mini 'cat ~/.myradio/control.token' > ~/.myradio-remote/control.token
chmod 600 ~/.myradio-remote/control.token
ssh -N -L 127.0.0.1:8765:127.0.0.1:8765 mini
```

Then set `"dataDir"` to the full path of `~/.myradio-remote` in `~/.local/state/omarchy/myradio.json`. Keep the local port the same as the station's port; the studio checks it. To keep the tunnel up, run the `ssh` line as a systemd user service.

## How it works

- The plugin talks to the studio's local API on `127.0.0.1:8765` with the control code in `~/.myradio/control.token`. The code is passed to `curl` through a file descriptor, so it never appears in the process list.
- Listening plays the studio's live stream with `mpv`. If `mpv-mpris` is installed, Omarchy's media controls and media keys see it too.
- Settings and recent requests are kept in `~/.local/state/omarchy/myradio.json`. To use a station in another data folder or on another port, set `"dataDir"` or `"port"` there.
- Open studio opens the studio in your browser with the control code in the address, the same way myradio's own launcher does.
- The plugin itself only connects to your station. A news lookup is run by the station: its research service reads a Google News search for the topic.

## Requirements

`curl`, `jq`, `mpv` and `socat`, which ship with Omarchy, and a running myradio studio.

## License

Apache-2.0, the same as myradio.
